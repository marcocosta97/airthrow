import AVFoundation
import CoreImage
import Darwin
import Foundation
import VideoToolbox

// Developer-only feasibility tool, independent of the playback session.
struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var probe = false
    var backend = "low-latency"
    var scale: Float = 2
    var frames = 180
    var input: URL?
    var output: URL?
    var downloadModel = false
    var pixelRange = "auto"
    var diagnostics = false
    var model: URL?
    var compute = "all"
    var noiseStrength: Float = 0.5
    var allowRawInput = false

    init(_ arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            let flag = arguments[i]
            if flag == "--probe" { probe = true }
            else if flag == "--download-model" { downloadModel = true }
            else if flag == "--diagnostics" { diagnostics = true }
            else if flag == "--allow-raw-input" { allowRawInput = true }
            else {
                guard i + 1 < arguments.count else { throw BenchError("Missing value for \(flag)") }
                i += 1
                let value = arguments[i]
                switch flag {
                case "--backend": backend = value
                case "--scale": scale = Float(value) ?? .nan
                case "--frames": frames = Int(value) ?? 0
                case "--pixel-range": pixelRange = value
                case "--input": input = URL(fileURLWithPath: value)
                case "--output": output = URL(fileURLWithPath: value)
                case "--model": model = URL(fileURLWithPath: value)
                case "--compute": compute = value
                case "--noise-strength": noiseStrength = Float(value) ?? .nan
                default: throw BenchError("Unknown option: \(flag)")
                }
            }
            i += 1
        }
        guard ["standard", "low-latency", "lanczos", "coreml", "denoise-lanczos", "denoise-low-latency"].contains(backend),
              noiseStrength.isFinite, (0...1).contains(noiseStrength),
              ["all", "ane", "gpu"].contains(compute),
              backend != "coreml" || (model != nil && [1, 2].contains(scale)),
              ["auto", "video", "full"].contains(pixelRange),
              backend != "standard" || pixelRange == "auto",
              scale.isFinite, scale >= 1, scale <= 4,
              scale > 1 || ["coreml", "lanczos", "denoise-lanczos"].contains(backend), (12...1800).contains(frames) else {
            throw BenchError("Invalid backend, scale (1 <= scale <= 4), or frame limit (12...1800)")
        }
        guard probe || (input != nil && output != nil) else {
            throw BenchError("Use --probe, or --input FILE --output NEW.mp4 [--backend low-latency|standard|lanczos] [--scale 2] [--frames 180]. Models download only with --download-model.")
        }
        if let output, FileManager.default.fileExists(atPath: output.path) {
            throw BenchError("Output already exists; refusing to replace it")
        }
    }
}

