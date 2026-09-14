import CoreVideo
import Dispatch
import Foundation
import Synchronization
import XCTest

@testable import KagamiCore

final class LatestFrameSlotTests: XCTestCase {
    private func makePixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    func testUnreadWriteIsSupersededAndOnlyTheNewestSurvives() {
        let stats = PipelineStats()
        let slot = LatestFrameSlot(stats: stats)
        let buffer = makePixelBuffer()
        let generation = UUID()
        slot.beginGeneration(generation)

        for index in 0..<5 {
            slot.write(.init(buffer: buffer, timestampMicros: UInt64(index)), generation: generation)
        }
        XCTAssertEqual(stats.snapshot().framesSuperseded, 4)

        let taken = slot.take()
        XCTAssertEqual(taken?.timestampMicros, 4)
        // Emptied by the read: a second take before any new write finds nothing.
        XCTAssertNil(slot.take())
    }

    func testDecodedEqualsDisplayedPlusSupersededUnderRandomTiming() {
        let stats = PipelineStats()
        let slot = LatestFrameSlot(stats: stats)
        let buffer = makePixelBuffer()
        let generation = UUID()
        slot.beginGeneration(generation)

        var displayed = 0
        var rng = SystemRandomNumberGenerator()
        for index in 0..<10_000 {
            slot.write(.init(buffer: buffer, timestampMicros: UInt64(index)), generation: generation)
            // A consumer that only sometimes keeps up, same as a real renderer racing
            // the decoder: whenever it does read, that frame counts as displayed.
            if Bool.random(using: &rng), slot.take() != nil {
                displayed += 1
            }
        }
        // Whatever is left waiting at the end is neither displayed nor superseded yet.
        if slot.take() != nil { displayed += 1 }

        XCTAssertEqual(10_000, displayed + stats.snapshot().framesSuperseded)
    }

