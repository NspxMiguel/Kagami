import Foundation
import Network
import OSLog
import Synchronization

/// One TCP connection to the console: video or audio, never both.
///
/// SysDVR opens a port per stream and each one runs its own handshake, so this is the
/// whole conversation with one of them — connect, agree on a protocol version, then
/// read framed packets until someone hangs up.
actor SysDVRStream {
    enum Kind: Sendable {
        case video, audio

        var port: UInt16 { self == .video ? SysDVR.Port.video : SysDVR.Port.audio }
        var name: String { self == .video ? "video" : "audio" }
    }

    struct Packet: Sendable {
        let header: SysDVR.PacketHeader
        let payload: Data
        var sequence = 0
    }

    enum Failure: LocalizedError {
        case notSysDVR
        case unsupportedVersion(String)
        case rejected(UInt32)
        case desynchronised
        case closed
        case timedOut
        /// The pipeline fell further behind live than any amount of catch-up could fix
        /// — see `VideoIngest.hardBacklogCeiling`. This is the one place a reconnect is
        /// triggered by lateness rather than by the socket itself being dead, and only
        /// because 3 s of backlog means something is wrong with the connection, not the
        /// decoder.
        case backlogExceeded
        /// `VideoIngest`'s self-heal policy already tried a full decoder reset and
        /// packets kept arriving with still no frame produced — the decoder itself is
        /// exonerated at that point, and only tearing down this TCP connection and
        /// renegotiating from scratch is left to try.
        case decoderWedged

        var errorDescription: String? {
            switch self {
            case .notSysDVR:
                return String(localized: "Something is listening on that port, but it is not SysDVR.")
            case .unsupportedVersion(let version):
                return String(localized: "The console speaks SysDVR protocol \(version), which Kagami does not know.")
            case .rejected(let code):
                if let known = SysDVR.HandshakeFailure(rawValue: code) { return known.message }
                return String(localized: "The console refused the connection (code \(code)).")
            case .desynchronised:
                return String(localized: "The stream lost sync with the console.")
            case .closed:
                return String(localized: "The console closed the connection.")
            case .backlogExceeded:
                return String(localized: "The stream fell too far behind live to catch up.")
            case .decoderWedged:
                return String(
                    localized: "The video decoder stopped producing frames and could not recover.")
            case .timedOut:
                return String(
                    localized: "The console did not respond. Check its address and Wi-Fi.")
            }
        }
    }

    private let log = Logger(subsystem: "com.kagami.app", category: "stream")
    private let kind: Kind
    private nonisolated let connection: NWConnection
    private var connected = false

    init(host: String, kind: Kind, turnOffConsoleScreen: Bool = false, port: UInt16? = nil) {
        self.kind = kind
        self.turnOffConsoleScreen = turnOffConsoleScreen

        let options = NWProtocolTCP.Options()
        // The console emits a frame every 33 ms and each one is small enough for Nagle
        // to want to hold it back waiting for a friend. That wait is pure added latency
        // on a stream that is already a third of a second behind the game.
        options.noDelay = true
        options.connectionTimeout = 5
        options.enableKeepalive = true
        options.keepaliveIdle = 5
        options.keepaliveInterval = 2
        options.keepaliveCount = 3

        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port ?? kind.port)!,
            using: NWParameters(tls: nil, tcp: options))
    }

    private let turnOffConsoleScreen: Bool

    // MARK: - Connection

    func connect() async throws {
        // TCP's timeout does not cover a peer that accepts but never handshakes.
        let deadline = Task {
            try await Task.sleep(for: .seconds(6))
            connection.cancel()
        }
        defer { deadline.cancel() }
        try Task.checkCancellation()
        try await openSocket()
        try await handshake()
        try Task.checkCancellation()
        connected = true
    }

    func close() {
        connection.cancel()
        connected = false
    }

    private func openSocket() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // The handler fires on every transition and the continuation may only be
            // resumed once, so it disarms itself on the first decisive state.
            let box = ResumeOnce(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.succeed()
                case .failed(let error): box.fail(error)
                case .cancelled: box.fail(Failure.closed)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            self.connection.cancel()
        }
    }

    /// The console speaks first with `SysDVR|NN\0`, we answer with what we want, and it
    /// replies with a verdict. Anything unexpected in that exchange means we are not
    /// talking to a Switch and should say so plainly rather than stream noise.
    private func handshake() async throws {
        let hello = try await receiveExactly(SysDVR.Hello.size)
        guard let version = SysDVR.Hello.parse(hello) else { throw Failure.notSysDVR }
        guard SysDVR.VersionCode.isSupported(version) else {
            throw Failure.unsupportedVersion(SysDVR.VersionCode.string(version))
        }

        let request = SysDVR.HandshakeRequest(
            version: version,
            wantsVideo: kind == .video,
            wantsAudio: kind == .audio,
            turnOffConsoleScreen: turnOffConsoleScreen)

        try await send(request.encoded())

        let response = try await receiveExactly(SysDVR.HandshakeRequest.responseSize(for: version))
        let result = [UInt8](response.prefix(4)).enumerated()
            .reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }

        guard result == SysDVR.HandshakeRequest.okResult else { throw Failure.rejected(result) }
        log.info("\(self.kind.name, privacy: .public) stream up, protocol \(SysDVR.VersionCode.string(version), privacy: .public)")
    }

    // MARK: - Reading

    /// Reads packets until the connection ends or the task is cancelled.
    func packets() -> AsyncThrowingStream<Packet, Error> {
        // Unbounded on purpose: over TCP the only way to lose an access unit is to drop
        // it ourselves, and a dropped access unit is exactly what used to force a wait
        // for the next keyframe. `sequence` is still assigned below, for diagnostics —
        // it should now always come out contiguous, since nothing here discards a
        // packet the console actually sent.
        AsyncThrowingStream { continuation in
            let task = Task {
                var sequence = 0
                do {
                    while !Task.isCancelled {
                        var packet = try await readPacket()
                        packet.sequence = sequence
                        sequence += 1
                        continuation.yield(packet)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                self.connection.cancel()
            }
        }
    }

    private func readPacket() async throws -> Packet {
        let raw = try await receiveExactly(SysDVR.PacketHeader.size)
        // A bad magic means the byte stream slipped. There is no resync marker in this
        // protocol, so the honest move is to fail and let the session reconnect
        // rather than reinterpret whatever comes next as a length.
        guard let header = SysDVR.PacketHeader.parse(raw) else { throw Failure.desynchronised }

        let payload = header.dataSize > 0 ? try await receiveExactly(header.dataSize) : Data()
        return Packet(header: header, payload: payload)
    }

    // MARK: - Socket primitives

    private func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
            }
        } onCancel: {
            self.connection.cancel()
        }
    }

    /// No bytes AT ALL for this long means the socket is dead, not merely slow — a slow
    /// but live connection is `VideoIngest`'s problem to catch up from, not a reason to
    /// tear down a TCP connection that would only need to be renegotiated and wait for
    /// another keyframe. This is the one place that distinction is actually enforced.
    ///
    /// The timer resets on every partial delivery (see `receiveExactly`), not once per
    /// whole read: a single `minimumIncompleteLength: count` receive only completes once
    /// every one of `count` bytes is in hand, so racing a flat timeout against that one
    /// call would measure "how long did this whole read take", not "how long has the
    /// socket gone silent" — a connection that is genuinely still delivering bytes, just
    /// too slowly to finish one large I-frame payload inside the window, would time out
    /// exactly like a dead one. Reading in small increments and resetting the clock on
    /// each one is what makes this actually mean idle.
    private static let readIdleTimeout = Duration.seconds(3)

    /// Assembles `count` bytes, racing one long-lived idle watchdog against a loop of
    /// partial reads for the whole call — not one fresh `TaskGroup` and sleep per
    /// partial read. A single header or payload can arrive across many small TCP
    /// segments (exactly the busy-scene, high-bitrate case this pipeline exists for),
    /// and the previous shape paid for a new task group plus a new 3 s timer task on
    /// every one of those partial deliveries, only to tear both down a moment later —
    /// real, avoidable overhead on the hottest path in the app for no behavioural gain.
    ///
    /// The watchdog is a single task that wakes up, re-reads `deadline`, and either
    /// throws (nothing has extended it since the last time it looked) or goes back to
    /// sleep for however much of the window is left. `deadline` is pushed forward by
    /// `readLoop` after every partial delivery, so the watchdog always ends up sleeping
    /// against the freshest deadline by the time it actually throws — it just may take
    /// one extra wake-and-recheck cycle to notice a push that landed while it was
    /// already asleep, never an early or a missed timeout.
    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        let deadline = DeadlineBox(ContinuousClock.now.advanced(by: Self.readIdleTimeout))

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var buffer = Data()
                    buffer.reserveCapacity(count)
                    while buffer.count < count {
                        buffer.append(try await self.rawReceive(maximumLength: count - buffer.count))
                        deadline.value = .now.advanced(by: Self.readIdleTimeout)
                    }
                    return buffer
                }
                group.addTask {
                    while true {
                        let remaining = ContinuousClock.now.duration(to: deadline.value)
                        guard remaining > .zero else { throw Failure.timedOut }
                        try await Task.sleep(for: remaining)
                    }
                }
                // `group.next()` returns as soon as either task finishes, but exiting
                // this scope still has to wait for BOTH to actually complete — a
                // `cancelAll()` only sets the flag `Task.isCancelled` reads, it does not
                // itself unblock a continuation. So when the timeout wins the race, the
                // losing read loop would otherwise hang here forever: nothing was ever
                // going to resume its continuation, because the peer really did stop
                // sending. `rawReceive` cancels the connection from its own `onCancel`
                // handler for exactly this reason — that is what turns this
                // `cancelAll()` into a real, timely unblock instead of a wait that never
                // ends.
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } onCancel: {
            self.connection.cancel()
        }
    }

    /// Returns as soon as at least one byte is available, never waiting for all of
    /// `maximumLength` — that partial-progress behaviour is exactly what lets the idle
    /// timer above measure genuine silence instead of one whole read's duration.
    private func rawReceive(maximumLength: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, _, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let data, !data.isEmpty else {
                        cont.resume(throwing: Failure.closed); return
                    }
                    cont.resume(returning: data)
                }
            }
        } onCancel: {
            // Fires when this loses the race against the idle timeout (via the
            // enclosing group's `cancelAll()`) as much as when the outer caller cancels
            // outright. Either way there is nothing to wait for any more, and cancelling
            // the connection is what makes the pending `receive` completion handler
            // actually fire so this task can finish instead of hanging.
            self.connection.cancel()
        }
    }
}

/// A shared, mutable deadline `receiveExactly`'s two racing child tasks both read and
/// push forward. A plain `Mutex` captured directly by both closures compiles, but the
/// compiler's region-based isolation checker cannot prove a non-copyable value shared
/// this way is race-free from an actor-isolated method — wrapping it in an ordinary
/// reference type sidesteps that ambiguity: a class reference is unambiguously a single
/// shared value, backed by the same `Mutex` for the actual thread safety.
private final class DeadlineBox: @unchecked Sendable {
    private let mutex: Mutex<ContinuousClock.Instant>
    init(_ instant: ContinuousClock.Instant) { mutex = Mutex(instant) }
    var value: ContinuousClock.Instant {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}

/// A continuation that tolerates being told the outcome more than once.
/// `NWConnection` reports `.cancelled` after `.failed`, and resuming twice traps.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func succeed() { take()?.resume() }
    func fail(_ error: Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        defer { continuation = nil }
        return continuation
    }
}
