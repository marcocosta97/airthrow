import AVFoundation
import Foundation
import VideoToolbox

/// System processors and models are never bundled with AirThrow.
@MainActor
public enum SuperResolutionSupport {
    public static func unavailableReason(_ backend: VideoUpscaler) -> String? {
        guard backend.isAI else { return nil }
        guard #available(macOS 26, *) else { return "AI Super Resolution requires macOS 26 or later." }
        let supported = backend == .standard ? VTSuperResolutionScalerConfiguration.isSupported
            : VTLowLatencySuperResolutionScalerConfiguration.isSupported
        return supported ? nil : "This Mac does not support this AI processor. Choose Lanczos."
    }

    public static var standardModelReady: Bool {
        guard #available(macOS 26, *), let configuration = standardConfiguration() else { return false }
        return configuration.configurationModelStatus == .ready
    }

    public static func downloadStandardModel() async throws {
        guard #available(macOS 26, *), let configuration = standardConfiguration() else {
            throw AppFailure(.unsupportedOperation, "AI Standard is unavailable on this Mac.")
        }
        if configuration.configurationModelStatus == .ready { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configuration.downloadConfigurationModel { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        guard configuration.configurationModelStatus == .ready else {
            throw AppFailure(.unsupportedOperation, "The AI Standard model is not ready. Try downloading it again.")
        }
    }

    @available(macOS 26, *)
    private static func standardConfiguration() -> VTSuperResolutionScalerConfiguration? {
        guard VTSuperResolutionScalerConfiguration.isSupported,
              let factor = VTSuperResolutionScalerConfiguration.supportedScaleFactors.first else { return nil }
        return VTSuperResolutionScalerConfiguration(frameWidth: 480, frameHeight: 270, scaleFactor: factor,
            inputType: .video, usePrecomputedFlow: false, qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }
}

struct SuperResolutionLayout: Sendable {
    let backend: VideoUpscaler
    let scale: Float
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int

    /// Normalize upward only. Never shrink the source to make an AI scale fit.
    @MainActor
    static func make(width: Int, height: Int, targetHeight: Int, backend: VideoUpscaler) throws -> Self {
        if let reason = SuperResolutionSupport.unavailableReason(backend) {
            throw AppFailure(.unsupportedOperation, reason)
        }
        guard #available(macOS 26, *), width > 0, height > 0,
              width.isMultiple(of: 2), height.isMultiple(of: 2), [1080, 2160].contains(targetHeight) else {
            throw AppFailure(.unsupportedOperation, "This source cannot use AI Super Resolution.")
        }
        let maximumWidth = targetHeight == 2160 ? 3840 : 1920
        let fit = min(Double(maximumWidth) / Double(width), Double(targetHeight) / Double(height))
        if backend == .lanczos {
            guard fit >= 1 else { throw PreparationFailure.conversionWouldDownscale }
            let outW = Int((Double(width) * fit).rounded(.down)) / 2 * 2
            let outH = Int((Double(height) * fit).rounded(.down)) / 2 * 2
            guard outW >= width, outH >= height else { throw PreparationFailure.conversionWouldDownscale }
            return Self(backend: backend, scale: Float(outH) / Float(height), inputWidth: width,
                inputHeight: height, outputWidth: outW, outputHeight: outH)
        }
        guard fit > 1 else {
            throw AppFailure(.unsupportedOperation, "AI needs a larger output than this source. Choose 4K or a smaller source.")
        }
        let factors: [Float]
        if backend == .standard {
            factors = VTSuperResolutionScalerConfiguration.supportedScaleFactors.map(Float.init)
        } else if #available(macOS 27, *) {
            factors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors
        } else {
            factors = [2]
        }
        for factor in factors.filter({ $0 > 1 && Double($0) <= fit + 0.0001 }).sorted(by: >) {
            let outW = Int((Double(width) * fit).rounded(.down)) / 2 * 2
            let outH = Int((Double(height) * fit).rounded(.down)) / 2 * 2
            // Packed UYVY rows in MOV use four-byte alignment. A width
            // divisible by four keeps AVFoundation's decoded size exact and
            // chooses the nearest aspect ratio within the output box.
            let inW = min(Int((Float(outW) / factor / 4).rounded()) * 4,
                          Int(Float(maximumWidth) / factor) / 4 * 4)
            let inH = Int(Float(outH) / factor) / 2 * 2
            guard inW >= width, inH >= height, inW <= 1920, inH <= 1080 else { continue }
            if backend == .lowLatency, #available(macOS 27, *),
                !VTLowLatencySuperResolutionScalerConfiguration.__supportedScaleFactors(forFrameWidth: inW, frameHeight: inH)
                    .contains(where: { abs($0.floatValue - factor) < 0.001 }) { continue }
            let actualW = Int((Float(inW) * factor).rounded())
            let actualH = Int((Float(inH) * factor).rounded())
            guard actualW.isMultiple(of: 2), actualH.isMultiple(of: 2),
                  actualW == maximumWidth || actualH == targetHeight else { continue }
            return Self(backend: backend, scale: factor, inputWidth: inW, inputHeight: inH,
                        outputWidth: actualW, outputHeight: actualH)
        }
        throw AppFailure(.unsupportedOperation, "This AI processor does not support this source and output combination on this Mac. Choose another output, a smaller source, or Lanczos.")
    }
}

/// Processes one bounded local clip. A new temporal session starts at each
/// independently regenerable chunk. No frames, model weights or media UI persist.
@MainActor
enum SuperResolutionEncoder {
    static func export(input: URL, output: URL, layout: SuperResolutionLayout,
                       seconds: Double, noiseReduction: CleanupNoiseReduction = .ffmpeg,
                       monitor: @Sendable () throws -> Void) async throws {
        guard #available(macOS 26, *) else { throw PreparationFailure.unsupported }
        try await exportAvailable(input: input, output: output, layout: layout, seconds: seconds, noiseReduction: noiseReduction, monitor: monitor)
    }

