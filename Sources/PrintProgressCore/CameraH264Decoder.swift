import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox

/// Apple's hardware decoder. The connection's serial queue owns this instance.
final class CameraH264Decoder {
    private var sps = Data(), pps = Data()
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var lastOutput = Date.distantPast
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (CGImage) -> Void
    init(onFrame: @escaping @Sendable (CGImage) -> Void) { self.onFrame = onFrame }
    func parameterSets(_ sets: [Data]) throws {
        for nal in sets {
            guard let first = nal.first else { continue }
            if first & 31 == 7, sps != nal { sps = nal; reset() }
            if first & 31 == 8, pps != nal { pps = nal; reset() }
        }
        guard !sps.isEmpty, !pps.isEmpty, format == nil else { return }
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw PrinterCameraError.invalidStream }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 8192, dimensions.height <= 8192,
              Int64(dimensions.width) * Int64(dimensions.height) <= 16_777_216 else { throw PrinterCameraError.unsupported }
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, buffer, _, _ in
            guard status == noErr, let ref, let buffer else { return }
            let decoder = Unmanaged<CameraH264Decoder>.fromOpaque(ref).takeUnretainedValue()
            guard Date().timeIntervalSince(decoder.lastOutput) >= 0.1 else { return }
            decoder.lastOutput = .now
            let image = CIImage(cvPixelBuffer: buffer)
            if let cg = decoder.context.createCGImage(image, from: image.extent) { decoder.onFrame(cg) }
        }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session) == noErr else { throw PrinterCameraError.unsupported }
        if let session { VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
    }
    func decode(_ nals: [Data]) throws {
        try parameterSets(nals)
        guard let session, let format else { return }
        var bytes = Data()
        for nal in nals where nal.first.map({ [1, 5, 6, 9].contains(Int($0 & 31)) }) == true {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(nal)
        }
        guard !bytes.isEmpty else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw PrinterCameraError.invalidStream }
        let copied = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard copied == noErr else { throw PrinterCameraError.invalidStream }
        var sample: CMSampleBuffer?
        var size = bytes.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw PrinterCameraError.invalidStream }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        guard status == noErr else { throw PrinterCameraError.invalidStream }
    }
    func reset() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil; format = nil
    }
    deinit { reset() }
}
