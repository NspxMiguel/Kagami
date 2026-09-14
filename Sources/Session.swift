import Foundation
import Observation
import OSLog
import SwiftUI

@MainActor
@Observable
final class Session {
    enum State: Equatable {
        case idle, connecting, reconnecting, waitingForGame, streaming
        case failed(String)
    }

    private let log = Logger(subsystem: "com.kagami.app", category: "session")
    private let diagnosticsLog = Logger(subsystem: "com.kagami.app", category: "diagnostics")
    private(set) var state: State = .idle
    let decoder = DecodedVideo()
    // Sendable and touched from the nonisolated receive loops below on every packet —
    // isolating it to the main actor would reintroduce the very per-packet main-actor
    // hop this rewrite exists to remove.
    nonisolated let stats = PipelineStats()
    var ambientComponents: (r: Double, g: Double, b: Double) = (0, 0, 0)
    var theaterOpen = false
    var theaterTransitioning = false

    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "console.host") }
    }
    var playAudio: Bool {
        didSet { UserDefaults.standard.set(playAudio, forKey: "console.audio") }
    }
    var turnOffConsoleScreen: Bool {
        didSet { UserDefaults.standard.set(turnOffConsoleScreen, forKey: "console.blankScreen") }
    }

    private(set) var framesPerSecond = 0
    private var generation = UUID()
    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var audio: AudioOutput?
    private var lastFrameAt = ContinuousClock.now
    /// Read and nudged once a second by the watchdog, from the video slot's own
    /// last-displayed timestamp and the audio output's playhead snapshot — never from
    /// either receive loop, so this stays off the per-packet hot path entirely.
    private var avSkew = AVSkew()

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "console.host") ?? ""
        playAudio = defaults.object(forKey: "console.audio") as? Bool ?? true
        turnOffConsoleScreen = defaults.object(forKey: "console.blankScreen") as? Bool ?? false
        decoder.stats = stats
    }

    var isRunning: Bool {
        switch state {
        case .idle, .failed: false
        default: true
        }
    }

    func connect() {
        guard !isRunning else { return }
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        generation = UUID()
        let token = generation
        let blankScreen = turnOffConsoleScreen
        // Closes the cross-generation race at its source: from this line on, the slot
        // drops any write not tagged with `token`, even one from a previous connection
        // that has not noticed its own cancellation yet. See `LatestFrameSlot`'s header.
        decoder.beginGeneration(token)
        decoder.reset()
        stats.reset()
        framesPerSecond = 0
        avSkew = AVSkew()
        state = .connecting
        // Captured once, synchronously, while still on the main actor: `runVideo` is
        // nonisolated and runs its decode loop off the main actor entirely, so it must
        // not touch `decoder` (a `@MainActor` type) itself on every frame just to reach
        // this one `Sendable` slot.
        let slot = decoder.slot
        videoTask = Task { await runVideo(host: target, blankScreen: blankScreen, token: token, slot: slot) }
        if playAudio, let output = AudioOutput() {
            audio = output
            output.start()
            audioTask = Task { await runAudio(host: target, output: output) }
        }
        startWatchdog(token: token)
    }

    func disconnect() {
        // Invalidate callbacks before cancellation, so old connections cannot mutate a new one.
        generation = UUID()
        // Nothing holds this generation, so the dying connection's presentation loop
        // stops being able to write into the slot immediately, rather than only once
        // (or if) a later `connect()` happens to begin a fresh one.
        decoder.beginGeneration(generation)
        videoTask?.cancel()
        videoTask = nil
        audioTask?.cancel()
        audioTask = nil
        watchdog?.cancel()
        watchdog = nil
        audio?.stop()
        audio = nil
        decoder.reset()
        framesPerSecond = 0
        ambientComponents = (0, 0, 0)
        state = .idle
    }

    /// Backoff between reconnect attempts, indexed by `retry - 1`. Short first, because
    /// most drops are the console still being reachable a moment later; capped at 2 s so
    /// a truly gone console does not make the UI wait much longer than that per attempt.
    private nonisolated static let reconnectBackoffMillis = [300, 1000, 2000]

    /// Backoff for a reconnect that looks decoder-side rather than network-side: either
    /// `VideoIngest`'s own self-heal gave up on the decoder entirely
    /// (`SysDVRStream.Failure.decoderWedged`), or this attempt received real packets
    /// from the console but never decoded a single frame before failing some other
    /// way (see `noProgressDespiteData` at the call site). Deliberately much longer
    /// than `reconnectBackoffMillis`: the socket itself is not the problem here (the
    /// console answered fine), what is suspected to need time is whatever hardware or
    /// software video-decode resource left `H264Decoder` unable to produce a single
    /// frame no matter how many times it rebuilds its session. Grows only across
    /// consecutive such reconnects that themselves decode nothing before failing
    /// again — one that does produce even a single frame is real progress and resets
    /// the schedule, the same way an ordinary healthy packet resets `retry`.
    private nonisolated static let decoderWedgeBackoffMillis = [1_000, 3_000, 8_000, 15_000]

    /// How many decoder-side reconnects in a row are allowed to produce not a single
    /// frame before this loop stops trying and fails visibly instead. Comfortably past
    /// the length of `decoderWedgeBackoffMillis` itself, so a genuinely recoverable
    /// stall gets the full escalating schedule — and then it repeating at the longest
    /// step a couple more times — before this gives up; see the call site's own header
    /// for why giving up at all, rather than retrying forever, is the right call here.
    private nonisolated static let maxConsecutiveWedgesBeforeGivingUp = 6

    nonisolated private func runVideo(
        host: String, blankScreen: Bool, token: UUID, slot: LatestFrameSlot
    ) async {
        var retry = 0
        var consecutiveWedgesWithNoProgress = 0
        // Sticky across a whole streak of no-progress reconnects, cleared only by
        // real decode progress — never by a single no-progress attempt on its own.
        // `receivedDataThisAttempt` is measured per attempt, but a lone attempt that
        // happens to see zero packets (a race during reconnect against a peer's own
        // accept loop, a momentary Wi-Fi blip) must not erase the fact that an
        // *earlier* attempt in this same streak already proved the console is
        // reachable and the decoder produced nothing anyway. Without this,
        // `consecutiveWedgesWithNoProgress` resets to zero on that one silent attempt
        // exactly as if the whole streak had never happened. A soak with this exact
        // scenario measured `framesDecoded` frozen for the entire run while
        // `reconnects` still climbed to 21 with the give-up bound never tripping —
        // impossible if every one of those reconnects had actually been counted
        // (seven in a row exceeds `maxConsecutiveWedgesBeforeGivingUp`), so at least
        // one attempt in that streak must have measured `receivedDataThisAttempt ==
        // false` and reset the counter without this stickiness.
        var sawDataSinceLastProgress = false
        while !Task.isCancelled {
            let stream = SysDVRStream(host: host, kind: .video, turnOffConsoleScreen: blankScreen)
            let ingest = VideoIngest(stats: stats)
            var presentation: Task<Void, Never>?
            var terminalError: String?
            var wasWedged = false
            let beforeAttempt = stats.snapshot()
            do {
                try await stream.connect()
                try Task.checkCancellation()
                await setState(.waitingForGame, token: token)
                // Off the main actor end to end: this just forwards whatever the
                // decoder produced into the slot the renderer pulls from. Nothing here
                // decides presentation state — the watchdog derives `.streaming` from
                // frames actually reaching the screen, once a second, rather than this
                // loop hopping to the main actor on every one of them.
                presentation = Task {
                    for await frame in ingest.frames {
                        guard !Task.isCancelled else { break }
                        slot.write(
                            LatestFrameSlot.Frame(buffer: frame.buffer, timestampMicros: frame.timestampMicros),
                            generation: token)
                    }
                }
                for try await packet in await stream.packets() {
                    try Task.checkCancellation()
                    if packet.header.flags.contains(.error) {
                        // Capture can be unavailable on HOME or in a particular game.
                        await setState(.waitingForGame, token: token)
                        continue
                    }
                    guard !packet.payload.isEmpty else { continue }
                    stats.increment(\.packetsReceived)
                    stats.increment(\.bytesReceived, by: packet.payload.count)
                    try await ingest.accept(packet)
                    retry = 0
                }
            } catch {
                if !Task.isCancelled {
                    log.error(
                        "video connection ended: \(error.localizedDescription, privacy: .public)")
                    if let failure = error as? SysDVRStream.Failure {
                        switch failure {
                        case .notSysDVR, .unsupportedVersion, .rejected:
                            terminalError = error.localizedDescription
                        case .decoderWedged:
                            wasWedged = true
                        default: break
                        }
                    }
                }
            }
            presentation?.cancel()
            await stream.close()
            await ingest.finish()
            if let presentation { await presentation.value }
            guard !Task.isCancelled else { return }
            if let terminalError {
                await fail(terminalError, token: token)
                return
            }
            // Deliberately does not touch `slot` or the decoder's last output: the
            // point of reconnecting instead of failing is that the picture already on
            // screen stays there, dimmed, until the next connection produces a fresh
            // one.
            await setState(.reconnecting, token: token)
            stats.increment(\.reconnects)
            let afterAttempt = stats.snapshot()
            let madeProgress = afterAttempt.framesDecoded > beforeAttempt.framesDecoded
            // Whether this attempt actually heard from the console at all — as opposed
            // to a connection that failed before a single packet arrived (console off,
            // wrong address, Wi-Fi down). Only an attempt that received real data yet
            // still decoded nothing is evidence of a decoder-side problem; a silent
            // attempt is an ordinary network failure and must not count toward giving
            // up, no matter how many of those happen in a row.
            let receivedDataThisAttempt = afterAttempt.packetsReceived > beforeAttempt.packetsReceived
            // `VideoIngest`'s own `.decoderWedged` is the clean, expected way this
            // shows up — but it is not the only one: a decoder that keeps failing every
            // submission can also stall this same loop's *packet reading* for long
            // enough (rebuilding a session, waiting out a hiccup) that `VideoIngest`
            // itself throws `.backlogExceeded` first, over a live connection that was
            // never actually the problem. Both are the same underlying fact — packets
            // kept arriving and nothing got decoded — so both must count toward the
            // same give-up counter. Counting only `.decoderWedged` let a run that kept
            // tripping the backlog ceiling instead reconnect 19+ times with this
            // counter reset to zero every single time, exactly the failure a soak
            // caught: the pipeline never gave up because it never looked wedged by
            // this check's own narrower definition.
            let noProgressDespiteData = receivedDataThisAttempt && !madeProgress
            let waitMillis: Int
            if madeProgress {
                // Real decode progress, however this attempt eventually ended: the
                // decoder is not the problem, so whatever no-progress streak might
                // have been building — including whether it has ever seen data —
                // resets clean.
                consecutiveWedgesWithNoProgress = 0
                sawDataSinceLastProgress = false
                retry = min(retry + 1, Self.reconnectBackoffMillis.count)
                waitMillis = Self.reconnectBackoffMillis[retry - 1]
            } else if wasWedged || noProgressDespiteData {
                consecutiveWedgesWithNoProgress += 1
                sawDataSinceLastProgress = true
                // A soak measured this exact failure surviving every reconnect this
                // loop can throw at it — a brand-new TCP connection, a brand-new
                // VideoIngest, a brand-new H264Decoder and VTDecompressionSession,
                // repeated 28 times over 900s, every one wedging again on its very
                // first keyframe. That pattern — zero progress across a full run of
                // this schedule — is this loop's own signal that whatever broke is
                // not scoped to anything it owns and is not coming back on its own:
                // continuing to retry forever would just spin the console's Wi-Fi and
                // this device's battery for a picture that providably never returns.
                // Failing here, instead, tells the person watching a frozen screen
                // that quitting and reopening Kagami — a fresh process, starting over
                // with whatever this held onto released — is the one thing left that
                // might actually help, rather than leaving them staring at a picture
                // that looks like it is still trying.
                guard consecutiveWedgesWithNoProgress <= Self.maxConsecutiveWedgesBeforeGivingUp else {
                    await fail(
                        String(
                            localized:
                                "The video pipeline stopped responding and could not recover after several attempts. Close and reopen Kagami to try again."
                        ), token: token)
                    return
                }
                // A wedge-driven reconnect starts the ordinary network backoff over
                // too: whatever comes after this is a fresh problem, not a
                // continuation of a socket that was already flaky.
                retry = 0
                let index = min(
                    max(0, consecutiveWedgesWithNoProgress - 1), Self.decoderWedgeBackoffMillis.count - 1)
                waitMillis = Self.decoderWedgeBackoffMillis[index]
            } else {
                // Neither progress nor any evidence either way this time — most often
                // an attempt that failed before a single packet arrived (console off,
                // wrong address, Wi-Fi down, or a momentary race dialing back in).
                // Only clear the wedge streak if nothing has proven the decoder is the
                // problem yet: once an earlier attempt in this same streak *did*
                // receive data and still decoded nothing, one data-less attempt in
                // between must not erase that evidence, or it masks a decoder that
                // really is wedged behind an unrelated, one-off connection hiccup.
                if !sawDataSinceLastProgress {
                    consecutiveWedgesWithNoProgress = 0
                }
                retry = min(retry + 1, Self.reconnectBackoffMillis.count)
                waitMillis = Self.reconnectBackoffMillis[retry - 1]
            }
            do {
                try await Task.sleep(for: .milliseconds(waitMillis))
            } catch {
                return
            }
        }
    }

    nonisolated private func runAudio(host: String, output: AudioOutput) async {
        while !Task.isCancelled {
            let stream = SysDVRStream(host: host, kind: .audio)
            do {
                try await stream.connect()
                // No lateness gate here any more: a slow audio packet is caught up by
                // the output's own ring buffer trimming to stay live (kagami-6), not by
                // this loop deciding the connection itself is bad. The only way this
                // reconnects now is a dead socket, via `SysDVRStream`'s own read-idle
                // timeout.
                for try await packet in await stream.packets() {
                    try Task.checkCancellation()
                    guard !packet.payload.isEmpty, !packet.header.flags.contains(.error) else { continue }
                    stats.increment(\.packetsReceived)
                    stats.increment(\.bytesReceived, by: packet.payload.count)
                    output.play(packet.payload, timestampMicros: packet.header.timestamp)
                }
            } catch {
                if !Task.isCancelled {
                    log.error(
                        "audio connection ended: \(error.localizedDescription, privacy: .public)")
                }
            }
            await stream.close()
            guard !Task.isCancelled else { return }
            stats.increment(\.reconnects)
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func setState(_ next: State, token: UUID) {
        guard generation == token else { return }
        state = next
    }

    private func startWatchdog(token: UUID) {
        watchdog = Task {
            var previousCount: Int?
            var previousTime = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard generation == token else { return }
                let count = await decoder.displayedFrameCount()
                guard !Task.isCancelled, generation == token else { return }
                let now = ContinuousClock.now
                let elapsed = previousTime.duration(to: now)
                let seconds =
                    Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds)
                    / 1e18
                var displayedThisTick = 0
                if let count, let previousCount {
                    displayedThisTick = max(0, count - previousCount)
                    framesPerSecond = Int((Double(displayedThisTick) / seconds).rounded())
                } else {
                    framesPerSecond = 0
                }
                previousCount = count
                previousTime = now
                if let count { stats.set(\.framesDisplayed, to: count) }
                updateAudioVideoSkew(now: now, videoActive: displayedThisTick > 0)
                logDiagnosticsIfEnabled(framesDisplayedPerSecond: framesPerSecond)
                // `.streaming` is derived here, once a second, rather than the moment a
                // frame is decoded: that per-frame update used to mean a main-actor hop
                // on every single one. A frame actually reaching the display layer
                // (proven by the renderer's own metrics, not by the decoder producing
                // one) is what "streaming" means.
                if displayedThisTick > 0 {
                    lastFrameAt = now
                    switch state {
                    case .connecting, .waitingForGame, .reconnecting: state = .streaming
                    default: break
                    }
                    // Only relayed while frames are actually arriving: `stats` outlives
                    // any one connection, so a stale colour from before a drop must
                    // never leak back in here once the "no frames" branch below has
                    // already zeroed it for a dark, no-signal room.
                    if let colour = stats.ambientColor() { ambientComponents = colour }
                } else if state == .streaming, lastFrameAt.duration(to: now) > .seconds(2) {
                    state = .waitingForGame
                    ambientComponents = (0, 0, 0)
                }
            }
        }
    }

    /// Once a second, off the per-packet hot path entirely: feeds `AVSkew` the video
    /// slot's last-displayed timestamp and the audio output's playhead snapshot, applies
    /// whatever nudge it computes back to the ring buffer's target fill, and copies the
    /// audio-side counters into `stats` for the diagnostics line. Never touches video —
    /// only `audio.setTargetFillSeconds` is ever adjusted here.
    ///
    /// `videoActive` is this tick's own `displayedThisTick > 0` from the watchdog loop —
    /// whether a *new* frame actually reached the screen this second, not merely whether
    /// one ever has. A stalled decoder (a keyframe wait, or `VideoIngest`'s self-heal
    /// window) leaves `decoder.displayedTimestampMicros` sitting at its last value while
    /// audio's playhead keeps advancing on its own independent connection; feeding that
    /// unchanged timestamp to `AVSkew` regardless would read as ever-growing audio lag
    /// and both mistune the nudge and paint a misleading `avSkewMicros` in diagnostics.
    /// See `AVSkew.tick`'s own header for why ignoring the tick, not resetting the
    /// estimator, is the right response.
    private func updateAudioVideoSkew(now: ContinuousClock.Instant, videoActive: Bool) {
        if videoActive, let videoTimestamp = decoder.displayedTimestampMicros {
            avSkew.noteVideoDisplayed(timestampMicros: videoTimestamp)
        }
        guard let audio, let snapshot = audio.playheadSnapshot() else { return }
        avSkew.noteAudioPlayhead(
            newestWrittenTimestampMicros: snapshot.newestWrittenTimestampMicros,
            fill: snapshot.fill, outputLatency: snapshot.outputLatency)
        stats.set(\.audioFillMillis, to: milliseconds(snapshot.fill))
        if videoActive, let skew = avSkew.skew { stats.set(\.avSkewMicros, to: microseconds(skew)) }
        audio.setTargetFillSeconds(avSkew.tick(now: now, videoActive: videoActive))
        stats.set(\.audioSamplesTrimmed, to: audio.trimmedSamplesTotal)
        stats.set(\.audioUnderruns, to: audio.underrunsTotal)
    }

    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        disconnect()
        state = .failed(message)
    }

    /// One compact JSON line per second describing the whole pipeline, gated behind
    /// `-streamDiagnostics YES` so it costs nothing in normal use. Later stages read
    /// it back with `log show --predicate 'subsystem == "com.kagami.app" AND
    /// category == "diagnostics"'` instead of eyeballing the on-screen fps counter.
    private func logDiagnosticsIfEnabled(framesDisplayedPerSecond: Int) {
        guard UserDefaults.standard.bool(forKey: "streamDiagnostics") else { return }
        let line = stats.snapshot().diagnosticsLine(framesDisplayedPerSecond: framesDisplayedPerSecond)
        diagnosticsLog.log("\(line, privacy: .public)")
    }
}
