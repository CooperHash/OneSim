import CoreImage
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

/// A panel's compression session is used by one in-flight submission at a time.
final class WebH264Encoder: @unchecked Sendable {
    struct Frame: Sendable {
        let bytes: Data
        let isKey: Bool
        let sequence: UInt32
    }

    private var session: VTCompressionSession?
    private var dimensions: (Int, Int)?
    private var sequence: UInt32 = 0
    private var surfaceBuffer: (IOSurfaceID, CVPixelBuffer)?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func encode(_ source: WebFrameSource, forceKey: Bool) -> Frame? {
        let (inputWidth, inputHeight) = source.dimensions
        let scale = min(1, 960 / Double(max(inputWidth, inputHeight)))
        let width = max(2, Int(Double(inputWidth) * scale) & ~1)
        let height = max(2, Int(Double(inputHeight) * scale) & ~1)
        let target = (width, height)
        var forceKey = forceKey
        if dimensions?.0 != width || dimensions?.1 != height {
            if let session { VTCompressionSessionInvalidate(session) }
            session = Self.createSession(width: width, height: height)
            dimensions = target
            forceKey = true
        }
        guard let session, let buffer = pixelBuffer(source, session: session, width: width, height: height) else { return nil }

        sequence &+= 1
        let timestamp = CMTime(value: Int64(sequence), timescale: 60)
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let result = Output()
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer,
            presentationTimeStamp: timestamp, duration: .invalid, frameProperties: properties,
            infoFlagsOut: nil) { status, flags, sample in
                guard status == noErr, !flags.contains(.frameDropped), let sample else { return }
                result.set(Self.annexB(sample))
            }
        guard status == noErr,
              VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: timestamp) == noErr,
              let (bytes, key) = result.get() else { return nil }
        return Frame(bytes: bytes, isKey: key, sequence: sequence)
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    private func pixelBuffer(_ source: WebFrameSource, session: VTCompressionSession, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        switch source {
        case .ios(let surface):
            let id = IOSurfaceGetID(surface)
            if let (previousID, previousBuffer) = surfaceBuffer, previousID == id { return previousBuffer }
            var wrapped: Unmanaged<CVPixelBuffer>?
            guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &wrapped) == kCVReturnSuccess,
                  let buffer = wrapped?.takeRetainedValue() else { return nil }
            surfaceBuffer = (id, buffer)
            return buffer
        case .android(let image, _):
            if let pool = VTCompressionSessionGetPixelBufferPool(session) {
                _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            }
            if buffer == nil {
                let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
                _ = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                        attributes, &buffer)
            }
            guard let buffer else { return nil }
            let frame = CIImage(cgImage: image).transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / CGFloat(image.width), y: CGFloat(height) / CGFloat(image.height)
            ))
            context.render(frame, to: buffer)
            return buffer
        }
    }

    private static func createSession(width: Int, height: Int) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: bufferAttributes as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        let averageBitRate = 1_650_000
        let dataRateLimits = [averageBitRate * 3 / 2 / 8, 1] as CFArray
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue as Any,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse as Any,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: kCFBooleanTrue as Any,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 90,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1.5,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_AverageBitRate: averageBitRate,
            kVTCompressionPropertyKey_DataRateLimits: dataRateLimits,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        return session
    }

    private static let startCode = Data([0, 0, 0, 1])

    private static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var setCount = 0
        var lengthBytes: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &setCount,
                nalUnitHeaderLengthOut: &lengthBytes) == noErr, (1...4).contains(lengthBytes) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        guard avcc.withUnsafeMutableBytes({ raw in
            guard let address = raw.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: address) == noErr
        }) else { return nil }

        var units: [Range<Int>] = []
        var key = false
        var offset = 0
        while offset + Int(lengthBytes) < length {
            let size = avcc[offset..<(offset + Int(lengthBytes))].reduce(0) { ($0 << 8) | Int($1) }
            offset += Int(lengthBytes)
            guard size > 0, size <= length - offset else { return nil }
            key = key || (avcc[offset] & 0x1f) == 5
            units.append(offset..<(offset + size))
            offset += size
        }
        guard !units.isEmpty, offset == length else { return nil }
        var payload = Data()
        if key {
            for index in 0..<setCount {
                var bytes: UnsafePointer<UInt8>?
                var count = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                        parameterSetPointerOut: &bytes, parameterSetSizeOut: &count,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let bytes else { return nil }
                payload.append(startCode)
                payload.append(bytes, count: count)
            }
        }
        for unit in units {
            payload.append(startCode)
            payload.append(avcc[unit])
        }
        return (payload, key)
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: (Data, Bool)?

        func set(_ value: (Data, Bool)?) { lock.withLock { frame = value } }
        func get() -> (Data, Bool)? { lock.withLock { frame } }
    }
}
