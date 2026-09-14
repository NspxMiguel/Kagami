import Darwin
import Synchronization

/// A pull-based ring buffer for interleaved 16-bit PCM that always favors the newest
/// audio over the oldest.
///
/// `write` appends whatever just arrived off the wire. Once the buffered amount passes
/// `highWater` the oldest samples are dropped back down to `targetFill`, with a short
/// linear crossfade at the seam so the cut has no audible click — this is what keeps
/// audio bounded to roughly `targetFill` plus output latency no matter what the network
/// does, instead of a push queue that grows for as long as the sender is ahead.
///
/// `read` is what the real-time render callback calls, so it never blocks: the writer
/// takes a real lock (it only ever runs on the network delivery task, where a wait is
/// harmless), but the reader only ever *tries* that same lock. Losing the race — the
/// writer is mid-append or mid-trim — is treated exactly like an underrun: silence for
/// that callback, counted, and tried again next time. A real block here, waiting out a
/// writer that could itself be scheduled out, is the priority inversion a render
/// callback cannot afford; a dropped callback's worth of audio is inaudible.
final class PCMRingBuffer: @unchecked Sendable {
    let channels: Int
    let sampleRate: Double
    let capacitySamples: Int
    let highWaterSamples: Int
    let crossfadeSamples: Int

    private var lock = os_unfair_lock()
    private var storage: [Int16] = []
    /// Interleaved-sample count `write` currently trims down to. Mutable at runtime —
    /// `AVSkew`'s nudge rule adjusts it within `nudgeBounds` — but only ever touched
    /// under `lock`, alongside everything else.
    private var targetFillSamples: Int
    /// True from init, and again after any underrun, until `storage` has re-accumulated
    /// `targetFillSamples`: an underrun that immediately resumes on a half-full buffer
    /// just underruns again a moment later, so this waits for a real cushion instead of
    /// trickling out whatever partial data exists.
    private var isRebuffering = true

    private let trimmedSamplesCount = Atomic<Int>(0)
    private let underrunCount = Atomic<Int>(0)

    /// - Parameters:
    ///   - sampleRate: frames per second of the PCM this buffer holds.
    ///   - channels: interleaved channel count.
    ///   - capacitySeconds: hard ceiling on buffered audio; a single write larger than
    ///     this keeps only its newest tail.
    ///   - targetFillSeconds: what a trim settles down to, and what must re-accumulate
    ///     after an underrun before playback resumes.
    ///   - highWaterSeconds: buffered amount that triggers a trim.
    ///   - crossfadeSeconds: length of the linear blend at a trim's seam.
    init(
        sampleRate: Double = SysDVR.Format.audioSampleRate,
        channels: Int = SysDVR.Format.audioChannels,
        capacitySeconds: Double = 0.5,
        targetFillSeconds: Double = 0.040,
        highWaterSeconds: Double = 0.100,
        crossfadeSeconds: Double = 0.005
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        func toSamples(_ seconds: Double) -> Int {
            max(0, Int((sampleRate * seconds).rounded())) * channels
        }
        capacitySamples = toSamples(capacitySeconds)
        targetFillSamples = toSamples(targetFillSeconds)
        highWaterSamples = toSamples(highWaterSeconds)
        crossfadeSamples = toSamples(crossfadeSeconds)
        storage.reserveCapacity(capacitySamples)
    }

    /// Total interleaved samples ever removed by a highWater trim (not counting the
    /// rare hard-capacity clamp of a single oversized write).
    var trimmedSamplesTotal: Int { trimmedSamplesCount.load(ordering: .relaxed) }
    /// Total `read` calls that returned any silence, whether from a genuine empty
    /// buffer, the rebuffering wait, or losing the trylock race.
    var underrunsTotal: Int { underrunCount.load(ordering: .relaxed) }

