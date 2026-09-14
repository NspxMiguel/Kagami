import CoreVideo
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
    private let onWriteBox = Mutex<(@Sendable () -> Void)?>(nil)
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
    /// pump), so a single callback — not a list of observers — is enough.
    func setDidWrite(_ callback: (@Sendable () -> Void)?) {
        onWriteBox.withLock { $0 = callback }
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
        onWriteBox.withLock { $0 }?()
    }

    /// Takes the pending frame, if any, leaving the slot empty.
    func take() -> Frame? {
        pending.withLock { slot in
            defer { slot = nil }
            return slot
        }
    }
}
