import AVFoundation
import Foundation
import OSLog

/// Plays the console's audio: signed 16-bit little-endian, 48 kHz, stereo, interleaved.
///
/// Kept deliberately shallow. Anything that buffers generously here would drift away
/// from the picture, and audio arriving late is worse than audio arriving thin.
final class AudioOutput {
    private let log = Logger(subsystem: "com.kagami.app", category: "audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var scheduled = 0
    private let lock = NSLock()

    /// Beyond this many queued buffers the stream is behind and catching up by waiting
    /// would only deepen the lag, so new audio is dropped instead.
    private let maxQueuedBuffers = 8

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
        do {
            let session = AVAudioSession.sharedInstance()
            // .ambient keeps the console's sound from stopping whatever else the person
            // has playing, and keeps Kagami from claiming the mixing rights of a game.
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.play()
        } catch {
            log.error("audio engine did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        lock.lock(); scheduled = 0; lock.unlock()
    }

    /// Takes one payload straight off the wire and queues it.
    func play(_ pcm: Data) {
        let bytesPerFrame = SysDVR.Format.audioChannels * SysDVR.Format.audioBytesPerSample
        let frames = pcm.count / bytesPerFrame
        guard frames > 0 else { return }

        lock.lock()
        let queued = scheduled
        lock.unlock()
        guard queued < maxQueuedBuffers else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)

        // Interleaved Int16 in, planar Float32 out — the format the mixer wants.
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let scale = Float(Int16.max)
            for frame in 0..<frames {
                for channel in 0..<SysDVR.Format.audioChannels {
                    let sample = Int16(littleEndian: samples[frame * SysDVR.Format.audioChannels + channel])
                    channels[channel][frame] = Float(sample) / scale
                }
            }
        }

        lock.lock(); scheduled += 1; lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.scheduled -= 1; self.lock.unlock()
        }
    }
}
