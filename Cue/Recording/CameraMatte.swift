import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import CoreVideo

/// Person-segmentation + background compositing for the camera, shared by the
/// live preview pipeline (`CameraEngine`) and the offline compositor
/// (`CueVideoCompositor`). One instance is used from a single serial queue —
/// the Vision request is reused across frames, so don't share an instance
/// across threads; share the type and make one per consumer.
final class CameraMatte {

    private let request = VNGeneratePersonSegmentationRequest()

    /// `quality`: use `.fast` for the live preview (cheap, runs continuously)
    /// and `.balanced`/`.accurate` for the final export.
    init(quality: VNGeneratePersonSegmentationRequest.QualityLevel) {
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Returns the camera frame with its background replaced per `background`,
    /// in the pixel buffer's own coordinate space. `.none` (or a segmentation
    /// failure) returns the untouched frame so callers degrade gracefully.
    func composite(_ pixelBuffer: CVPixelBuffer, background: CameraBackground) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard background.removesBackground,
              let mask = personMask(for: pixelBuffer, matching: image.extent) else { return image }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.maskImage = mask
        blend.backgroundImage = backdrop(for: background, source: image)
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: Mask

    private func personMask(for pixelBuffer: CVPixelBuffer, matching extent: CGRect) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        // The mask is lower-resolution; stretch it to line up with the frame.
        let sx = extent.width / mask.extent.width
        let sy = extent.height / mask.extent.height
        return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    // MARK: Backdrops

    /// What sits behind the person for each mode (transparent → nothing).
    private func backdrop(for background: CameraBackground, source: CIImage) -> CIImage {
        switch background {
        case .none, .transparent:
            return CIImage.empty()
        case .blur:
            return source.clampedToExtent()
                .applyingGaussianBlur(sigma: max(8, source.extent.height * 0.04))
                .cropped(to: source.extent)
        case .gradient:
            return Self.gradient(in: source.extent)
        case .color:
            return CIImage(color: Self.solidColor).cropped(to: source.extent)
        }
    }

    /// A clean dark slate (not pure black) for the solid backdrop.
    private static let solidColor = CIColor(red: 0.12, green: 0.13, blue: 0.17)

    /// A tasteful vertical indigo→azure gradient for the gradient backdrop.
    private static func gradient(in rect: CGRect) -> CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: rect.midX, y: rect.minY)
        filter.color0 = CIColor(red: 0.13, green: 0.16, blue: 0.40)   // deep indigo (bottom)
        filter.point1 = CGPoint(x: rect.midX, y: rect.maxY)
        filter.color1 = CIColor(red: 0.26, green: 0.52, blue: 0.96)   // azure (top)
        return (filter.outputImage ?? CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.3)))
            .cropped(to: rect)
    }
}
