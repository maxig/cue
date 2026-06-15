import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

// MARK: - Custom video compositor (background + padded screen + camera PiP)

final class CueVideoCompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let bubbleShape: CameraBubbleShape
    let corner: CameraCorner
    let cameraPlacement: CameraPlacement?
    let padding: CGFloat
    let background: CanvasBackground
    let mirrorBase: Bool
    let mirrorOverlay: Bool
    let cameraBackground: CameraBackground
    let cameraHiddenRanges: [ClosedRange<Double>]

    init(timeRange: CMTimeRange,
         screenTrackID: CMPersistentTrackID,
         cameraTrackID: CMPersistentTrackID,
         bubbleShape: CameraBubbleShape,
         corner: CameraCorner,
         cameraPlacement: CameraPlacement? = nil,
         padding: CGFloat,
         background: CanvasBackground,
         mirrorBase: Bool,
         mirrorOverlay: Bool,
         cameraBackground: CameraBackground = .none,
         cameraHiddenRanges: [ClosedRange<Double>] = []) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.bubbleShape = bubbleShape
        self.corner = corner
        self.cameraPlacement = cameraPlacement
        self.padding = padding
        self.background = background
        self.mirrorBase = mirrorBase
        self.mirrorOverlay = mirrorOverlay
        self.cameraBackground = cameraBackground
        self.cameraHiddenRanges = cameraHiddenRanges
        var ids = [NSNumber(value: screenTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }
}

final class CueVideoCompositor: NSObject, AVVideoCompositing {

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let renderQueue = DispatchQueue(label: "com.max.Cue.Compositor")
    private var maskCache: [String: CIImage] = [:]
    private var backgroundCache: [String: CIImage] = [:]

    /// Camera background compositing. Frames are processed serially on
    /// `renderQueue`, so a single matte (reused Vision request) is safe.
    private let matte = CameraMatte(quality: .balanced)

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [Int(kCVPixelFormatType_32BGRA)]
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { request.finish(with: RecordingError.compositionFailed("compositor gone")); return }
                guard let instruction = request.videoCompositionInstruction as? CueVideoCompositorInstruction,
                      let output = request.renderContext.newPixelBuffer() else {
                    request.finish(with: RecordingError.compositionFailed("no output buffer"))
                    return
                }
                let size = request.renderContext.size
                var result = self.background(instruction.background, size: size)

