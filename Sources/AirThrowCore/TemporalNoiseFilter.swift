import CoreImage
import Foundation
import VideoToolbox

@MainActor
public enum TemporalNoiseFilterSupport {
    public static var unavailableReason: String? {
        guard #available(macOS 26, *) else { return "Apple temporal noise filter requires macOS 26 or later." }
        return VTTemporalNoiseFilterConfiguration.isSupported ? nil
            : "Apple temporal noise filter is not supported on this Mac. Use FFmpeg noise reduction."
    }
}

/// Owns only the references required by one independently prepared clip.
@available(macOS 26, *)
@MainActor
final class TemporalNoiseFilter {
    let processor = VTFrameProcessor()
    let configuration: VTTemporalNoiseFilterConfiguration
    let destinationPool: CVPixelBufferPool
    let nextCount: Int
    let previousCount: Int
    private var previous: [VTFrameProcessorFrame] = []

    init(width: Int, height: Int) throws {
        if let reason = TemporalNoiseFilterSupport.unavailableReason {
            throw AppFailure(.unsupportedOperation, reason)
        }
        guard let configuration = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height,
                  sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let next = configuration.nextFrameCount, let past = configuration.previousFrameCount,
              next > 0, past > 0, next <= 8, past <= 8 else {
            throw AppFailure(.unsupportedOperation, "Apple temporal noise filter does not support this source with bounded references. Choose FFmpeg noise reduction.")
        }
        self.configuration = configuration
        nextCount = next; previousCount = past
        destinationPool = try SuperResolutionEncoder.pool(attributes: configuration.destinationPixelBufferAttributes,
            width: width, height: height)
        try processor.startSession(configuration: configuration)
    }
    func end() { processor.endSession(); previous.removeAll() }

    func process(source: CVPixelBuffer, pts: CMTime, next: [VTFrameProcessorFrame]) async throws -> CVPixelBuffer {
        guard !next.isEmpty || !previous.isEmpty else {
            throw AppFailure(.unsupportedOperation, "Apple temporal noise filter needs at least two video frames. Choose FFmpeg noise reduction.")
        }
        let destination = try await SuperResolutionEncoder.allocate(destinationPool)
        CVBufferPropagateAttachments(source, destination)
        guard let frame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
              let result = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts),
              let parameters = VTTemporalNoiseFilterParameters(sourceFrame: frame, nextFrames: next,
                  previousFrames: previous, destinationFrame: result, filterStrength: 0.5,
                  hasDiscontinuity: previous.isEmpty) else { throw PreparationFailure.failed }
        try await processor.process(parameters: parameters)
        CVBufferPropagateAttachments(source, destination)
        previous.append(frame)
        previous = Array(previous.suffix(previousCount))
        return destination
    }
}

/// Temporal cleanup runs before scaling. Lanczos also permits unchanged dimensions.
@available(macOS 26, *)
@MainActor
final class PreparedVideoProcessor {
    let layout: SuperResolutionLayout
    let processor = VTFrameProcessor()
    let sourceAttributes: [String: Any]
    let destinationAttributes: [String: Any]
    let cleaner: TemporalNoiseFilter?
    private let scalerSourcePool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private let renderer: MetalVideoRenderer
    private let gpuCleanupPool: CVPixelBufferPool?
    private let gpuCleanup: Bool
    private(set) var metalPasses = 0
    private(set) var metalSeconds = 0.0
    private var previousSource: VTFrameProcessorFrame?
    private var previousOutput: VTFrameProcessorFrame?
    private var sessionStarted = false
    var lookAhead: Int { cleaner?.nextCount ?? 0 }
    var sourceThreshold: Int { max(8, lookAhead + (cleaner?.previousCount ?? 0) + 3) }

