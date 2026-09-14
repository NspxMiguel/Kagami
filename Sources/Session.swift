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

    nonisolated private func runVideo(
        host: String, blankScreen: Bool, token: UUID, slot: LatestFrameSlot
    ) async {
        var retry = 0
        while !Task.isCancelled {
            let stream = SysDVRStream(host: host, kind: .video, turnOffConsoleScreen: blankScreen)
            let ingest = VideoIngest(stats: stats)
            var presentation: Task<Void, Never>?
            var terminalError: String?
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
                        slot.write(LatestFrameSlot.Frame(buffer: frame.buffer, timestampMicros: frame.timestampMicros))
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
            retry = min(retry + 1, Self.reconnectBackoffMillis.count)
            do {
                try await Task.sleep(for: .milliseconds(Self.reconnectBackoffMillis[retry - 1]))
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
                updateAudioVideoSkew(now: now)
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
    private func updateAudioVideoSkew(now: ContinuousClock.Instant) {
        if let videoTimestamp = decoder.displayedTimestampMicros {
            avSkew.noteVideoDisplayed(timestampMicros: videoTimestamp)
        }
        guard let audio, let snapshot = audio.playheadSnapshot() else { return }
        avSkew.noteAudioPlayhead(
            newestWrittenTimestampMicros: snapshot.newestWrittenTimestampMicros,
            fill: snapshot.fill, outputLatency: snapshot.outputLatency)
        stats.set(\.audioFillMillis, to: milliseconds(snapshot.fill))
        if let skew = avSkew.skew { stats.set(\.avSkewMicros, to: microseconds(skew)) }
        audio.setTargetFillSeconds(avSkew.tick(now: now))
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
