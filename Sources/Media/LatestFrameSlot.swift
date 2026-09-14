import CoreVideo
import Dispatch
import Foundation
import Synchronization

/// A single-slot mailbox for the one decoded frame the renderer has not yet taken.
///
/// This is the whole mechanism behind "decode faster than arrival, present only the
/// newest frame": a writer (the decoder's own output) always overwrites, a reader (the
/// display layer's pump) always takes the newest thing waiting. Nothing here ever waits
/// for the other side, so neither can block the pipeline — a burst of decoded frames
/// just means most of them are superseded before anyone reads them, which is exactly
/// what should happen to frames that arrived behind the live edge.
final class LatestFrameSlot: Sendable {
    /// A decoded picture plus the console timestamp it carries, so a reader can tell
    /// which access unit ended up on screen.
    struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let timestampMicros: UInt64
    }

    private let pending = Mutex<Frame?>(nil)
    private let statsBox = Mutex<PipelineStats?>(nil)
    /// The reader's wake source, created once when a reader attaches. `write()` only
    /// ever merges a data value into it — see `attachReader` for why that, and not a
    /// plain callback, is what makes the wake-up structurally safe.
    private let wakeSource = Mutex<(any DispatchSourceUserDataAdd)?>(nil)
    /// The one connection attempt currently allowed to write into this slot. A `write`
    /// tagged with any other generation is silently dropped.
    ///
    /// The slot outlives any one connection — a session keeps a single `LatestFrameSlot`
    /// for its whole lifetime, never recreating it per attempt — and disconnecting is
    /// cooperative: cancelling the old connection's task does not make its still-running
    /// presentation loop stop writing decoded frames the instant a new connection
    /// begins. Without this check, a frame that loop decodes between "a new generation
    /// started" and "the old generation's teardown actually finished" would land in the
    /// slot a fresh session just reset for, resurrecting a stale picture (or, for a
    /// disconnect with no reconnect at all, writing into a slot nobody asked for anymore).
    /// `nil`, the initial value before any connection has ever begun, accepts nothing —
    /// there is no legitimate writer yet.
    private let currentGeneration = Mutex<UUID?>(nil)

    init(stats: PipelineStats? = nil) {
        statsBox.withLock { $0 = stats }
    }

    var stats: PipelineStats? {
        get { statsBox.withLock { $0 } }
        set { statsBox.withLock { $0 = newValue } }
    }

    /// Marks `generation` as the only one whose writes are accepted from now on. Called
    /// once per connection attempt — and once more on disconnect, with a generation
    /// nothing holds, so a dying connection's writes stop being accepted immediately
    /// rather than only once a *new* connection happens to begin.
    func beginGeneration(_ generation: UUID) {
        currentGeneration.withLock { $0 = generation }
    }

    /// Registers the one reader that should be woken whenever a frame lands in an empty
    /// slot. There is only ever one consumer of a given slot (the display layer's own
    /// pump), so a single wake source — not a list of observers — is enough.
    ///
    /// This — not a plain `@Sendable () -> Void` callback that `write()` calls directly —
    /// is deliberate, and is the fix for a real SIGBUS ("Thread stack size exceeded due
    /// to excessive recursion") that took down every decoded frame after ~280 s of
    /// streaming. The previous design let `write()` invoke an arbitrary closure
    /// synchronously, on whichever thread decoded the frame, every single time; nothing
    /// stopped that closure from doing something that does not return in bounded stack —
    /// and it did: the registered closure called `DispatchQueue.async`, whose defaulted
    /// `flags:` parameter goes through Swift's generic-metadata cache, which under the
    /// contention of dozens of near-simultaneous first-time lookups (one per decoded
    /// frame, forever) recursed instead of returning. Wrapping that same call in another
    /// layer of dispatch (the fix attempted before this one) did not help, because the
    /// crash was in evaluating the *call* to `.async`, not in anything that ran after it.
    ///
    /// `attachReader` removes the recursion by construction rather than by convention:
    /// `write()` below never again calls into caller-supplied code on the producer's own
    /// stack. It only ever merges a value into a `DispatchSourceUserDataAdd` — a lock-free
    /// atomic accumulate with no closures and no defaulted generic parameters to resolve
    /// per call — and GCD guarantees that merging into a source never runs its handler
    /// inline on the calling thread; the handler always runs later, on `queue`, and event
    /// delivery is coalesced (a source that already has unread data caches the new value
    /// instead of double-scheduling) so a burst of writes wakes the reader at least once
    /// without ever losing a wake. The one-time cost of resolving `DispatchQueue`'s own
    /// defaulted-argument overloads happens here, once, in `attachReader` — off the hot
    /// path entirely — instead of racing on every decoded frame.
    ///
    /// Call once per reader lifetime (typically from the consumer's own `init`), not per
    /// frame.
    func attachReader(onQueue queue: DispatchQueue, wake handler: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler(handler: handler)
        source.activate()
        wakeSource.withLock { previous in
            previous?.cancel()
            previous = source
        }
    }

    /// Detaches the current reader, if any, so a later `write()` stops signalling a
    /// source whose owner has gone away.
    func detachReader() {
        wakeSource.withLock { source in
            source?.cancel()
            source = nil
        }
    }

    /// Overwrites whatever frame is waiting, but only if `generation` is still the one
    /// `beginGeneration` last set — see that method's header for why a stale generation
    /// must be silently dropped rather than written. If nobody had taken the previous
    /// frame yet, it was never worth displaying — the slot only ever wants the live edge
    /// — and `framesSuperseded` says so.
    func write(_ frame: Frame, generation: UUID) {
        guard currentGeneration.withLock({ $0 }) == generation else { return }
        let hadPending = pending.withLock { slot -> Bool in
            let had = slot != nil
            slot = frame
            return had
        }
        if hadPending { statsBox.withLock { $0 }?.increment(\.framesSuperseded) }
        wakeSource.withLock { $0 }?.add(data: 1)
    }

    /// Takes the pending frame, if any, leaving the slot empty.
    func take() -> Frame? {
        pending.withLock { slot in
            defer { slot = nil }
            return slot
        }
    }
}