                if let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID) {
                    var image = CIImage(cvPixelBuffer: screenBuffer)
                    if instruction.mirrorBase { image = image.oriented(.upMirrored) }
                    if instruction.background.isVisible {
                        result = self.composeScreenWithPadding(image, padding: instruction.padding,
                                                               renderSize: size, over: result)
                    } else {
                        result = image.scaledToFill(size).composited(over: result)
                    }
                }

                let nowSeconds = request.compositionTime.seconds
                let cameraHidden = instruction.cameraHiddenRanges.contains { $0.contains(nowSeconds) }
                if instruction.cameraTrackID != kCMPersistentTrackID_Invalid, !cameraHidden,
                   let cameraBuffer = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
                    // Composite the chosen background first (segmentation runs in
                    // the source buffer's own orientation), THEN mirror, so the
                    // cutout and the picture stay aligned.
                    var camera = self.matte.composite(cameraBuffer, background: instruction.cameraBackground)
                    if instruction.mirrorOverlay { camera = camera.oriented(.upMirrored) }
                    let bubble = self.makeBubble(camera, shape: instruction.bubbleShape,
                                                 corner: instruction.corner,
                                                 placement: instruction.cameraPlacement, renderSize: size)
                    result = bubble.composited(over: result)
                }

                self.ciContext.render(result, to: output)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    // MARK: Background

    private func background(_ background: CanvasBackground, size: CGSize) -> CIImage {
        guard let stops = background.gradient else {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        }
        let key = "\(background.rawValue)-\(Int(size.width))x\(Int(size.height))"
        if let cached = backgroundCache[key] { return cached }
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: size.width / 2, y: 0)
        filter.color0 = CIColor(red: stops.bottom.0, green: stops.bottom.1, blue: stops.bottom.2)
        filter.point1 = CGPoint(x: size.width / 2, y: size.height)
        filter.color1 = CIColor(red: stops.top.0, green: stops.top.1, blue: stops.top.2)
        let image = (filter.outputImage ?? CIImage(color: .black))
            .cropped(to: CGRect(origin: .zero, size: size))
        backgroundCache[key] = image
        return image
    }

    // MARK: Padded screen (rounded + shadow)

    private func composeScreenWithPadding(_ screen: CIImage, padding: CGFloat,
                                          renderSize: CGSize, over background: CIImage) -> CIImage {
        let target = max(0.5, 1 - 2 * padding)
        let maxW = renderSize.width * target
        let maxH = renderSize.height * target
        // Aspect-FIT the screen inside the padded content box: when the source
        // aspect differs from the 16:9 canvas, the whole window stays visible
        // with gradient (never black) filling the remaining space.
        let ext = screen.extent
        let sAspect = ext.height > 0 ? ext.width / ext.height : (maxW / max(1, maxH))
        var sw = maxW
        var sh = sw / sAspect
        if sh > maxH { sh = maxH; sw = sh * sAspect }
        sw = sw.rounded()
        sh = sh.rounded()
        let ox = ((renderSize.width - sw) / 2).rounded()
        let oy = ((renderSize.height - sh) / 2).rounded()

        let scaled = screen.scaledToFill(CGSize(width: sw, height: sh))

        // With no padding (a pure aspect-fit fill) the screen sits flush — no
        // rounded card or shadow, just the screen on the gradient. With padding
        // it becomes a floating, rounded, shadowed card.
        guard padding > 0.015 else {
            let flush = scaled.cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh))
                .transformed(by: CGAffineTransform(translationX: ox, y: oy))
            return flush.composited(over: background)
        }

        let radius = max(8, sw * 0.018)
        let mask = roundedMask(width: sw, height: sh, radius: radius)

        let rounded = maskedImage(scaled, mask: mask, size: CGSize(width: sw, height: sh))
            .transformed(by: CGAffineTransform(translationX: ox, y: oy))

        // Soft drop shadow behind the screen.
        let shadowShape = maskedImage(
            CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                .cropped(to: CGRect(x: 0, y: 0, width: sw, height: sh)),
            mask: mask, size: CGSize(width: sw, height: sh)
        )
        .transformed(by: CGAffineTransform(translationX: ox, y: oy - renderSize.height * 0.006))
        .applyingGaussianBlur(sigma: max(10, renderSize.width * 0.010))
        .cropped(to: CGRect(origin: .zero, size: renderSize))

        return rounded.composited(over: shadowShape.composited(over: background))
    }

    // MARK: Camera bubble

    private func makeBubble(_ camera: CIImage, shape: CameraBubbleShape,
                            corner: CameraCorner, placement: CameraPlacement?,
                            renderSize: CGSize) -> CIImage {
        let diameter: CGFloat = {
            if let placement {
                let frac = CGFloat(min(max(placement.size, 0.05), 0.9))
                return max(80, (renderSize.width * frac)).rounded()
            }
            return max(renderSize.width * 0.22, 180).rounded()
        }()
        let extent = camera.extent
        let side = min(extent.width, extent.height)
        let cropRect = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
        let squared = camera
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        let scale = diameter / side
        let scaled = squared.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(x: 0, y: 0, width: diameter, height: diameter))

        let mask = roundedMask(width: diameter, height: diameter, radius: shape.cornerRadius(for: diameter))
        let masked = maskedImage(scaled, mask: mask, size: CGSize(width: diameter, height: diameter))

        let x: CGFloat
        let y: CGFloat
        if let placement {
            // Normalized center (top-left origin) → CI space (bottom-left origin),
            // clamped so the bubble stays fully on-frame.
            let cx = CGFloat(min(max(placement.centerX, 0), 1)) * renderSize.width
            let cyTop = CGFloat(min(max(placement.centerY, 0), 1)) * renderSize.height
            let rawX = cx - diameter / 2
            let rawY = (renderSize.height - cyTop) - diameter / 2     // flip Y
            x = min(max(rawX, 0), max(0, renderSize.width - diameter)).rounded()
            y = min(max(rawY, 0), max(0, renderSize.height - diameter)).rounded()
        } else {
            let margin = max(renderSize.width * 0.025, 24)
            switch corner {
            case .bottomLeft:  x = margin;                              y = margin
            case .bottomRight: x = renderSize.width - diameter - margin; y = margin
            case .topLeft:     x = margin;                              y = renderSize.height - diameter - margin
            case .topRight:    x = renderSize.width - diameter - margin; y = renderSize.height - diameter - margin
            }
        }
        return masked.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    // MARK: Helpers

    private func maskedImage(_ image: CIImage, mask: CIImage, size: CGSize) -> CIImage {
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func roundedMask(width: CGFloat, height: CGFloat, radius: CGFloat) -> CIImage {
        let key = "\(Int(width))x\(Int(height))-\(Int(radius))"
        if let cached = maskCache[key] { return cached }
        let w = Int(width), h = Int(height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        let mask = ctx.makeImage().map { CIImage(cgImage: $0) }
            ?? CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        maskCache[key] = mask
        return mask
    }
}

private extension CIImage {
    func scaledToFill(_ size: CGSize) -> CIImage {
        let ex = extent
        guard ex.width > 0, ex.height > 0 else { return self }
        let scale = max(size.width / ex.width, size.height / ex.height)
        let scaled = transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2
        let dy = (scaled.extent.height - size.height) / 2
        return scaled
            .transformed(by: CGAffineTransform(translationX: -scaled.extent.minX - dx,
                                               y: -scaled.extent.minY - dy))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}

// MARK: - Composer

enum VideoComposer {

    struct Output {
        let url: URL
        let size: CGSize
        /// Audio-only sidecar (`audio.m4a`) for transcription, when the clip has
        /// audio. Small and locked to the final timeline; uploaded alongside the
        /// video so the backend transcribes audio, not the whole movie.
        let audioURL: URL?
    }

    static func compose(screenURL: URL?,
                        cameraURL: URL?,
                        bubbleShape: CameraBubbleShape,
                        mirrored: Bool,
                        cameraBackground: CameraBackground = .none,
                        corner: CameraCorner,
                        padding: Double,
                        background: CanvasBackground,
                        aspectRatio: CGFloat?,
                        cameraStartOffset: Double?,
                        leadTrim: Double?,
                        cameraPlacement: CameraPlacement? = nil,
                        cameraHiddenRanges: [ClosedRange<Double>] = [],
                        screenPauseSpans: [ClosedRange<Double>] = [],
                        cameraPauseSpans: [ClosedRange<Double>] = [],
                        outputURL: URL) async throws -> Output {

        guard let baseVideoURL = screenURL ?? cameraURL else {
            throw RecordingError.compositionFailed("no video to compose")
        }
        let composition = AVMutableComposition()
        let baseAsset = AVURLAsset(url: baseVideoURL)

        guard let baseTrack = try await baseAsset.loadTracks(withMediaType: .video).first else {
            throw RecordingError.compositionFailed("no video track")
        }
        let baseDuration = try await baseAsset.load(.duration)
        let naturalSize = try await baseTrack.load(.naturalSize)
        let cameraIsBase = (screenURL == nil)

        // Decide the output frame. Target aspect is the requested ratio (e.g.
        // 16:9), or the source's own when "follow screen". When the source
        // doesn't match the target — OR a background is chosen — render onto a
        // gradient canvas and aspect-FIT the screen onto it, so the clip never
        // letterboxes to black in a player and the screen is never cropped.
        // Camera-only clips always keep their native frame.
        let screenAspect = naturalSize.height > 0 ? naturalSize.width / naturalSize.height : 16.0 / 9.0
        let targetAspect = cameraIsBase ? screenAspect : (aspectRatio ?? screenAspect)
        let aspectMismatch = abs(targetAspect - screenAspect) > 0.01
        let needsCanvas = !cameraIsBase && (background.isVisible || aspectMismatch)
        // Fill with the chosen background, or a default midnight gradient when
        // the screen just needs to be fit to the target aspect.
        let fillBackground: CanvasBackground = background.isVisible ? background : (needsCanvas ? .midnight : .none)
        // Respect the chosen padding exactly when a background is set (0 = the
        // screen grows to the frame edge, gradient only fills aspect-ratio gaps).
        // A pure aspect-fit (no background chosen) never adds margin.
        let effPadding: Double = background.isVisible ? padding : 0
        let renderSize = needsCanvas
            ? Self.renderSize(forSource: naturalSize, aspect: targetAspect, padding: effPadding)
            : CGSize(width: max(2, (naturalSize.width / 2).rounded() * 2),
                     height: max(2, (naturalSize.height / 2).rounded() * 2))

        // Trim the countdown/warm-up lead-in off the front of every stream, so
        // the clip begins exactly at content-start with all streams rolling.
        let lead = min(CMTime(seconds: max(0, leadTrim ?? 0), preferredTimescale: 600), baseDuration)

        // The base records continuously through pauses; cut those spans out (in
        // the base file's own timeline) so the clip has no dead air. Screen and
        // camera-only bases use their respective spans; the base audio below is
        // cut with the *same* spans so it stays locked to the picture.
        let baseSpans = cameraIsBase ? cameraPauseSpans : screenPauseSpans
        let baseVideoDuration = (try? await baseTrack.load(.timeRange).duration) ?? baseDuration

        guard let screenCompTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: 1) else {
            throw RecordingError.compositionFailed("video track alloc")
        }
        let contentDuration = try Self.insertExcised(
            baseTrack, into: screenCompTrack,
            from: CMTimeGetSeconds(lead), to: CMTimeGetSeconds(baseVideoDuration),
            spans: baseSpans, at: .zero)

        // Camera overlay (only when there's a separate screen base)
        var cameraTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
        if screenURL != nil, let cameraURL,
           FileManager.default.fileExists(atPath: cameraURL.path) {
            let cameraAsset = AVURLAsset(url: cameraURL)
            if let cameraTrack = try await cameraAsset.loadTracks(withMediaType: .video).first,
               let camComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 2) {
                let camDuration = try await cameraAsset.load(.duration)
                // Where the camera began relative to the screen (original
                // timeline), then shifted onto the trimmed timeline.
                let camStartOnBase = cameraStartOffset
                    ?? max(0, CMTimeGetSeconds(baseDuration) - CMTimeGetSeconds(camDuration))
                let camCompStart = camStartOnBase - CMTimeGetSeconds(lead)
                var camSourceStart = CMTime.zero
                var camInsertAt = CMTime.zero
                if camCompStart >= 0 {
                    // Camera started after content-start → small gap is correct.
                    camInsertAt = CMTime(seconds: camCompStart, preferredTimescale: 600)
                } else {
                    // Camera was already rolling at content-start → trim its head.
                    camSourceStart = CMTime(seconds: -camCompStart, preferredTimescale: 600)
                }
                // The camera rolls continuously through pauses, so cut the paused
                // spans out of the source and splice the remaining chunks back
                // together — matching the screen track (cut with the same spans)
                // so the PiP stays locked instead of freezing or drifting.
                let camEnd = try Self.insertExcised(
                    cameraTrack, into: camComp,
                    from: CMTimeGetSeconds(camSourceStart), to: CMTimeGetSeconds(camDuration),
                    spans: cameraPauseSpans, at: camInsertAt, limit: contentDuration)
                if camEnd > camInsertAt { cameraTrackID = camComp.trackID }
            }
        }

        // Audio comes straight from the base file, cut with the SAME lead-in and
        // paused spans as the base video so it stays perfectly locked, and capped
        // to the video length so there's no audio-only tail.
        try await addAudio(from: baseAsset, lead: lead, spans: baseSpans, limit: contentDuration,
                           composition: composition, workdir: outputURL.deletingLastPathComponent())

        // Video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CueVideoCompositor.self
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = renderSize
        videoComposition.instructions = [
            CueVideoCompositorInstruction(
                timeRange: CMTimeRange(start: .zero, duration: contentDuration),
                screenTrackID: screenCompTrack.trackID,
                cameraTrackID: cameraTrackID,
                bubbleShape: bubbleShape,
                corner: corner,
                cameraPlacement: cameraPlacement,
                padding: CGFloat(effPadding),
                background: cameraIsBase ? .none : fillBackground,   // no canvas behind a camera-only clip
                mirrorBase: mirrored && cameraIsBase,
                mirrorOverlay: mirrored && !cameraIsBase,
                cameraBackground: cameraBackground,
                cameraHiddenRanges: cameraHiddenRanges)
        ]

        // Export
        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.compositionFailed("exporter unavailable")
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw RecordingError.compositionFailed(export.error?.localizedDescription ?? "export failed")
        }

        // Audio-only sidecar for transcription. Exporting the same composition
        // with the AppleM4A preset yields just the (already lead-trimmed,
        // pause-excised, mixed) audio as a small .m4a — so the backend can
        // transcribe audio instead of pulling the full video.
        var audioURL: URL?
        if !composition.tracks(withMediaType: .audio).isEmpty {
            let candidate = outputURL.deletingLastPathComponent().appendingPathComponent("audio.m4a")
            if (try? await exportAudio(composition: composition, to: candidate)) == true {
                audioURL = candidate
            }
        }

        return Output(url: outputURL, size: renderSize, audioURL: audioURL)
    }

    /// Exports the composition's audio track to a standalone `.m4a` (AAC).
    private static func exportAudio(composition: AVComposition, to outputURL: URL) async throws -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        return export.status == .completed
    }

    /// Returns the sub-ranges of `[start, end]` that remain after removing
    /// `spans` — used to splice paused time out of the continuous camera track.
    private static func subtractSpans(from start: Double, to end: Double,
                                      spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard end > start else { return [] }
        guard !spans.isEmpty else { return [start...end] }
        var result: [ClosedRange<Double>] = []
        var cursor = start
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = max(start, span.lowerBound)
            let upper = min(end, span.upperBound)
            if upper <= cursor { continue }                  // entirely behind the cursor
            if lower > cursor { result.append(cursor...lower) } // active chunk before this pause
            cursor = max(cursor, upper)
        }
        if cursor < end { result.append(cursor...end) }
        return result
    }

    /// Canvas frame sized so the source fits at `1 - 2·padding` of a frame with
    /// the given `aspect` (w/h), preserving source resolution.
    private static func renderSize(forSource natural: CGSize, aspect: CGFloat, padding: Double) -> CGSize {
        func even(_ s: CGSize) -> CGSize {
            CGSize(width: max(2, (s.width / 2).rounded() * 2),
                   height: max(2, (s.height / 2).rounded() * 2))
        }
        guard natural.width > 0, natural.height > 0, aspect > 0 else { return even(natural) }
        let target = max(0.5, 1 - 2 * CGFloat(padding))
        let sAspect = natural.width / natural.height
        var cw: CGFloat
        var ch: CGFloat
        if sAspect >= aspect {
            cw = natural.width / target
            ch = cw / aspect
        } else {
            ch = natural.height / target
            cw = ch * aspect
        }
        let maxDim: CGFloat = 3840
        let longest = max(cw, ch)
        if longest > maxDim { let r = maxDim / longest; cw *= r; ch *= r }
        return even(CGSize(width: cw, height: ch))
    }

    /// Inserts one audio track into the composition. One source track passes
    /// through; two or more are mixed (sync-preserving) via AVAssetReader. The
    /// front `lead` seconds and the paused `spans` are cut out — exactly as the
    /// base video — so the audio stays locked to the picture.
    private static func addAudio(from asset: AVURLAsset, lead: CMTime, spans: [ClosedRange<Double>],
                                 limit: CMTime, composition: AVMutableComposition, workdir: URL) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty,
              let audioComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 3) else {
            return
        }
        func insert(_ track: AVAssetTrack) async {
            let dur = (try? await track.load(.timeRange).duration) ?? .zero
            _ = try? insertExcised(track, into: audioComp,
                                   from: CMTimeGetSeconds(lead), to: CMTimeGetSeconds(dur),
                                   spans: spans, at: .zero, limit: limit)
        }

        if audioTracks.count == 1 {
            await insert(audioTracks[0])
            return
        }

        // Mix system + mic into one track, preserving each track's timing.
        let mixedURL = workdir.appendingPathComponent("mixed.caf")
        try await AudioMixer.mixTracks(asset: asset, tracks: audioTracks, to: mixedURL)
        let mixedAsset = AVURLAsset(url: mixedURL)
        if let mixedTrack = try await mixedAsset.loadTracks(withMediaType: .audio).first {
            await insert(mixedTrack)
        }
    }

    /// Splices `source[startSec...endSec]` into `comp` starting at `at`, cutting
    /// out `spans` (all in the source's own seconds) and butting the kept chunks
    /// together. Optionally stops once the composition reaches `limit`. Returns
    /// the end position in the composition.
    @discardableResult
    private static func insertExcised(_ source: AVAssetTrack, into comp: AVMutableCompositionTrack,
                                      from startSec: Double, to endSec: Double,
                                      spans: [ClosedRange<Double>], at start: CMTime,
                                      limit: CMTime? = nil) throws -> CMTime {
        var pos = start
        for range in subtractSpans(from: startSec, to: endSec, spans: spans) {
            var chunk = range.upperBound - range.lowerBound
            if let limit {
                let remaining = CMTimeGetSeconds(limit - pos)
                if remaining <= 0 { break }
                chunk = min(chunk, remaining)
            }
            if chunk <= 0 { continue }
            let src = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                  duration: CMTime(seconds: chunk, preferredTimescale: 600))
            try comp.insertTimeRange(src, of: source, at: pos)
            pos = pos + CMTime(seconds: chunk, preferredTimescale: 600)
        }
        return pos
    }
}

// MARK: - Sync-preserving track mixer

enum AudioMixer {

    /// Mixes the given audio tracks of `asset` into a single PCM `.caf` using
    /// `AVAssetReaderAudioMixOutput`, which respects each track's presentation
    /// timing — so the mix stays locked to the video.
    static func mixTracks(asset: AVAsset, tracks: [AVAssetTrack], to outputURL: URL) async throws {
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
        guard reader.canAdd(mixOutput) else { throw RecordingError.compositionFailed("audio mix output") }
        reader.add(mixOutput)

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .caf)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw RecordingError.compositionFailed("audio writer input") }
        writer.add(writerInput)

        guard reader.startReading() else { throw RecordingError.compositionFailed("audio reader start") }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let q = DispatchQueue(label: "com.max.Cue.AudioMixer")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: q) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = mixOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting { continuation.resume() }
                        return
                    }
                }
            }
        }
    }
}