func emit(_ dictionary: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

func usage() -> rusage {
    var value = rusage()
    getrusage(RUSAGE_SELF, &value)
    return value
}

func cpuSeconds(_ value: rusage) -> Double {
    Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}

@available(macOS 26, *)
@MainActor
final class Scaler {
    let backend: String
    let scale: Float
    let pixelRange: String
    let context = CIContext(options: [.cacheIntermediates: false])
    let processor = VTFrameProcessor()
    var started = false
    var previousSource: VTFrameProcessorFrame?
    var previousOutput: VTFrameProcessorFrame?
    var sourceAttributes: [String: Any] = [:]
    var destinationAttributes: [String: Any] = [:]
    var ml: MLImageScaler?
    var cleaner: TemporalCleaner?
    var postScaler: Scaler?
    var cleanTransfer: VTPixelTransferSession?
    var cleanSourcePool: CVPixelBufferPool?
    var lookAhead: Int { cleaner?.nextCount ?? 0 }
    var sourceThreshold: Int { max(8, lookAhead + (cleaner?.previousCount ?? 0) + 3) }

    init(backend: String, scale: Float, pixelRange: String) {
        self.backend = backend; self.scale = scale; self.pixelRange = pixelRange
    }

    func configure(width: Int, height: Int, downloadModel: Bool, model: URL? = nil, compute: String = "all", noiseStrength: Float = 0.5) async throws {
        if backend.hasPrefix("denoise-") {
            let noise = try TemporalCleaner(width: width, height: height, strength: noiseStrength)
            cleaner = noise
            let post = Scaler(backend: String(backend.dropFirst(8)), scale: scale, pixelRange: pixelRange)
            postScaler = post
            try await post.configure(width: width, height: height, downloadModel: false)
            sourceAttributes = noise.configuration.sourcePixelBufferAttributes
            destinationAttributes = post.destinationAttributes
            cleanSourcePool = try makePool(attributes: post.sourceAttributes, width: width, height: height)
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &cleanTransfer) == noErr else {
                throw BenchError("Cannot create temporal post-filter transfer")
            }
            return
        }
        if backend == "coreml", let model {
            sourceAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            destinationAttributes = sourceAttributes
            ml = try MLImageScaler(url: model, compute: compute, width: width, height: height, outputScale: Int(scale))
            return
        }
        let configuration: any VTFrameProcessorConfiguration
        if backend == "standard" {
            guard VTSuperResolutionScalerConfiguration.isSupported,
                  VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(Int(scale)),
                  scale.rounded() == scale,
                  let standard = VTSuperResolutionScalerConfiguration(
                    frameWidth: width, frameHeight: height, scaleFactor: Int(scale), inputType: .video,
                    usePrecomputedFlow: false, qualityPrioritization: .normal,
                    revision: VTSuperResolutionScalerConfiguration.defaultRevision) else {
                throw BenchError("Standard backend does not support these dimensions or scale")
            }
            if standard.configurationModelStatus != .ready {
                guard downloadModel else { throw BenchError("Model not ready; use --download-model explicitly to request the Apple model") }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    standard.downloadConfigurationModel { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                guard standard.configurationModelStatus == .ready else { throw BenchError("Model is still unavailable") }
            }
            sourceAttributes = standard.sourcePixelBufferAttributes
            destinationAttributes = standard.destinationPixelBufferAttributes
            configuration = standard
        } else {
            // Lanczos uses the same pixel layout as the low-latency comparison when possible.
            guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
                  VTLowLatencySuperResolutionScalerConfiguration.__supportedScaleFactors(forFrameWidth: width, frameHeight: height)
                    .contains(where: { abs($0.floatValue - scale) < 0.001 }) else {
                if backend == "lanczos" {
                    sourceAttributes = [kCVPixelBufferPixelFormatTypeKey as String: pixelRange == "full"
                        ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                    destinationAttributes = sourceAttributes
                    return
                }
                throw BenchError("Low-latency backend does not support these dimensions or scale")
            }
            let low = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: scale)
            sourceAttributes = low.sourcePixelBufferAttributes
            destinationAttributes = low.destinationPixelBufferAttributes
            if pixelRange != "auto" {
                let requested = pixelRange == "full" ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                guard backend == "lanczos" || low.supportedPixelFormats.contains(requested) else { throw BenchError("Requested pixel range is unsupported") }
                sourceAttributes[kCVPixelBufferPixelFormatTypeKey as String] = requested
                destinationAttributes[kCVPixelBufferPixelFormatTypeKey as String] = requested
            }
            configuration = low
        }
        if backend != "lanczos" {
            try processor.startSession(configuration: configuration)
            started = true
        }
    }

    func end() {
        cleaner?.end(); postScaler?.end()
        if let cleanTransfer { VTPixelTransferSessionInvalidate(cleanTransfer) }
        if started { processor.endSession(); started = false }
    }

    func process(source: CVPixelBuffer, destination: CVPixelBuffer, pts: CMTime, next: [VTFrameProcessorFrame] = []) async throws {
        if let cleaner, let postScaler, let cleanSourcePool, let cleanTransfer {
            let clean = try await cleaner.process(source: source, pts: pts, next: next)
            let postSource = try await allocate(cleanSourcePool)
            guard VTPixelTransferSessionTransferImage(cleanTransfer, from: clean, to: postSource) == noErr else {
                throw BenchError("Temporal post-filter pixel transfer failed")
            }
            CVBufferPropagateAttachments(clean, postSource)
            guard CVPixelBufferFillExtendedPixels(postSource) == kCVReturnSuccess else { throw BenchError("Cannot fill cleaned source padding") }
            try await postScaler.process(source: postSource, destination: destination, pts: pts)
            return
        }
        if let ml { try await ml.process(source: source, destination: destination); return }
        if backend == "lanczos" {
            let scaled = CIImage(cvPixelBuffer: source, options: [.colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!]).applyingFilter("CILanczosScaleTransform",
                parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            context.render(scaled, to: destination, bounds: CGRect(x: 0, y: 0,
                width: CVPixelBufferGetWidth(destination), height: CVPixelBufferGetHeight(destination)),
                colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            return
        }
        guard let current = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
              let output = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts) else {
            throw BenchError("Invalid frame buffers")
        }
        if backend == "standard" {
            guard let parameters = VTSuperResolutionScalerParameters(sourceFrame: current,
                previousFrame: previousSource, previousOutputFrame: previousOutput, opticalFlow: nil,
                submissionMode: previousSource == nil ? .random : .sequential, destinationFrame: output) else {
                throw BenchError("Invalid standard frame parameters")
            }
            try await processor.process(parameters: parameters)
            // Only the previous input/output pair is retained, never the whole clip.
            previousSource = current
            previousOutput = output
        } else {
            try await processor.process(parameters: VTLowLatencySuperResolutionScalerParameters(
                sourceFrame: current, destinationFrame: output))
        }
    }
}

func pixelFormat(_ attributes: [String: Any]) throws -> OSType {
    let value = attributes[kCVPixelBufferPixelFormatTypeKey as String]
    if let number = value as? NSNumber { return number.uint32Value }
    if let values = value as? [NSNumber], let number = values.first { return number.uint32Value }
    throw BenchError("Configuration returned no usable pixel format")
}

// Read first-frame flat-patch samples before encoding to separate processing from mux/codec errors.
func patchSamples(_ buffer: CVPixelBuffer) -> [[String: Any]] {
    guard CVPixelBufferGetPlaneCount(buffer) == 2,
          [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            .contains(CVPixelBufferGetPixelFormatType(buffer)) else { return [] }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    return (0..<6).map { patch in
        let x = (w * (2 * patch + 1) / 12) & ~1
        let y = (h / 4) & ~1
        var luma: [Double] = [], cb: [Double] = [], cr: [Double] = []
        for dy in 0..<8 { for dx in 0..<8 {
            luma.append(Double(yPlane[(y + dy) * yStride + x + dx]))
            let offset = ((y + dy) / 2) * uvStride + ((x + dx) / 2) * 2
            cb.append(Double(uvPlane[offset])); cr.append(Double(uvPlane[offset + 1]))
        } }
        let mean = luma.reduce(0, +) / Double(luma.count)
        return ["patch": patch, "yMean": mean,
            "yStdDev": sqrt(luma.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(luma.count)),
            "cbMean": cb.reduce(0, +) / Double(cb.count), "crMean": cr.reduce(0, +) / Double(cr.count)]
    }
}

func colorMetadata(_ buffer: CVPixelBuffer) -> [String: Any] {
    let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
    var result: [String: Any] = ["pixelFormat": CVPixelBufferGetPixelFormatType(buffer)]
    for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
        result[key as String] = attachments[key as String] as? String ?? "absent"
    }
    return result
}

func makePool(attributes: [String: Any], width: Int, height: Int) throws -> CVPixelBufferPool {
    var resolved = attributes
    resolved[kCVPixelBufferPixelFormatTypeKey as String] = try pixelFormat(attributes)
    resolved[kCVPixelBufferWidthKey as String] = width
    resolved[kCVPixelBufferHeightKey as String] = height
    resolved[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil, nil, resolved as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw BenchError("Cannot allocate pixel pool: \(status)") }
    return pool
}

@MainActor
func allocate(_ pool: CVPixelBufferPool, threshold: Int = 8) async throws -> CVPixelBuffer {
    let deadline = Date().addingTimeInterval(10)
    repeat {
        try Task.checkCancellation()
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey as String: threshold] as CFDictionary, &buffer)
        if status == kCVReturnSuccess, let buffer { return buffer }
        guard status == kCVReturnWouldExceedAllocationThreshold else { throw BenchError("Pixel allocation failed: \(status)") }
        try await Task.sleep(for: .milliseconds(2))
    } while Date() < deadline
    throw BenchError("Encoder retained too many buffers")
}

