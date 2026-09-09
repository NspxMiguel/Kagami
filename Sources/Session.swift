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
    let decoder = VideoDecoder()

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
        decoder.reset()

        videoTask = Task { await self.runVideo(host: target) }
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
        decoder.reset()
        framesPerSecond = 0
        state = .idle
    }

    // MARK: - Streams

    private func runVideo(host: String) async {
        let stream = SysDVRStream(host: host, kind: .video,
                                  turnOffConsoleScreen: turnOffConsoleScreen)
        do {
            try await stream.connect()
            state = .waitingForGame

            for try await packet in await stream.packets() {
                if Task.isCancelled { break }

                if packet.header.flags.contains(.error) {
                    fail(SysDVR.describeError(packet.payload))
                    break
                }
                guard !packet.payload.isEmpty else { continue }

                decoder.decode(packet.payload, timestampNanos: packet.header.timestamp)
                noteFrame()
            }
        } catch is CancellationError {
            // Ordinary teardown.
        } catch {
            fail(error.localizedDescription)
        }
        await stream.close()
    }

    private func runAudio(host: String) async {
        let stream = SysDVRStream(host: host, kind: .audio)
        do {
            try await stream.connect()
            for try await packet in await stream.packets() {
                if Task.isCancelled { break }
                guard !packet.payload.isEmpty, !packet.header.flags.contains(.error) else { continue }
                audio?.play(packet.payload)
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
