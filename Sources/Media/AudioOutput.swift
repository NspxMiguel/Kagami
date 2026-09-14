import AVFoundation
import Foundation
import OSLog

/// Plays 48 kHz stereo PCM straight off the wire through a pull-based `PCMRingBuffer`.
///
/// The render block asks the buffer for the next `frameCount` frames whenever the
/// hardware wants them; nothing here decides when audio plays, so there is no queue to
/// flush and restart when it falls behind — that push-and-flush pattern is what used to
/// cause an audible gap on every burst. Latency is bounded by the ring buffer's own
/// `targetFill`, adjustable at runtime by `AVSkew`'s nudge rule, not by however deep a
/// push queue happened to grow.
final class AudioOutput: @unchecked Sendable {
    private let log = Logger(subsystem: "com.kagami.app", category: "audio")
    private let engine = AVAudioEngine()
    private let source: AVAudioSourceNode
    private let ring: PCMRingBuffer
    private let lifecycleLock = NSLock()
    private var running = false
    /// Guarded by `lifecycleLock`, never touched by the render block: the newest
    /// console timestamp handed to `play`. `AVSkew` reads it (through
    /// `playheadSnapshot()`) to locate where the audio playhead currently sits in the
    /// console's own clock.
    private var newestWrittenTimestampMicros: UInt64?

    init?() {
        let channels = SysDVR.Format.audioChannels
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: SysDVR.Format.audioSampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: true)
        else { return nil }

        let ring = PCMRingBuffer()
        self.ring = ring
        // Captured by value into the render block below: `ring` is a class reference,
        // so this closure only ever touches `PCMRingBuffer.read`, which is the one
        // method on it safe to call from a real-time thread.
        source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let raw = buffers[0].mData else { return noErr }
            let samples = raw.assumingMemoryBound(to: Int16.self)
            let output = UnsafeMutableBufferPointer(start: samples, count: Int(frameCount) * channels)
            ring.read(into: output, frameCount: Int(frameCount))
            // Always false: the ring buffer already writes explicit silence on an
            // underrun, and reporting isSilence truthfully would need reading back
            // what was just written, which is work this callback has no reason to do.
            isSilence.pointee = false
            return noErr
        }
    }

    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.playback` + `.moviePlayback` is Apple's own pairing for mirroring
            // another device's video and audio together: unlike the old `.ambient`,
            // it is not silenced by the ring/silent switch, matching a game mirror the
            // person is actively watching rather than a background sound.
            try session.setCategory(.playback, mode: .moviePlayback)
            // The console's stereo mix already has a picture to go with it — Kagami's
            // own window or theater — so a virtualized, head-tracked soundstage on top
            // of that would fight the picture instead of matching it. Spelling
            // verified against the visionOS 26 SDK's AVFAudio.swiftinterface:
            // `AVAudioSession.setIntendedSpatialExperience(_: any
            // AVAudioSessionSpatialExperience)`, with `.bypassed` on
            // `AVAudioSession.BypassedSpatialExperience`.
            try session.setIntendedSpatialExperience(.bypassed)
            try session.setPreferredSampleRate(SysDVR.Format.audioSampleRate)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)

            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: source.outputFormat(forBus: 0))
            try engine.start()
            running = true
        } catch {
            log.error("audio engine did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        running = false
        newestWrittenTimestampMicros = nil
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Takes one payload straight off the wire — interleaved Int16 PCM, the console's
    /// own wire format, so no conversion is needed before it reaches the ring buffer —
    /// and appends it. `timestampMicros` is the packet's console timestamp; it does not
    /// affect playback order or timing (the ring buffer already governs that), it is
    /// only kept for `AVSkew` to locate the playhead.
    ///
    /// Runs on the audio network delivery task, never on the render thread — the only
    /// lock this takes is `lifecycleLock`, held briefly, and the ring buffer's own
    /// write lock, which may legitimately block here (see `PCMRingBuffer`).
    func play(_ pcm: Data, timestampMicros: UInt64) {
        lifecycleLock.lock()
        let isRunning = running
        if isRunning { newestWrittenTimestampMicros = timestampMicros }
        lifecycleLock.unlock()
        guard isRunning else { return }

        let bytesPerSample = SysDVR.Format.audioBytesPerSample
        let count = pcm.count / bytesPerSample
        guard count > 0 else { return }
        var samples = [Int16](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { destination in
            pcm.copyBytes(to: destination, count: count * bytesPerSample)
        }
        ring.write(samples)
    }

    /// Where `AVSkew` should treat the audio playhead as being right now, expressed in
    /// the console's own microsecond clock rather than as a sample count: the newest
    /// timestamp written, minus however much buffered audio and output latency stand
    /// between it and the speaker.
    func playheadSnapshot() -> (newestWrittenTimestampMicros: UInt64, fill: Duration, outputLatency: Duration)? {
        lifecycleLock.lock()
        let newest = newestWrittenTimestampMicros
        lifecycleLock.unlock()
        guard let newest else { return nil }
        let frames = ring.fillSamples / max(1, ring.channels)
        let fill = Duration.seconds(Double(frames) / ring.sampleRate)
        let outputLatency = Duration.seconds(source.outputPresentationLatency)
        return (newest, fill, outputLatency)
    }

    /// Applied by `AVSkew`'s nudge rule. Never called from the render block — like a
    /// trim, retuning the target only ever runs on the network delivery task.
    func setTargetFillSeconds(_ seconds: Double) {
        ring.setTargetFillSeconds(seconds)
    }

    var trimmedSamplesTotal: Int { ring.trimmedSamplesTotal }
    var underrunsTotal: Int { ring.underrunsTotal }
}