@available(macOS 26, *)
@MainActor
func benchmark(_ options: Options) async throws {
    let asset = AVURLAsset(url: options.input!)
    guard try await !asset.load(.hasProtectedContent),
          let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw BenchError("A readable, unprotected video track is required")
    }
    let duration = try await asset.load(.duration).seconds
    let rate = try await track.load(.nominalFrameRate)
    let transform = try await track.load(.preferredTransform)
    guard duration.isFinite, duration > 0, rate > 0, rate <= 30,
          transform == .identity else { throw BenchError("Use finite, unrotated video at 1...30 fps") }
    let descriptions = try await track.load(.formatDescriptions)
    guard let format = descriptions.first else { throw BenchError("Unknown video format") }
    guard let metadata = CMFormatDescriptionGetExtensions(format) else { throw BenchError("Missing color metadata") }
    let extensions = metadata as NSDictionary
    let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String
    let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries] as? String
    let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
    let aspect = extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary
    let horizontal = (aspect?[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber)?.intValue ?? 1
    let vertical = (aspect?[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber)?.intValue ?? 1
    let fields = (extensions[kCMFormatDescriptionExtension_FieldCount] as? NSNumber)?.intValue ?? 1
    let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
    let avc = atoms?["avcC"] as? Data
    let subtype = CMFormatDescriptionGetMediaSubType(format)
    let h264 = subtype == kCMVideoCodecType_H264 && avc.map { $0.count > 1 && [66, 77, 88, 100].contains(Int($0[1])) } == true
    // Explicitly gated uncompressed 8-bit UYVY intermediates avoid a lossy
    // encode between FFmpeg cleanup and the paired native encoder.
    let raw = options.allowRawInput && subtype == kCVPixelFormatType_422YpCbCr8
    guard transfer == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
          primaries == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
          matrix == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String,
          horizontal == vertical, fields == 1,
          h264 || raw else {
        throw BenchError("Prototype requires progressive square-pixel 8-bit BT.709 SDR H.264 input")
    }
    let size = CMVideoFormatDescriptionGetDimensions(format)
    let width = Int(size.width), height = Int(size.height)
    let outWidth = Int((Float(width) * options.scale).rounded())
    let outHeight = Int((Float(height) * options.scale).rounded())
    guard width > 0, height > 0, width <= 1920, height <= 1080,
          outWidth <= 3840, outHeight <= 2160, outWidth % 2 == 0, outHeight % 2 == 0 else {
        throw BenchError("Dimensions exceed prototype limits (1080p input, 4K output, even dimensions)")
    }
    let scaler = Scaler(backend: options.backend, scale: options.scale, pixelRange: options.pixelRange)
    defer { scaler.end() }
    let setupStart = Date()
    try await scaler.configure(width: width, height: height, downloadModel: options.downloadModel,
        model: options.model, compute: options.compute, noiseStrength: options.noiseStrength)
    let setupSeconds = Date().timeIntervalSince(setupStart)
    let sourcePool = try makePool(attributes: scaler.sourceAttributes, width: width, height: height)
    var transferSession: VTPixelTransferSession?
    guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession) == noErr,
          let transferSession else { throw BenchError("Cannot create pixel transfer session") }
    defer { VTPixelTransferSessionInvalidate(transferSession) }
    let pool = try makePool(attributes: scaler.destinationAttributes, width: outWidth, height: outHeight)
    let reader = try AVAssetReader(asset: asset)
    let readOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: try pixelFormat(scaler.sourceAttributes),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ])
    readOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readOutput) else { throw BenchError("Reader cannot decode this video") }
    reader.add(readOutput)
    let output = options.output!
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    var completed = false
    defer {
        reader.cancelReading()
        if !completed { writer.cancelWriting(); try? FileManager.default.removeItem(at: output) }
    }
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: outHeight > 1080 || outWidth > 1920 ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
        AVVideoWidthKey: outWidth, AVVideoHeightKey: outHeight,
        AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: outWidth * outHeight * 6,
            AVVideoExpectedSourceFrameRateKey: rate, AVVideoMaxKeyFrameIntervalKey: Int(rate * 2),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: outHeight > 1080 || outWidth > 1920 ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel],
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
        sourcePixelBufferAttributes: nil)
    guard writer.canAdd(writerInput) else { throw BenchError("Writer does not support this output") }
    writer.add(writerInput)
    guard reader.startReading(), writer.startWriting() else { throw BenchError("Cannot start decode/encode") }
    let startUsage = usage(), wallStart = Date()
    var frameTimes: [Double] = []
    var firstPTS: CMTime?
    var lastPTS = CMTime.zero, mediaEnd = CMTime.zero
    var firstFrameSeconds: Double = 0
    var warmWallStart: Date?
    var warmMediaStart: CMTime?
    var diagnostics: [String: Any] = [:]
    // Retain only the processor's bounded look-ahead window and past references.
    var pending: [(decoded: CVPixelBuffer, source: CVPixelBuffer, pts: CMTime, duration: CMTime)] = []
    var readFrames = 0
    var readEnded = false
    while frameTimes.count < options.frames {
        try Task.checkCancellation()
        while pending.count <= scaler.lookAhead && readFrames < options.frames && !readEnded {
            guard let sample = autoreleasepool(invoking: { readOutput.copyNextSampleBuffer() }) else { readEnded = true; break }
            guard let decoded = CMSampleBufferGetImageBuffer(sample) else { throw BenchError("Decoder returned no image") }
            let source = try await allocate(sourcePool, threshold: scaler.sourceThreshold)
            guard VTPixelTransferSessionTransferImage(transferSession, from: decoded, to: source) == noErr else {
                throw BenchError("Source pixel transfer failed")
            }
            CVBufferPropagateAttachments(decoded, source)
            guard CVPixelBufferFillExtendedPixels(source) == kCVReturnSuccess else { throw BenchError("Cannot fill source padding") }
            pending.append((decoded, source, CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample)))
            readFrames += 1
        }
        guard let item = pending.first else { break }
        let decoded = item.decoded, source = item.source, pts = item.pts
        guard pts.isNumeric, firstPTS == nil || CMTimeCompare(pts, lastPTS) > 0 else { throw BenchError("Non-monotonic timestamps") }
        if firstPTS == nil { firstPTS = pts; writer.startSession(atSourceTime: pts) }
        if frameTimes.count == 10 { warmWallStart = Date(); warmMediaStart = pts }
        let destination = try await allocate(pool)
        CVBufferPropagateAttachments(source, destination)
        let frameStart = Date()
        let future = try pending.dropFirst().map { item -> VTFrameProcessorFrame in
            guard let frame = VTFrameProcessorFrame(buffer: item.source, presentationTimeStamp: item.pts) else {
                throw BenchError("Cannot construct future reference")
            }
            return frame
        }
        try await scaler.process(source: source, destination: destination, pts: pts, next: future)
        frameTimes.append(Date().timeIntervalSince(frameStart))
        if options.diagnostics && frameTimes.count == 1 {
            diagnostics = ["decoded": patchSamples(decoded), "processorInput": patchSamples(source),
                "processorOutputBeforeEncoding": patchSamples(destination),
                "decodedColor": colorMetadata(decoded), "processorInputColor": colorMetadata(source),
                "processorOutputColor": colorMetadata(destination)]
        }
        // Match Apple's sample: restore source color attachments after processing as well.
        CVBufferPropagateAttachments(source, destination)
        let deadline = Date().addingTimeInterval(10)
        while !writerInput.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else { throw BenchError("Encoder stalled or failed") }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard adaptor.append(destination, withPresentationTime: pts) else { throw BenchError("Encoding failed") }
        if frameTimes.count == 1 { firstFrameSeconds = Date().timeIntervalSince(wallStart) }
        lastPTS = pts
        let sampleDuration = item.duration
        mediaEnd = pts + (sampleDuration.isNumeric && sampleDuration.seconds > 0 ? sampleDuration : CMTime(seconds: 1 / Double(rate), preferredTimescale: 60000))
        pending.removeFirst()
    }
    guard reader.status != .failed, let firstPTS, frameTimes.count >= 12 else { throw BenchError("Not enough decoded frames or decoding failed") }
    writer.endSession(atSourceTime: mediaEnd)
    writerInput.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw BenchError("Output finalization failed") }
    completed = true
    let wallSeconds = Date().timeIntervalSince(wallStart)
    let finalUsage = usage()
    let mediaSeconds = (mediaEnd - firstPTS).seconds
    let sorted = frameTimes.dropFirst(10).sorted()
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    try emit([
        "schemaVersion": 1, "backend": options.backend, "scale": options.scale,
        "model": options.model?.lastPathComponent ?? "system", "computeRequested": options.compute,
        "modelCompileSeconds": scaler.ml?.compileSeconds ?? 0, "tileSize": scaler.ml?.tileSize ?? 0,
        "temporalFilterStrength": options.noiseStrength, "futureReferenceCount": scaler.lookAhead,
        "pastReferenceCount": scaler.cleaner?.previousCount ?? 0,
        "pixelRangeRequested": options.pixelRange,
        "sourcePixelFormat": try pixelFormat(scaler.sourceAttributes),
        "destinationPixelFormat": try pixelFormat(scaler.destinationAttributes),
        "firstFrameDiagnostics": diagnostics,
        "inputWidth": width, "inputHeight": height, "outputWidth": outWidth, "outputHeight": outHeight,
        "frames": frameTimes.count, "mediaSeconds": mediaSeconds,
        "setupSeconds": setupSeconds, "decodeProcessEncodeSeconds": wallSeconds,
        "speedIncludingSetup": mediaSeconds / (wallSeconds + setupSeconds),
        "pipelineSpeed": mediaSeconds / wallSeconds,
        "warmPipelineSpeed": (mediaEnd - warmMediaStart!).seconds / Date().timeIntervalSince(warmWallStart!),
        "firstFrameSeconds": firstFrameSeconds, "processP95MillisecondsAfter10Frames": p95 * 1000,
        "cpuSeconds": cpuSeconds(finalUsage) - cpuSeconds(startUsage),
        "processPeakRSSBytes": finalUsage.ru_maxrss,
        "outputBytes": (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0,
        "audioIncluded": false, "receiverValidated": false, "energyMeasured": false,
        "lanczosImplementation": "Core Image CILanczosScaleTransform (not the production FFmpeg filter)"
    ])
}

