import Foundation

/// Estimates additional network delay without assuming synchronized device clocks.
/// The initial capture/transport delay is unknown; only growth above the best
/// observed offset is measurable from one-way packets.
struct StreamTimeline {
    private var originTimestamp: UInt64?
    private var lastTimestamp: UInt64 = 0
    private var originTime = ContinuousClock.now
    private var minimumOffset = 0.0

    mutating func excessDelay(timestampMicros: UInt64, receivedAt: ContinuousClock.Instant)
        -> Duration
    {
        if originTimestamp == nil || timestampMicros < lastTimestamp {
            originTimestamp = timestampMicros
            originTime = receivedAt
            minimumOffset = 0
        }
        lastTimestamp = timestampMicros
        let elapsed = originTime.duration(to: receivedAt)
        let localSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let sourceSeconds = Double(timestampMicros - originTimestamp!) / 1_000_000
        let offset = localSeconds - sourceSeconds
        minimumOffset = min(minimumOffset, offset)
        return .seconds(max(0, offset - minimumOffset))
    }
}
