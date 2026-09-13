import AVFoundation
import SwiftUI
import UIKit

/// Frames are delivered directly to the video layer, without invalidating SwiftUI
/// or copying every YUV frame into a CPU-backed CGImage.
@MainActor
final class DecodedVideo {
    private(set) var frame: CVPixelBuffer?
    private(set) var framesPresented = 0
    weak var surface: VideoSurfaceView?
    var stats: PipelineStats?

    func publish(_ buffer: CVPixelBuffer) {
        frame = buffer
        if surface?.present(buffer) == true {
            framesPresented += 1
        } else if surface != nil {
            stats?.increment(\.rendererNotReady)
        }
    }

    func reset() {
        frame = nil
        framesPresented = 0
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
        if let frame = video.frame { _ = view.present(frame) }
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
    private var format: CMVideoFormatDescription?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func clear() {
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        format = nil
    }

    func displayedFrameCount() async -> Int? {
        guard let metrics = await videoLayer.sampleBufferRenderer.videoPerformanceMetrics else {
            return nil
        }
        return max(0, metrics.totalNumberOfFrames - metrics.numberOfDroppedFrames)
    }

    func present(_ buffer: CVPixelBuffer) -> Bool {
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.status == .failed { clear() }
        guard renderer.isReadyForMoreMediaData else { return false }
        if format == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer)
        {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer, formatDescriptionOut: &format)
        }
        guard let format else { return false }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: true)
        else { return false }
        let dictionary = unsafeBitCast(
            CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        renderer.enqueue(sample)
        return true
    }
}