@main
struct SuperResolutionBench {
    @MainActor
    static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            guard #available(macOS 26, *) else { throw BenchError("Super resolution benchmark requires macOS 26+") }
            if options.probe {
                var result: [String: Any] = ["schemaVersion": 1,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "standardSupported": VTSuperResolutionScalerConfiguration.isSupported,
                    "standardScaleFactors": VTSuperResolutionScalerConfiguration.supportedScaleFactors,
                    "lowLatencySupported": VTLowLatencySuperResolutionScalerConfiguration.isSupported,
                    "lowLatencyScaleFactorsAt960x540": VTLowLatencySuperResolutionScalerConfiguration.__supportedScaleFactors(forFrameWidth: 960, frameHeight: 540),
                    "modelDownloadRequested": false]
                result["temporalNoiseSupported"] = VTTemporalNoiseFilterConfiguration.isSupported
                if let size = VTTemporalNoiseFilterConfiguration.minimumDimensions { result["temporalNoiseMinimumDimensions"] = [size.width, size.height] }
                if let size = VTTemporalNoiseFilterConfiguration.maximumDimensions { result["temporalNoiseMaximumDimensions"] = [size.width, size.height] }
                result["temporalNoiseSourceFormats"] = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats
                if VTTemporalNoiseFilterConfiguration.isSupported, let noise = VTTemporalNoiseFilterConfiguration(frameWidth: 960, frameHeight: 540,
                    sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                    result["temporalNoiseSourceAttributes"] = noise.sourcePixelBufferAttributes
                    result["temporalNoisePastReferences"] = noise.previousFrameCount ?? -1
                    result["temporalNoiseFutureReferences"] = noise.nextFrameCount ?? -1
                }
                if VTLowLatencySuperResolutionScalerConfiguration.isSupported {
                    let low = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: 960, frameHeight: 540, scaleFactor: 2)
                    result["lowLatencyPixelFormats"] = low.supportedPixelFormats
                    result["lowLatencySourceAttributes"] = low.sourcePixelBufferAttributes
                    result["lowLatencyDestinationAttributes"] = low.destinationPixelBufferAttributes
                }
                if VTSuperResolutionScalerConfiguration.isSupported,
                   let factor = VTSuperResolutionScalerConfiguration.supportedScaleFactors.first,
                   let configuration = VTSuperResolutionScalerConfiguration(frameWidth: 480, frameHeight: 270,
                    scaleFactor: factor, inputType: .video, usePrecomputedFlow: false,
                    qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision) {
                    result["standardModelStatus"] = configuration.configurationModelStatus.rawValue
                    result["standardModelReady"] = configuration.configurationModelStatus == .ready
                }
                try emit(result)
            } else { try await benchmark(options) }
        } catch {
            let message = (error as? BenchError)?.description ?? "Native processing failed (\((error as NSError).domain), code \((error as NSError).code)): \(error.localizedDescription)"
            try? emit(["schemaVersion": 1, "error": message])
            exit(1)
        }
    }
}
