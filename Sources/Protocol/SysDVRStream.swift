import Foundation
import Network
import OSLog

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
        // `var` rather than `let` so the memberwise initializer accepts an override —
        // Swift only synthesizes a default-valued init parameter for a property with an
        // initial-value expression when it is mutable. Nothing in the pipeline mutates
        // this after construction; tests use the override to build a packet as though
        // it arrived at a specific synthetic instant, without a real sleep.
        var receivedAt = ContinuousClock.now
    }

    enum Failure: LocalizedError {
        case notSysDVR
        case unsupportedVersion(String)
        case rejected(UInt32)
        case desynchronised
        case closed
        case timedOut
        case excessiveLatency
        /// The pipeline fell further behind live than any amount of catch-up could fix
        /// — see `VideoIngest.hardBacklogCeiling`. Fix 4 replaces the lateness-based
        /// reconnect this enum used to have with a genuine dead-socket timeout; this one
        /// case survives that change; it is not "data is late" but "so late that no
        /// realistic amount of catch-up decoding fixes it," which stays a reconnect
        /// reason even once the socket itself is proven alive.
        case backlogExceeded

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
            case .excessiveLatency:
                return "Stream latency exceeded the recovery budget."
            case .backlogExceeded:
                return String(localized: "The stream fell too far behind live to catch up.")
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

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { cont.resume(throwing: error); return }
                guard let data, data.count == count else {
                    cont.resume(throwing: Failure.closed); return
                }
                cont.resume(returning: data)
            }
            }
        } onCancel: {
            self.connection.cancel()
        }
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
