import Foundation
import Synchronization

/// Every drop point and pipeline counter in one place, so a stalled frame or a
/// keyframe wait shows up as a measured number instead of a guess.
///
/// Backed by a single mutex-guarded snapshot rather than one atomic per counter:
/// contention is irrelevant here (at most a few hundred increments per second), and
/// a plain `Int`-only struct keeps `Snapshot` trivially `Codable` for the diagnostics
/// logger.
final class PipelineStats: Sendable {
    struct Snapshot: Sendable, Equatable, Codable {
        var packetsReceived = 0
        var bytesReceived = 0
        /// Access units the client never saw, inferred from a gap in the console's own
        /// sequence numbering rather than sampled after the fact.
        var compressedDropped = 0
        var decodeCalls = 0
        var decodeErrors = 0
        var keyframeWaitsEntered = 0
        var keyframeWaitMillisTotal = 0
        var framesDecoded = 0
        var framesSuperseded = 0
        var rendererNotReady = 0
        var framesDisplayed = 0
        var reconnects = 0
        var audioSamplesTrimmed = 0
        var audioUnderruns = 0
        /// Latest console timestamp seen minus the timestamp currently being decoded, in
        /// milliseconds — how far behind live the pipeline is right now, not a historical
        /// average.
        var receiveBacklogMillis = 0
        /// `AVSkew`'s own measurement of how far apart the video and audio outputs are,
        /// in microseconds: positive means video is ahead (audio lagging). Microseconds
        /// rather than milliseconds because the 80 ms nudge threshold needs to resolve
        /// well below a whole millisecond of noise.
        var avSkewMicros = 0
        /// The audio ring buffer's current fill, in milliseconds — what `AVSkew` reads
        /// as the audio playhead's distance from the newest write.
        var audioFillMillis = 0
    }

    private let state = Mutex(Snapshot())
    /// The theater's ambient colour, as `AmbientSampler` computes it. Kept outside
    /// `Snapshot` because it is not a counter and has no business in the JSON
    /// diagnostics line, but it rides the same contract as every counter here: written
    /// from the ingest pipeline off the main actor, read a few times a second by the
    /// watchdog, never the other way around.
    private let ambientColorState = Mutex<(r: Double, g: Double, b: Double)?>(nil)

    /// Adds `amount` to one counter. Safe to call from any thread or actor.
    func increment(_ counter: WritableKeyPath<Snapshot, Int>, by amount: Int = 1) {
        state.withLock { $0[keyPath: counter] += amount }
    }

    /// Overwrites one counter with a value read from elsewhere (a renderer's own
    /// cumulative metrics, a backlog estimate) rather than accumulating locally.
    func set(_ counter: WritableKeyPath<Snapshot, Int>, to value: Int) {
        state.withLock { $0[keyPath: counter] = value }
    }

    func snapshot() -> Snapshot {
        state.withLock { $0 }
    }

    func setAmbientColor(_ color: (r: Double, g: Double, b: Double)) {
        ambientColorState.withLock { $0 = color }
    }

    func ambientColor() -> (r: Double, g: Double, b: Double)? {
        ambientColorState.withLock { $0 }
    }

    func reset() {
        state.withLock { $0 = Snapshot() }
        ambientColorState.withLock { $0 = nil }
    }
}

extension PipelineStats.Snapshot {
    /// One compact, single-line JSON object with every counter plus the derived
    /// numbers a raw counter cannot show by itself (frames displayed per second, and
    /// eventually audio fill once step 6 gives the pipeline a ring buffer to read it
    /// from). Field order is fixed so `log show` output is diffable across samples.
    func diagnosticsLine(framesDisplayedPerSecond: Int) -> String {
        let fields: [(String, Int)] = [
            ("packetsReceived", packetsReceived),
            ("bytesReceived", bytesReceived),
            ("compressedDropped", compressedDropped),
            ("decodeCalls", decodeCalls),
            ("decodeErrors", decodeErrors),
            ("keyframeWaitsEntered", keyframeWaitsEntered),
            ("keyframeWaitMillisTotal", keyframeWaitMillisTotal),
            ("framesDecoded", framesDecoded),
            ("framesSuperseded", framesSuperseded),
            ("rendererNotReady", rendererNotReady),
            ("framesDisplayed", framesDisplayed),
            ("framesDisplayedPerSecond", framesDisplayedPerSecond),
            ("reconnects", reconnects),
            ("audioSamplesTrimmed", audioSamplesTrimmed),
            ("audioUnderruns", audioUnderruns),
            ("receiveBacklogMillis", receiveBacklogMillis),
            ("avSkewMicros", avSkewMicros),
            ("audioFillMillis", audioFillMillis),
        ]
        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }
}

/// Converts a `Duration` to whole milliseconds. `Duration` has no built-in
/// millisecond accessor; every diagnostics counter that reports elapsed time
/// (`receiveBacklogMillis`, `keyframeWaitMillisTotal`) needs a plain `Int` rather
/// than an exact `Duration`, so this rounds down to the millisecond.
func milliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
}

/// Same idea as `milliseconds(_:)` above, at finer resolution: `AVSkew`'s 80 ms nudge
/// threshold needs to resolve well below a whole millisecond of rounding noise.
func microseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds) * 1_000_000 + Int(components.attoseconds / 1_000_000_000_000)
}
