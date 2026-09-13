import AVFoundation
import CoreMedia
import Synchronization
import SwiftUI
import UIKit

/// Owns the surface the decoder's frames land on. Presentation itself now happens on a
/// background render queue (see `VideoPump`) — this class only holds the weak reference
/// SwiftUI needs and the slot the pipeline writes into.
@MainActor
final class DecodedVideo {
    weak var surface: VideoSurfaceView?
    let slot = LatestFrameSlot()
    var stats: PipelineStats? {
        didSet { slot.stats = stats }
    }

    /// The frame currently on screen, for the ambient-light sampler. Read a few times a
    /// second from here, never per frame, so going through the pump's own lock is fine.
    var frame: CVPixelBuffer? { surface?.latestPresentedFrame }

    func reset() {
        _ = slot.take()
        surface?.clear()
    }

    func displayedFrameCount() async -> Int? {
        await surface?.displayedFrameCount()
    }
}

struct VideoSurface: UIViewRepresentable {
    let video: DecodedVideo

    func makeUIView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        video.surface = view
        view.attach(video.slot)
        return view
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {}

    static func dismantleUIView(_ view: VideoSurfaceView, coordinator: ()) {
        view.clear()
    }
}

final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var pump: VideoPump?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// Starts pulling frames from `slot` onto the display layer's own renderer. The
    /// renderer is documented safe to enqueue from a background thread, so `VideoPump`
    /// deliberately is not a method on this `UIView` (which is main-actor-isolated) —
    /// the whole point is that none of this touches the main actor once it is running.
    func attach(_ slot: LatestFrameSlot) {
        let pump = VideoPump(renderer: videoLayer.sampleBufferRenderer, slot: slot)
        self.pump = pump
        pump.frameAvailable()  // in case a frame was already waiting when this attached
    }

    var latestPresentedFrame: CVPixelBuffer? { pump?.latestPresentedFrame }

    func clear() {
        pump?.stop()
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
    }

    func displayedFrameCount() async -> Int? {
        guard let metrics = await videoLayer.sampleBufferRenderer.videoPerformanceMetrics else {
            return nil
        }
        return max(0, metrics.totalNumberOfFrames - metrics.numberOfDroppedFrames)
    }
}

/// Pulls the newest frame out of a `LatestFrameSlot` and hands it to the display layer
/// whenever it is ready for more, entirely on a background queue.
///
/// This replaces the old push model — the decoder calling into a `@MainActor` method
/// per frame, dropped on the floor if `isReadyForMoreMediaData` happened to be false —
/// with a pull: the renderer asks for data when it wants it, and always gets whatever
/// is newest. Not a method on `VideoSurfaceView` on purpose: that is a `UIView`, and
/// `UIView` is main-actor-isolated as a whole, so anything touching the main actor's
/// timeline is exactly what this exists to avoid.
final class VideoPump: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let slot: LatestFrameSlot
    private let queue = DispatchQueue(label: "com.kagami.app.render")
    private var format: CMVideoFormatDescription?
    private let requesting = Mutex(false)
    private let lastPresented = Mutex<CVPixelBuffer?>(nil)

    init(renderer: AVSampleBufferVideoRenderer, slot: LatestFrameSlot) {
        self.renderer = renderer
        self.slot = slot
        slot.setDidWrite { [weak self] in self?.frameAvailable() }
    }

    var latestPresentedFrame: CVPixelBuffer? { lastPresented.withLock { $0 } }

    /// Wakes the pump when a new frame lands. `requestMediaDataWhenReady` is only
    /// re-armed if it was actually stopped — calling it while already active would just
    /// replace the same request.
    func frameAvailable() {
        let alreadyRequesting = requesting.withLock { current -> Bool in
            let was = current
            current = true
            return was
        }
        guard !alreadyRequesting else { return }
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pump() }
    }

    func stop() {
        requesting.withLock { $0 = false }
        renderer.stopRequestingMediaData()
    }

    /// Runs on `queue`. Drains the slot for as long as the renderer wants more, then
    /// stops asking — `requestMediaDataWhenReady` would otherwise spin this block
    /// against an empty slot until the next frame arrives.
    private func pump() {
        while renderer.isReadyForMoreMediaData {
            guard let frame = slot.take() else {
                renderer.stopRequestingMediaData()
                requesting.withLock { $0 = false }
                return
            }
            enqueue(frame)
        }
    }

    private func enqueue(_ frame: LatestFrameSlot.Frame) {
        if format == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: frame.buffer)
        {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: frame.buffer, formatDescriptionOut: &format)
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame.buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: true)
        else { return }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        renderer.enqueue(sample)
        lastPresented.withLock { $0 = frame.buffer }
    }
}