    /// Buffered amount right now, in interleaved samples. Diagnostics/tests only — the
    /// render path never checks this before calling `read`.
    var fillSamples: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return storage.count
    }

    var targetFillSecondsValue: Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Double(targetFillSamples / channels) / sampleRate
    }

    /// Retunes how much audio a trim settles down to. Called by `AVSkew`'s nudge rule,
    /// never from the render block — like a trim itself, this only ever runs on the
    /// network delivery task.
    func setTargetFillSeconds(_ seconds: Double) {
        let clamped = max(0, Int((sampleRate * seconds).rounded())) * channels
        os_unfair_lock_lock(&lock)
        targetFillSamples = min(clamped, highWaterSamples)
        os_unfair_lock_unlock(&lock)
    }

    /// Appends newly arrived PCM. Only ever called from the network delivery task —
    /// this is the one place allowed to block (briefly, under real contention) and to
    /// do the O(size) work of a trim.
    func write(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        storage.append(contentsOf: samples)
        if storage.count > capacitySamples {
            // A single write bigger than the whole capacity: keep only its newest tail
            // rather than let the buffer grow past the ceiling it exists to enforce.
            storage.removeFirst(storage.count - capacitySamples)
        }
        if storage.count > highWaterSamples {
            trimToTargetLocked()
        }
    }

    /// Removes the oldest excess down to `targetFillSamples`, blending the seam over
    /// `crossfadeSamples` so the drop has no audible click. Must be called with `lock`
    /// already held.
    private func trimToTargetLocked() {
        let excess = storage.count - targetFillSamples
        guard excess > 0 else { return }
        let fadeLen = max(0, min(crossfadeSamples, storage.count - excess))
        if fadeLen > 0 {
            // `storage[i]` is about to be discarded (the outgoing tail of the old
            // audio); `storage[excess + i]` is what will become the new start (the
            // incoming audio). Blending them in place at the seam, rather than jumping
            // straight from one to the other, is the whole crossfade.
            for i in 0..<fadeLen {
                let t = Double(i) / Double(fadeLen)
                let outgoing = Double(storage[i])
                let incoming = Double(storage[excess + i])
                let blended = outgoing * (1 - t) + incoming * t
                storage[excess + i] = Int16(clamping: Int(blended.rounded()))
            }
        }
        storage.removeFirst(excess)
        trimmedSamplesCount.wrappingAdd(excess, ordering: .relaxed)
    }

    /// Fills `output` (interleaved, `frameCount * channels` samples) with the oldest
    /// buffered audio, or silence on underrun. Called from the real-time render
    /// thread: never allocates, never logs, never awaits, and never blocks.
    func read(into output: UnsafeMutableBufferPointer<Int16>, frameCount: Int) {
        guard frameCount > 0, let base = output.baseAddress else { return }
        // Clamp to whatever the caller's span can actually hold: `frameCount` is what
        // the render callback says it wants, but a future engine/format change could
        // hand this a buffer smaller than `frameCount * channels`. Writing silence into
        // the space that does exist (and still counting it as an underrun) beats
        // returning early and leaving whatever was already in that memory — audible
        // garbage, uncounted — playing out.
        let needed = min(frameCount * channels, output.count)
        guard needed > 0 else { return }
        guard os_unfair_lock_trylock(&lock) else {
            base.update(repeating: 0, count: needed)
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            return
        }
        defer { os_unfair_lock_unlock(&lock) }

        if isRebuffering {
            guard storage.count >= targetFillSamples else {
                base.update(repeating: 0, count: needed)
                underrunCount.wrappingAdd(1, ordering: .relaxed)
                return
            }
            isRebuffering = false
        }

        let available = min(needed, storage.count)
        if available > 0 {
            storage.withUnsafeBufferPointer { source in
                base.update(from: source.baseAddress!, count: available)
            }
            storage.removeFirst(available)
        }
        if available < needed {
            base.advanced(by: available).update(repeating: 0, count: needed - available)
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            isRebuffering = true
        }
    }
}
