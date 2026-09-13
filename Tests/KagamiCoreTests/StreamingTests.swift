import CoreVideo
import Foundation
import Network
import VideoToolbox
import XCTest

@testable import KagamiCore

final class StreamingTests: XCTestCase, @unchecked Sendable {
    func testTimelineUsesMicrosecondsAndRecoversAfterBurst() {
        var timeline = StreamTimeline()
        let origin = ContinuousClock.now
        XCTAssertEqual(timeline.excessDelay(timestampMicros: 9_000_000, receivedAt: origin), .zero)
        XCTAssertEqual(
            timeline.excessDelay(
                timestampMicros: 9_100_000, receivedAt: origin.advanced(by: .milliseconds(100))),
            .zero)
        let delayed = timeline.excessDelay(
            timestampMicros: 9_200_000, receivedAt: origin.advanced(by: .milliseconds(500)))
        XCTAssertGreaterThan(delayed, .milliseconds(290))
        XCTAssertEqual(
            timeline.excessDelay(
                timestampMicros: 9_500_000, receivedAt: origin.advanced(by: .milliseconds(500))),
            .zero)
        XCTAssertEqual(
            timeline.excessDelay(timestampMicros: 0, receivedAt: origin.advanced(by: .seconds(1))),
            .zero)
    }