    @available(macOS 26, *)
    private static func exportAvailable(input: URL, output: URL, layout: SuperResolutionLayout,
                                        seconds: Double, noiseReduction: CleanupNoiseReduction,
                                        monitor: @Sendable () throws -> Void) async throws {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: output.path) else { throw PreparationFailure.failed }
        let processor = try PreparedVideoProcessor(layout: layout, noiseReduction: noiseReduction)
        defer { processor.end() }
        let sourceAttributes = processor.sourceAttributes
        let destinationAttributes = processor.destinationAttributes
        let sourcePool = try pool(attributes: sourceAttributes, width: layout.inputWidth, height: layout.inputHeight)
        let destinationPool = try pool(attributes: destinationAttributes, width: layout.outputWidth, height: layout.outputHeight)
        let format = try pixelFormat(sourceAttributes)
        let asset = AVURLAsset(url: input)
        guard try await !asset.load(.hasProtectedContent),
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw PreparationFailure.unsupported }
        let rate = try await track.load(.nominalFrameRate)
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        guard rate > 0, rate <= 60.01, duration.isFinite, duration > 0, duration <= 6.1,
              Int(size.width) == layout.inputWidth, Int(size.height) == layout.inputHeight else { throw PreparationFailure.failed }
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw PreparationFailure.failed }
        reader.add(readerOutput)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        var completed = false
        defer {
            reader.cancelReading()
            if !completed { writer.cancelWriting(); try? FileManager.default.removeItem(at: output) }
        }
        let fourK = layout.outputHeight > 1080 || layout.outputWidth > 1920
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: fourK ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: layout.outputWidth, AVVideoHeightKey: layout.outputHeight,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: fourK ? 14_000_000 : 4_000_000,
                AVVideoExpectedSourceFrameRateKey: rate, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: fourK ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        // Preserve fractional broadcast rates (23.976/29.97/59.94) rather
        // than rounding presentation times to AVAssetWriter's default scale.
        writerInput.mediaTimeScale = 120000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(writerInput) else { throw PreparationFailure.failed }
        writer.add(writerInput)
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr,
              let transfer else { throw PreparationFailure.failed }
        defer { VTPixelTransferSessionInvalidate(transfer) }
        guard reader.startReading(), writer.startWriting() else { throw PreparationFailure.failed }
        let deadline = Date().addingTimeInterval(seconds)
        var firstPTS: CMTime?
        var lastPTS = CMTime.zero
        var mediaEnd = CMTime.zero
        var lastMonitor = Date.distantPast
        var pending: [(source: CVPixelBuffer, pts: CMTime, duration: CMTime)] = []
        var readEnded = false
        var lastReadPTS: CMTime?
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw PreparationFailure.stalled }
            if Date().timeIntervalSince(lastMonitor) > 0.1 { try monitor(); lastMonitor = Date() }
            while pending.count <= processor.lookAhead && !readEnded {
                try Task.checkCancellation()
                guard Date() < deadline else { throw PreparationFailure.stalled }
                guard let sample = autoreleasepool(invoking: { readerOutput.copyNextSampleBuffer() }) else {
                    readEnded = true; break
                }
                guard let decoded = CMSampleBufferGetImageBuffer(sample) else { throw PreparationFailure.failed }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isNumeric, lastReadPTS == nil || CMTimeCompare(pts, lastReadPTS!) > 0 else { throw PreparationFailure.failed }
                lastReadPTS = pts
                let source = try await allocate(sourcePool, threshold: processor.sourceThreshold)
                guard VTPixelTransferSessionTransferImage(transfer, from: decoded, to: source) == noErr else { throw PreparationFailure.failed }
                CVBufferPropagateAttachments(decoded, source)
                guard CVPixelBufferFillExtendedPixels(source) == kCVReturnSuccess else { throw PreparationFailure.failed }
                pending.append((source, pts, CMSampleBufferGetDuration(sample)))
            }
            guard let item = pending.first else { break }
            let source = item.source, pts = item.pts
            guard firstPTS == nil || CMTimeCompare(pts, lastPTS) > 0 else { throw PreparationFailure.failed }
            if firstPTS == nil { firstPTS = pts; writer.startSession(atSourceTime: pts) }
            let destination = try await allocate(destinationPool)
            CVBufferPropagateAttachments(source, destination)
            let future = try pending.dropFirst().map { reference -> VTFrameProcessorFrame in
                guard let frame = VTFrameProcessorFrame(buffer: reference.source, presentationTimeStamp: reference.pts) else { throw PreparationFailure.failed }
                return frame
            }
            try await processor.process(source: source, destination: destination, pts: pts, next: future)
            let backpressureDeadline = Date().addingTimeInterval(10)
            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing, Date() < backpressureDeadline, Date() < deadline else { throw PreparationFailure.stalled }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(destination, withPresentationTime: pts) else { throw PreparationFailure.failed }
            lastPTS = pts
            let sampleDuration = item.duration
            mediaEnd = pts + (sampleDuration.isNumeric && sampleDuration.seconds > 0 ? sampleDuration
                : CMTime(seconds: 1 / Double(rate), preferredTimescale: 60000))
            pending.removeFirst()
        }
        guard reader.status == .completed, let firstPTS,
              abs((mediaEnd - firstPTS).seconds - duration) < 0.15 else { throw PreparationFailure.failed }
        writer.endSession(atSourceTime: mediaEnd)
        writerInput.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        try monitor()
        guard writer.status == .completed else { throw PreparationFailure.failed }
        completed = true
    }

    static func pixelFormat(_ attributes: [String: Any]) throws -> OSType {
        if let number = attributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber { return number.uint32Value }
        if let values = attributes[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber], let number = values.first { return number.uint32Value }
        throw PreparationFailure.unsupported
    }
    static func pool(attributes: [String: Any], width: Int, height: Int) throws -> CVPixelBufferPool {
        var values = attributes
        values[kCVPixelBufferWidthKey as String] = width
        values[kCVPixelBufferHeightKey as String] = height
        values[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        var result: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, values as CFDictionary, &result) == kCVReturnSuccess, let result else { throw PreparationFailure.failed }
        return result
    }
    static func allocate(_ pool: CVPixelBufferPool, threshold: Int = 8) async throws -> CVPixelBuffer {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            try Task.checkCancellation()
            var result: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey as String: threshold] as CFDictionary, &result)
            if status == kCVReturnSuccess, let result { return result }
            guard status == kCVReturnWouldExceedAllocationThreshold else { throw PreparationFailure.failed }
            try await Task.sleep(for: .milliseconds(2))
        } while Date() < deadline
        throw PreparationFailure.stalled
    }
}