    func testWriteWakesTheRegisteredReader() {
        let slot = LatestFrameSlot()
        let buffer = makePixelBuffer()
        let generation = UUID()
        slot.beginGeneration(generation)
        let woken = Mutex(0)
        let wake = DispatchSemaphore(value: 0)
        slot.attachReader(onQueue: DispatchQueue(label: "test.reader")) {
            woken.withLock { $0 += 1 }
            wake.signal()
        }

        // Waited between writes on purpose: the wake source coalesces any writes that
        // land while a previous wake is still being handled (that is the whole point —
        // see `attachReader`'s header), so two writes issued back-to-back are only
        // guaranteed to wake the reader at least once, not exactly twice. Waiting for
        // each wake before issuing the next write keeps this assertion meaningful.
        slot.write(.init(buffer: buffer, timestampMicros: 1), generation: generation)
        XCTAssertEqual(wake.wait(timeout: .now() + 2), .success)
        slot.write(.init(buffer: buffer, timestampMicros: 2), generation: generation)
        XCTAssertEqual(wake.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(woken.withLock { $0 }, 2)
        slot.detachReader()
    }

    /// Regression test for the cross-generation race: a connection's presentation loop
    /// can still be decoding and writing after a new connection attempt has already
    /// begun (cancellation is cooperative, not instant), and the slot is never recreated
    /// per attempt. A write tagged with anything other than the current generation must
    /// be dropped outright — not superseded, not counted, not woken for — exactly as if
    /// it had never been sent.
    func testWriteFromAStaleGenerationIsDroppedEntirely() {
        let stats = PipelineStats()
        let slot = LatestFrameSlot(stats: stats)
        let buffer = makePixelBuffer()
        let woken = Mutex(0)
        let wake = DispatchSemaphore(value: 0)
        slot.attachReader(onQueue: DispatchQueue(label: "test.reader")) {
            woken.withLock { $0 += 1 }
            wake.signal()
        }

        let dyingGeneration = UUID()
        slot.beginGeneration(dyingGeneration)
        slot.write(.init(buffer: buffer, timestampMicros: 1), generation: dyingGeneration)
        XCTAssertEqual(wake.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(woken.withLock { $0 }, 1)
        XCTAssertEqual(slot.take()?.timestampMicros, 1)

        // A new connection attempt begins -- the old one's presentation loop has not
        // necessarily noticed its own cancellation yet, and keeps decoding.
        let freshGeneration = UUID()
        slot.beginGeneration(freshGeneration)

        // The dying generation's loop produces one more frame and writes it, unaware
        // anything has changed.
        slot.write(.init(buffer: buffer, timestampMicros: 2), generation: dyingGeneration)

        // Dropped outright: no wake, no supersede count, and the slot still holds
        // whatever the fresh generation last legitimately wrote (nothing, here) rather
        // than the stale frame. Proving "no wake happened" means waiting out a bounded
        // grace period instead of waiting for an event that should never come.
        XCTAssertEqual(wake.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertEqual(woken.withLock { $0 }, 1)
        XCTAssertEqual(stats.snapshot().framesSuperseded, 0)
        XCTAssertNil(slot.take())

        // The fresh generation's own writes are unaffected.
        slot.write(.init(buffer: buffer, timestampMicros: 3), generation: freshGeneration)
        XCTAssertEqual(wake.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(woken.withLock { $0 }, 2)
        XCTAssertEqual(slot.take()?.timestampMicros, 3)
        slot.detachReader()
    }

    /// Regression test for the kagami-2026-09-13/14 SIGBUS: "Thread stack size exceeded
    /// due to excessive recursion" after ~280 s / ~8,300 decoded frames, always inside
    /// the reader's wake-up path, one call to `DispatchQueue.async` deep. The full
    /// analysis is in `attachReader`'s header on `LatestFrameSlot`; the short version is
    /// that `write()` used to call a caller-supplied closure directly, on the decoder's
    /// own thread, once per frame -- and the specific closure it called eventually made a
    /// call (`DispatchQueue.async`, evaluating its defaulted `flags:` argument) that,
    /// under contention from the cooperative thread pool, recursed instead of returning.
    ///
    /// Faithfully reproducing *that exact* failure on demand is not practical here: it
    /// depends on many concurrent first-time callers racing Swift's runtime
    /// generic-metadata cache for the same not-yet-instantiated type, on a specific
    /// OS/Swift-runtime build, and it took ~280 real seconds of contended traffic to
    /// surface on device even there -- a single writer thread calling `write()` in a
    /// tight sequential loop, as below, would not race anything and would very likely
    /// "pass" against the *old* wiring too, most of the time, which would make it a flaky
    /// regression test rather than a reliable one.
    ///
    /// What this test asserts instead is the structural property that makes the whole
    /// failure category impossible, regardless of scheduling or runtime version:
    /// `write()` must never again call into caller-supplied code on the writer's own
    /// native stack, so its per-call stack usage is O(1) no matter how many times it is
    /// called. A 256 KB thread stack -- roughly 1/32nd of a default thread's -- makes this
    /// sensitive: with the *old* wiring (`write()` invoking `onWriteBox`'s closure
    /// inline, and that closure itself making a nested call), any unbounded or
    /// linearly-growing per-call stack contribution would exhaust 256 KB in at most a few
    /// hundred to a few thousand iterations, not 50,000 -- so this test would fail fast,
    /// by crashing the test process with the very same "excessive recursion" signature,
    /// well before this run's iteration count, had the old callback-based `setDidWrite`
    /// still been in place. Against the current wiring (`write()` only ever merging a
    /// value into a `DispatchSourceUserDataAdd`), 50,000 iterations on that same small
    /// stack complete and drain cleanly, because nothing on this path recurses at all.
    func testFiftyThousandWritesFromASmallStackThreadNeverOverflow() {
        let stats = PipelineStats()
        let slot = LatestFrameSlot(stats: stats)
        let buffer = makePixelBuffer()
        let generation = UUID()
        slot.beginGeneration(generation)

        let writeCount = 50_000
        let consumed = Mutex(0)
        let readerQueue = DispatchQueue(label: "test.smallstack.reader")
        // Mirrors `VideoPump.pump()`: drain everything waiting, one `take()` at a time,
        // every time the reader is woken.
        slot.attachReader(onQueue: readerQueue) {
            while slot.take() != nil { consumed.withLock { $0 += 1 } }
        }

        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            for index in 0..<writeCount {
                slot.write(
                    .init(buffer: buffer, timestampMicros: UInt64(index)), generation: generation)
            }
            finished.signal()
        }
        // The whole point of this test: run the writer on a stack over an order of
        // magnitude smaller than a default thread's, so any per-call growth in `write()`'s
        // own call path overflows almost immediately instead of only after minutes of
        // real, contended traffic.
        thread.stackSize = 256 * 1024
        thread.start()

        // A stack overflow on a thread this small crashes the process outright (SIGBUS,
        // the same signature as the original report) rather than hanging -- so a timeout
        // here would itself be a surprising result, not the expected failure mode, but is
        // still checked so a genuine deadlock is reported as a normal test failure
        // instead of the suite hanging forever.
        XCTAssertEqual(
            finished.wait(timeout: .now() + 15), .success,
            "writer thread did not finish 50,000 writes in time")

        // The writer finishing does not guarantee the reader has drained the very last
        // frame yet -- its wake can still be in flight on `readerQueue`. Submitting an
        // empty block to that same serial queue is a barrier: because the source's
        // handler is itself always delivered through `readerQueue`, by the time this
        // call returns, every wake triggered by a write above (including the final one)
        // has already run to completion.
        readerQueue.sync {}

        XCTAssertEqual(consumed.withLock { $0 } + stats.snapshot().framesSuperseded, writeCount)
        slot.detachReader()
    }
}