    func testCancelsDuringHandshake() async throws {
        let peer = try TestPeer(bytes: Data())
        let port = try await peer.start()
        defer { peer.stop() }
        let stream = SysDVRStream(host: "127.0.0.1", kind: .video, port: port)
        let task = Task { try await stream.connect() }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled handshake succeeded")
        } catch {}
        XCTAssertTrue(start.duration(to: .now) < .seconds(1))
        await stream.close()
    }

    func testSilentPeerHasHandshakeDeadline() async throws {
        let peer = try TestPeer(bytes: Data())
        let port = try await peer.start()
        defer { peer.stop() }
        let stream = SysDVRStream(host: "127.0.0.1", kind: .video, port: port)
        let start = ContinuousClock.now
        do {
            try await stream.connect()
            XCTFail("Silent peer connected")
        } catch {}
        XCTAssertTrue(start.duration(to: .now) < .seconds(8))
        await stream.close()
    }

    /// The client never drops a compressed access unit itself any more — over TCP the
    /// only loss is a decision made here, and every drop used to force a wait for the
    /// next keyframe. A burst that arrives faster than it is consumed used to leave only
    /// the newest 3; now every packet the peer sent comes out, in order.
    func testBurstDeliversEveryPacketInOrder() async throws {
        var bytes = TestPeer.handshake
        for index in 0..<100 {
            bytes.append(littleEndian: SysDVR.PacketHeader.magic)
            bytes.append(littleEndian: UInt32(1))
            bytes.append(littleEndian: UInt64(index * 33_333))
            bytes.append(contentsOf: [1, 0, UInt8(index)])
        }
        let peer = try TestPeer(bytes: bytes)
        let port = try await peer.start()
        defer { peer.stop() }
        let stream = SysDVRStream(host: "127.0.0.1", kind: .video, port: port)
        try await stream.connect()
        let packets = await stream.packets()
        try await Task.sleep(for: .milliseconds(300))
        var received: [SysDVRStream.Packet] = []
        var iterator = packets.makeAsyncIterator()
        for _ in 0..<100 {
            guard let packet = try await iterator.next() else { break }
            received.append(packet)
        }
        XCTAssertEqual(received.count, 100)
        XCTAssertEqual(received.map(\.sequence), Array(0..<100))
        XCTAssertEqual(received.map(\.payload), (0..<100).map { Data([UInt8($0)]) })
        await stream.close()
    }

    func testCancelPendingReadAndConnectAgain() async throws {
        let peer = try TestPeer(bytes: TestPeer.handshake)
        let port = try await peer.start()
        defer { peer.stop() }
        for _ in 0..<3 {
            let stream = SysDVRStream(host: "127.0.0.1", kind: .video, port: port)
            try await stream.connect()
            let task = Task {
                for try await _ in await stream.packets() {}
                await stream.close()
            }
            try await Task.sleep(for: .milliseconds(50))
            let start = ContinuousClock.now
            task.cancel()
            _ = await task.result
            XCTAssertTrue(start.duration(to: .now) < .seconds(1))
            await stream.close()
        }
    }

    func testCorruptHeaderIsRejected() async throws {
        let peer = try TestPeer(bytes: TestPeer.handshake + Data(repeating: 0, count: 18))
        let port = try await peer.start()
        defer { peer.stop() }
        let stream = SysDVRStream(host: "127.0.0.1", kind: .video, port: port)
        try await stream.connect()
        do {
            for try await _ in await stream.packets() { XCTFail("Accepted a corrupt packet") }
            XCTFail("Corrupt stream ended without error")
        } catch SysDVRStream.Failure.desynchronised {} catch { XCTFail(String(describing: error)) }
        await stream.close()
    }

    func testDecoderSustainsThirtyFramesPerSecond() async throws {
        let file = try XCTUnwrap(
            Bundle.module.url(
                forResource: "keyframe", withExtension: "h264", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: file)
        let decoder = H264Decoder()
        let receiver = Task {
            var count = 0
            for await frame in decoder.frames {
                XCTAssertTrue(CVPixelBufferGetWidth(frame.buffer) == 1280)
                XCTAssertTrue(CVPixelBufferGetHeight(frame.buffer) == 720)
                count += 1
            }
            return count
        }
        let clock = ContinuousClock()
        let start = clock.now
        var durations: [Double] = []
        for index in 0..<300 {
            try await clock.sleep(
                until: start.advanced(by: .nanoseconds(Int64(index) * 33_333_333)))
            let before = clock.now
            try await decoder.decode(bytes, timestampMicros: UInt64(index) * 33_333)
            let duration = before.duration(to: clock.now)
            durations.append(
                Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds)
                    * 1000)
        }
        await decoder.finish()
        let count = await receiver.value
        XCTAssertTrue(count == 300)
        let sorted = durations.sorted()
        print(
            "720p30: \(count)/300 decoded frames; decode p50=\(sorted[150])ms, p95=\(sorted[285])ms, max=\(sorted[299])ms"
        )
    }

    func testDecoderAcceptsSeparateParameterSets() async throws {
        let file = try XCTUnwrap(
            Bundle.module.url(
                forResource: "keyframe", withExtension: "h264", subdirectory: "Fixtures"))
        let parsed = AnnexB.parse(try Data(contentsOf: file))
        let decoder = H264Decoder()
        for parameter in parsed.parameterSets {
            try await decoder.decode(Data([0, 0, 0, 1]) + parameter, timestampMicros: 0)
        }
        var picture = Data()
        var offset = 0
        let bytes = parsed.lengthPrefixedPicture
        while offset + 4 <= bytes.count {
            let length = bytes.withUnsafeBytes {
                Int(UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            offset += 4
            picture.append(contentsOf: [0, 0, 0, 1])
            picture.append(bytes[offset..<offset + length])
            offset += length
        }
        try await decoder.decode(picture, timestampMicros: 0)
        await decoder.finish()
        var count = 0
        for await _ in decoder.frames { count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testDecoderWaitsForKeyframeAndBoundsOutput() async throws {
        let file = try XCTUnwrap(
            Bundle.module.url(
                forResource: "keyframe", withExtension: "h264", subdirectory: "Fixtures"))
        let keyframe = try Data(contentsOf: file)
        let decoder = H264Decoder()
        try await decoder.decode(Data([0, 0, 0, 1, 0x41, 0]), timestampMicros: 0)
        for index in 0..<30 {
            try await decoder.decode(keyframe, timestampMicros: UInt64(index) * 33_333)
        }
        await decoder.recoverAfterDrop()
        try await decoder.decode(Data([0, 0, 0, 1, 0x41, 0]), timestampMicros: 1_000_000)
        await decoder.finish()
        var count = 0
        for await _ in decoder.frames { count += 1 }
        XCTAssertTrue(count == 1)
    }

    /// The do-not-output fallback may only fire on a synchronous rejection, where
    /// VideoToolbox's own contract guarantees no callback is still pending for the
    /// first submission. A timeout carries no such guarantee — the original call could
    /// still complete later — so resubmitting the same sample then would risk decoding
    /// one access unit twice concurrently inside the same stateful session.
    func testRetryWithoutHintOnlyFollowsASynchronousRejection() {
        XCTAssertTrue(
            H264Decoder.shouldRetryWithoutHint(
                after: .rejectedSynchronously(kVTVideoDecoderMalfunctionErr), suppressOutput: true))
        XCTAssertFalse(
            H264Decoder.shouldRetryWithoutHint(after: .timedOut, suppressOutput: true))
        XCTAssertFalse(
            H264Decoder.shouldRetryWithoutHint(after: .success, suppressOutput: true))
        // The hint was never sent in the first place, so there is nothing to fall back
        // from regardless of how the plain decode came out.
        XCTAssertFalse(
            H264Decoder.shouldRetryWithoutHint(
                after: .rejectedSynchronously(kVTVideoDecoderMalfunctionErr), suppressOutput: false))
    }

    /// A stall well under the read-idle timeout must never tear down the connection —
    /// that used to cost a handshake plus a wait for the next keyframe for a delay the
    /// network was always going to recover from on its own.
    func testStallUnderTheIdleTimeoutNeverClosesTheConnection() async throws {
        var initial = TestPeer.handshake
        for index in 0..<90 { initial.appendTestPacket(index) }
        let burst: Data = {
            var data = Data()
            for index in 90..<165 { data.appendTestPacket(index) }
            return data
        }()

        let peer = try TestPeer(bytes: initial) { connection in
            Task {
                try? await Task.sleep(for: .milliseconds(2_500))
                connection.send(content: burst, completion: .contentProcessed { _ in })
            }
        }
        let port = try await peer.start()
        defer { peer.stop() }
        let stream = SysDVRStream(host: "127.0.0.1", kind: .video, port: port)
        try await stream.connect()
        var received: [SysDVRStream.Packet] = []
        var iterator = await stream.packets().makeAsyncIterator()
        for _ in 0..<165 {
            guard let packet = try await iterator.next() else { break }
            received.append(packet)
        }
        XCTAssertEqual(received.count, 165)
        XCTAssertEqual(received.map(\.sequence), Array(0..<165))
        await stream.close()
    }

    /// A socket that goes silent past the idle timeout is the one lateness-shaped thing
    /// that should still end the connection — nothing else can tell the console is
    /// actually gone rather than just slow.
    func testIdleSocketTimesOutRatherThanHangingForever() async throws {
        let peer = try TestPeer(bytes: TestPeer.handshake)
        let port = try await peer.start()
        defer { peer.stop() }
        let stream = SysDVRStream(host: "127.0.0.1", kind: .video, port: port)
        try await stream.connect()
        let start = ContinuousClock.now
        do {
            for try await _ in await stream.packets() { XCTFail("Idle peer produced a packet") }
            XCTFail("Idle peer's stream ended without error")
        } catch SysDVRStream.Failure.timedOut {
        } catch {
            XCTFail("Expected .timedOut, got \(error)")
        }
        let elapsed = start.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(3))
        XCTAssertLessThan(elapsed, .seconds(5))
        await stream.close()
    }
}

extension Data {
    /// One synthetic video packet: 18-byte header plus a 1-byte payload carrying its
    /// own index, so a test can check both ordering and content without decoding
    /// anything.
    fileprivate mutating func appendTestPacket(_ index: Int) {
        append(littleEndian: SysDVR.PacketHeader.magic)
        append(littleEndian: UInt32(1))
        append(littleEndian: UInt64(index * 33_333))
        append(contentsOf: [1, 0, UInt8(truncatingIfNeeded: index)])
    }
}

private final class TestPeer: @unchecked Sendable {
    static var handshake: Data {
        var data = Data("SysDVR|03\0".utf8)
        data.append(littleEndian: UInt32(6))
        data.append(Data(repeating: 0, count: 68))
        return data
    }

    private let listener: NWListener
    private let bytes: Data
    private let onConnect: (@Sendable (NWConnection) -> Void)?
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(bytes: Data, onConnect: (@Sendable (NWConnection) -> Void)? = nil) throws {
        self.bytes = bytes
        self.onConnect = onConnect
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            lock.withLock { connections.append(connection) }
            connection.start(queue: .global())
            if !bytes.isEmpty {
                connection.send(content: bytes, completion: .contentProcessed { _ in })
            }
            onConnect?(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
        listener.newConnectionHandler = nil
        lock.withLock {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
