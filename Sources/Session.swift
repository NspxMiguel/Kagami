import Foundation
import Observation
import OSLog
import SwiftUI

/// The whole console session: both connections, the decoder, the speaker, and the
/// state the interface reads.
@MainActor
@Observable
final class Session {
    enum State: Equatable {
        case idle
        case connecting
        /// Connected, but the console is not producing frames. This is the normal state
        /// on the HOME menu: SysDVR captures through `grc:d`, which only runs while a
        /// game is in the foreground, so the link is fine and the picture is simply not
        /// there yet.
        case waitingForGame
        case streaming
        case failed(String)
    }

    private let log = Logger(subsystem: "com.kagami.app", category: "session")

    var state: State = .idle
    let decoder = DecodedVideo()
    private var worker: H264Decoder?

    /// The colour `ConsoleScreen` is currently bleeding past its own edges, as raw
    /// components rather than a SwiftUI `Color` — it is `TheaterSpace`'s RealityKit
    /// material that reads this, and that has no use for round-tripping through `Color`
    /// to get three numbers back out. Shared here, rather than kept as the screen's own
    /// `@State`, because the theater is a separate scene with no other way to see it —
    /// without this, dimming the room just goes to a flat black with no relation to
    /// what is actually on screen.
    var ambientComponents: (r: Double, g: Double, b: Double) = (0, 0, 0)

    /// Where the console is. Remembered between launches, because it does not move.
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "console.host") }
    }

    var playAudio: Bool {
        didSet { UserDefaults.standard.set(playAudio, forKey: "console.audio") }
    }

    /// Blank the Switch's own panel while streaming. Handheld, this is most of the
    /// battery: the picture is already on your face.
    var turnOffConsoleScreen: Bool {
        didSet { UserDefaults.standard.set(turnOffConsoleScreen, forKey: "console.blankScreen") }
    }

    private(set) var framesPerSecond = 0

    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var audio: AudioOutput?
    private var frameCountWindow = 0
    private var lastFrameAt = Date.distantPast

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "console.host") ?? ""
        playAudio = defaults.object(forKey: "console.audio") as? Bool ?? true
        turnOffConsoleScreen = defaults.object(forKey: "console.blankScreen") as? Bool ?? false
    }

    var isRunning: Bool {
        switch state {
        case .idle, .failed: return false
        case .connecting, .waitingForGame, .streaming: return true
        }
    }

    // MARK: - Lifecycle

    func connect() {
        guard !isRunning else { return }
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }

        state = .connecting
        // A fresh worker per connection, rather than reusing one: it starts with no
        // session and no parameter sets, which is exactly the state a reset would have
        // produced anyway, and it sidesteps ever touching a VTDecompressionSession
        // that a just-cancelled decode call might still be inside.
        let worker = H264Decoder(output: decoder)
        self.worker = worker
        decoder.reset()

        videoTask = Task { await self.runVideo(host: target, worker: worker) }
        if playAudio {
            audio = AudioOutput()
            audio?.start()
            audioTask = Task { await self.runAudio(host: target) }
        }
        startWatchdog()
    }

    func disconnect() {
        videoTask?.cancel(); videoTask = nil
        audioTask?.cancel(); audioTask = nil
        watchdog?.cancel(); watchdog = nil
        audio?.stop(); audio = nil
        if let worker { Task { await worker.reset() } }
        worker = nil
        decoder.reset()
        framesPerSecond = 0
        ambientComponents = (0, 0, 0)
        state = .idle
    }

    // MARK: - Streams

    /// `nonisolated` is load-bearing, not decoration. `Session` is `@MainActor`, so a
    /// plain method here would run this entire loop — including resuming after every
    /// `await` — on the main actor. Moving `decode()` to its own actor still left the
    /// *loop* itself gated on the main actor being free to resume it, and the main
    /// actor is also where SwiftUI and RealityKit do their own per-frame work. Under
    /// real network conditions (bursty Wi-Fi, not the steady drip a loopback test
    /// gives you) that contention was enough to make packets pile up in the socket
    /// buffer faster than the loop drained them — measured as a frame rate that decayed
    /// over tens of seconds against a real console, while a raw socket reading the same
    /// stream held a rock-steady 30 packets/sec throughout. `nonisolated` lets this loop
    /// run without waiting for the main actor at all; only the two-line state updates
    /// below explicitly hop over to it, and a two-line hop clears even a busy queue
    /// far faster than an ~8ms decode call ever could.
    nonisolated private func runVideo(host: String, worker: H264Decoder) async {
        let turnOffScreen = await turnOffConsoleScreen
        let stream = SysDVRStream(host: host, kind: .video, turnOffConsoleScreen: turnOffScreen)
        do {
            try await stream.connect()
            await MainActor.run { self.state = .waitingForGame }

            for try await packet in await stream.packets() {
                if Task.isCancelled { break }

                if packet.header.flags.contains(.error) {
                    let message = SysDVR.describeError(packet.payload)
                    await MainActor.run { self.fail(message) }
                    break
                }
                guard !packet.payload.isEmpty else { continue }

                await worker.decode(packet.payload, timestampNanos: packet.header.timestamp)
                await MainActor.run { self.noteFrame() }
            }
        } catch is CancellationError {
            // Ordinary teardown.
        } catch {
            let message = error.localizedDescription
            await MainActor.run { self.fail(message) }
        }
        await stream.close()
    }

    /// Same reasoning as `runVideo`, plus one more thing this fixed that `runVideo`
    /// didn't: hopping to the main actor for every single audio packet — 40+ times a
    /// second — meant audio scheduling queued up behind whatever the main actor was
    /// doing for video (CGImage conversion, SwiftUI compositing, the theater's RealityKit
    /// update), which is exactly why audio lagged in lockstep with the picture instead
    /// of running independently the way two separate network connections should let it.
    /// `AudioOutput` is a plain class with its own internal locking, not `@MainActor` —
    /// grabbing it once, up front, means every `play()` call after that runs with no
    /// actor hop at all.
    nonisolated private func runAudio(host: String) async {
        let stream = SysDVRStream(host: host, kind: .audio)
        let output = await audio
        do {
            try await stream.connect()
            for try await packet in await stream.packets() {
                if Task.isCancelled { break }
                guard !packet.payload.isEmpty, !packet.header.flags.contains(.error) else { continue }
                output?.play(packet.payload)
            }
        } catch {
            // Audio failing on its own is not worth killing the picture over — plenty of
            // reasons to watch a muted console, none to watch a silent black rectangle.
            log.error("audio stream ended: \(error.localizedDescription, privacy: .public)")
        }
        await stream.close()
    }

    // MARK: - Health

    private func noteFrame() {
        frameCountWindow += 1
        lastFrameAt = Date()
        if state != .streaming { state = .streaming }
    }

    /// Counts frames per second and notices when the console goes quiet, which is what
    /// happens on the HOME menu and in games that refuse capture.
    private func startWatchdog() {
        watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                framesPerSecond = frameCountWindow
                frameCountWindow = 0

                if state == .streaming, Date().timeIntervalSince(lastFrameAt) > 2 {
                    state = .waitingForGame
                    if let worker { Task { await worker.reset() } }
                    decoder.reset()
                }
            }
        }
    }

    private func fail(_ message: String) {
        log.error("session failed: \(message, privacy: .public)")
        state = .failed(message)
        audio?.stop(); audio = nil
        audioTask?.cancel(); audioTask = nil
        watchdog?.cancel(); watchdog = nil
    }
}
