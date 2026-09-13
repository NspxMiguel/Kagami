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
    private(set) var state: State = .idle
    let decoder = DecodedVideo()
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

    init() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "console.host") ?? ""
        playAudio = defaults.object(forKey: "console.audio") as? Bool ?? true
        turnOffConsoleScreen = defaults.object(forKey: "console.blankScreen") as? Bool ?? false
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
        framesPerSecond = 0
        state = .connecting
        videoTask = Task { await runVideo(host: target, blankScreen: blankScreen, token: token) }
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

    nonisolated private func runVideo(host: String, blankScreen: Bool, token: UUID) async {
        var retry = 0
        while !Task.isCancelled {
            let stream = SysDVRStream(host: host, kind: .video, turnOffConsoleScreen: blankScreen)
            let worker = H264Decoder()
            var presentation: Task<Void, Never>?
            var terminalError: String?
            do {
                try await stream.connect()
                try Task.checkCancellation()
                await setState(.waitingForGame, token: token)
                presentation = Task { @MainActor in
                    for await frame in worker.frames {
                        guard !Task.isCancelled, self.generation == token else { break }
                        guard frame.decodedAt.duration(to: .now) < .milliseconds(100) else {
                            continue
                        }
                        self.decoder.publish(frame.buffer)
                        self.lastFrameAt = .now
                        self.state = .streaming
                    }
                }
                var previousSequence = -1
                var timeline = StreamTimeline()
                var stalePackets = 0
                for try await packet in await stream.packets() {
                    try Task.checkCancellation()
                    if packet.header.flags.contains(.error) {
                        // Capture can be unavailable on HOME or in a particular game.
                        await setState(.waitingForGame, token: token)
                        continue
                    }
                    guard !packet.payload.isEmpty else { continue }
                    if packet.sequence != previousSequence + 1 {
                        await worker.recoverAfterDrop()
                    }
                    previousSequence = packet.sequence
                    let transportDelay = timeline.excessDelay(
                        timestampMicros: packet.header.timestamp,
                        receivedAt: packet.receivedAt)
                    guard transportDelay + packet.receivedAt.duration(to: .now) < .milliseconds(120)
                    else {
                        await worker.recoverAfterDrop()
                        stalePackets += 1
                        if stalePackets >= 30 { throw SysDVRStream.Failure.excessiveLatency }
                        continue
                    }
                    stalePackets = 0
                    try await worker.decode(
                        packet.payload, timestampMicros: packet.header.timestamp)
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
            await worker.finish()
            if let presentation { await presentation.value }
            guard !Task.isCancelled else { return }
            if let terminalError {
                await fail(terminalError, token: token)
                return
            }
            await setState(.reconnecting, token: token)
            retry = min(retry + 1, 4)
            do { try await Task.sleep(for: .milliseconds(retry == 1 ? 300 : retry * 1000)) } catch {
                return
            }
        }
    }

    nonisolated private func runAudio(host: String, output: AudioOutput) async {
        while !Task.isCancelled {
            let stream = SysDVRStream(host: host, kind: .audio)
            do {
                try await stream.connect()
                var timeline = StreamTimeline()
                var stalePackets = 0
                for try await packet in await stream.packets() {
                    try Task.checkCancellation()
                    guard !packet.payload.isEmpty, !packet.header.flags.contains(.error) else { continue }
                    let transportDelay = timeline.excessDelay(
                        timestampMicros: packet.header.timestamp,
                        receivedAt: packet.receivedAt)
                    guard transportDelay + packet.receivedAt.duration(to: .now) < .milliseconds(80)
                    else {
                        stalePackets += 1
                        if stalePackets >= 40 { throw SysDVRStream.Failure.excessiveLatency }
                        continue
                    }
                    stalePackets = 0
                    output.play(packet.payload)
                }
            } catch {
                if !Task.isCancelled {
                    log.error(
                        "audio connection ended: \(error.localizedDescription, privacy: .public)")
                }
            }
            await stream.close()
            guard !Task.isCancelled else { return }
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
                if let count, let previousCount {
                    framesPerSecond = Int(
                        (Double(max(0, count - previousCount)) / seconds).rounded())
                } else {
                    framesPerSecond = 0
                }
                previousCount = count
                previousTime = now
                if UserDefaults.standard.bool(forKey: "streamDiagnostics") {
                    print(
                        "video: displayedFPS=\(framesPerSecond), submitted=\(decoder.framesPresented), displayed=\(count ?? 0)"
                    )
                }
                if state == .streaming, lastFrameAt.duration(to: now) > .seconds(2) {
                    state = .waitingForGame
                    ambientComponents = (0, 0, 0)
                }
            }
        }
    }

    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        disconnect()
        state = .failed(message)
    }
}
