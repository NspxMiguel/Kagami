import AVFoundation
import Foundation
import OSLog

/// Plays 48 kHz stereo PCM with a bounded queue. Lifecycle operations and scheduling
/// share a lock; completion callbacks use a separate counter lock and generation.
final class AudioOutput: @unchecked Sendable {
    private let log = Logger(subsystem: "com.kagami.app", category: "audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var scheduled = 0
    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var running = false
    private var epoch = 0

    /// Beyond this many queued buffers the stream is behind and catching up by waiting
    /// would only deepen the lag, so new audio is dropped instead.
    private let maxQueuedBuffers = 3

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SysDVR.Format.audioSampleRate,
            channels: AVAudioChannelCount(SysDVR.Format.audioChannels),
            interleaved: false)
        else { return nil }
        self.format = format
    }

    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // .ambient keeps the console's sound from stopping whatever else the person
            // has playing, and keeps Kagami from claiming the mixing rights of a game.
            try session.setCategory(.ambient, mode: .default)
            try session.setPreferredSampleRate(SysDVR.Format.audioSampleRate)
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
            running = true
        } catch {
            log.error("audio engine did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        running = false
        lock.withLock {
            epoch += 1; scheduled = 0
        }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    /// Takes one payload straight off the wire and queues it.
    func play(_ pcm: Data) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard running else { return }
        let bytesPerFrame = SysDVR.Format.audioChannels * SysDVR.Format.audioBytesPerSample
        let frames = pcm.count / bytesPerFrame
        guard frames > 0 else { return }

        lock.lock()
        let queued = scheduled
        lock.unlock()
        if queued >= maxQueuedBuffers {
            // Flush old sound on a burst instead of discarding the newest sound and
            // keeping the player permanently behind the console.
            lock.withLock {
                epoch += 1; scheduled = 0
            }
            player.stop()
            player.play()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)

        // Interleaved Int16 in, planar Float32 out — the format the mixer wants.
        pcm.withUnsafeBytes { raw in
            let scale = Float(Int16.max)
            for frame in 0..<frames {
                for channel in 0..<SysDVR.Format.audioChannels {
                    let offset = (frame * SysDVR.Format.audioChannels + channel) * 2
                    let sample = Int16(
                        littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                    channels[channel][frame] = Float(sample) / scale
                }
            }
        }

        let bufferEpoch = lock.withLock {
            scheduled += 1; return epoch
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                if self.epoch == bufferEpoch { self.scheduled = max(0, self.scheduled - 1) }
            }
        }
    }
}
