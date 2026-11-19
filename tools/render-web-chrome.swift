import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

for id in [12, 14, 15] {
    let name = "phone\(id)"
    let path = source.appendingPathComponent(name + ".pdf")
    guard let page = CGPDFDocument(path as CFURL)?.page(at: 1) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let bounds = page.getBoxRect(.mediaBox)
    let scale = 1_600 / max(bounds.width, bounds.height)
    let width = Int((bounds.width * scale).rounded(.up))
    let height = Int((bounds.height * scale).rounded(.up))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw CocoaError(.fileWriteUnknown)
    }
    context.concatenate(page.getDrawingTransform(.mediaBox,
                                                  rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                  rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    let url = destination.appendingPathComponent(name + ".png")
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[y * context.bytesPerRow + x * 4 + 3] != 0 {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard !crop.isEmpty, let image = context.makeImage()?.cropping(to: crop),
          let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
}