    init(layout: SuperResolutionLayout, noiseReduction: CleanupNoiseReduction) throws {
        self.layout = layout
        renderer = try MetalVideoRenderer()
        gpuCleanup = noiseReduction == .gpu
        let inputAttributes: [String: Any]
        let configuration: (any VTFrameProcessorConfiguration)?
        if layout.backend == .standard {
            guard let standard = VTSuperResolutionScalerConfiguration(frameWidth: layout.inputWidth,
                frameHeight: layout.inputHeight, scaleFactor: Int(layout.scale), inputType: .video,
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTSuperResolutionScalerConfiguration.defaultRevision) else { throw PreparationFailure.unsupported }
            guard standard.configurationModelStatus == .ready else {
                throw AppFailure(.unsupportedOperation, "Download the AI Standard model in Settings before using it.")
            }
            configuration = standard
            inputAttributes = standard.sourcePixelBufferAttributes
            destinationAttributes = standard.destinationPixelBufferAttributes
        } else if layout.backend == .lowLatency {
            let low = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: layout.inputWidth,
                frameHeight: layout.inputHeight, scaleFactor: layout.scale)
            configuration = low
            inputAttributes = low.sourcePixelBufferAttributes
            destinationAttributes = low.destinationPixelBufferAttributes
        } else {
            configuration = nil
            inputAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            destinationAttributes = inputAttributes
        }
        let noise = noiseReduction == .appleTemporal
            ? try TemporalNoiseFilter(width: layout.inputWidth, height: layout.inputHeight) : nil
        cleaner = noise
        gpuCleanupPool = noiseReduction == .gpu && layout.backend.isAI
            ? try SuperResolutionEncoder.pool(attributes: inputAttributes, width: layout.inputWidth, height: layout.inputHeight) : nil
        sourceAttributes = noise?.configuration.sourcePixelBufferAttributes ?? inputAttributes
        do {
            if noise != nil {
                scalerSourcePool = try SuperResolutionEncoder.pool(attributes: inputAttributes,
                    width: layout.inputWidth, height: layout.inputHeight)
                guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr else {
                    throw PreparationFailure.failed
                }
            } else { scalerSourcePool = nil }
            if let configuration { try processor.startSession(configuration: configuration); sessionStarted = true }
        } catch {
            noise?.end()
            if let transfer { VTPixelTransferSessionInvalidate(transfer) }
            throw error
        }
    }

    func end() {
        if sessionStarted { processor.endSession(); sessionStarted = false }
        cleaner?.end()
        if let transfer { VTPixelTransferSessionInvalidate(transfer); self.transfer = nil }
        previousSource = nil; previousOutput = nil
    }

    func process(source: CVPixelBuffer, destination: CVPixelBuffer, pts: CMTime,
                 next: [VTFrameProcessorFrame]) async throws {
        var input = source
        if let cleaner, let scalerSourcePool, let transfer {
            let cleaned = try await cleaner.process(source: source, pts: pts, next: next)
            input = try await SuperResolutionEncoder.allocate(scalerSourcePool)
            guard VTPixelTransferSessionTransferImage(transfer, from: cleaned, to: input) == noErr else { throw PreparationFailure.failed }
            CVBufferPropagateAttachments(cleaned, input)
            guard CVPixelBufferFillExtendedPixels(input) == kCVReturnSuccess else { throw PreparationFailure.failed }
        }
        let color = CGColorSpace(name: CGColorSpace.itur_709)!
        if let gpuCleanupPool {
            let cleaned = try await SuperResolutionEncoder.allocate(gpuCleanupPool)
            let image = CIImage(cvPixelBuffer: input, options: [.colorSpace: color])
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.4])
            let info = try renderer.render(image, to: cleaned)
            metalPasses += info.passCount; metalSeconds += info.kernelExecutionTime
            CVBufferPropagateAttachments(input, cleaned); input = cleaned
        }
        if layout.backend == .lanczos {
            var image = CIImage(cvPixelBuffer: input, options: [.colorSpace: color])
            if gpuCleanup {
                image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.02, "inputSharpness": 0.4])
            }
            if layout.inputWidth != layout.outputWidth || layout.inputHeight != layout.outputHeight {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: layout.scale,
                    kCIInputAspectRatioKey: Double(layout.outputWidth) / Double(layout.inputWidth) / Double(layout.scale)])
            }
            let info = try renderer.render(image, to: destination)
            metalPasses += info.passCount; metalSeconds += info.kernelExecutionTime
        } else {
            guard let frame = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: pts),
                  let result = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts) else { throw PreparationFailure.failed }
            if layout.backend == .standard {
                guard let parameters = VTSuperResolutionScalerParameters(sourceFrame: frame,
                    previousFrame: previousSource, previousOutputFrame: previousOutput, opticalFlow: nil,
                    submissionMode: previousSource == nil ? .random : .sequential, destinationFrame: result) else { throw PreparationFailure.failed }
                try await processor.process(parameters: parameters)
                previousSource = frame; previousOutput = result
            } else {
                try await processor.process(parameters: VTLowLatencySuperResolutionScalerParameters(sourceFrame: frame, destinationFrame: result))
            }
        }
        CVBufferPropagateAttachments(input, destination)
    }
}
