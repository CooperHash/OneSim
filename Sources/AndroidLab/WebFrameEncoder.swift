import CoreImage
import ImageIO
import IOSurface

/// Encodes each display independently. The controller submits at most one job
/// per display and takes the newest available frame when that job finishes.
enum WebFrameSource: @unchecked Sendable {
    case android(CGImage, UInt64)
    case ios(IOSurface)

    var stamp: UInt64 {
        switch self {
        case .android(_, let number): return number
        case .ios(let surface):
            return UInt64(IOSurfaceGetID(surface)) << 32 | UInt64(IOSurfaceGetSeed(surface))
        }
    }

    var dimensions: (Int, Int) {
        switch self {
        case .android(let image, _): return (image.width, image.height)
        case .ios(let surface): return (IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface))
        }
    }

    var image: CIImage {
        switch self {
        case .android(let image, _): return CIImage(cgImage: image)
        case .ios(let surface): return CIImage(ioSurface: surface)
        }
    }
}

final class WebFrameEncoder: Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func encode(_ source: WebFrameSource) -> Data? {
        let image = source.image
        let maximumDimension: CGFloat = 960
        let scale = min(1, maximumDimension / max(image.extent.width, image.extent.height))
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.jpegRepresentation(of: resized, colorSpace: colorSpace,
                                          options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.68])
    }
}

struct WebDeviceStatus: Encodable, Equatable, Sendable {
    let panel: Int
    var unavailableReason: String?
    var revision: UInt32?
    var width: Int?
    var height: Int?
    var rotation: Int = 0
    var orientation: Int = 0
    var density: Double?
    var angle: Double?
    var activeDisplay: String?
    var is3DPoseActive = false
    var hingeBusy = false
}
