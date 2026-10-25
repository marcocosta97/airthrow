import CoreVideo
import Foundation
import VideoToolbox

@available(macOS 26, *)
@MainActor
final class TemporalCleaner {
    let processor = VTFrameProcessor()
    let configuration: VTTemporalNoiseFilterConfiguration
    let pool: CVPixelBufferPool
    let strength: Float
    let nextCount: Int
    let previousCount: Int
    var previous: [VTFrameProcessorFrame] = []
    var first = true

    init(width: Int, height: Int, strength: Float) throws {
        guard VTTemporalNoiseFilterConfiguration.isSupported,
              let configuration = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height,
                sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
              let nextCount = configuration.nextFrameCount, let previousCount = configuration.previousFrameCount,
              nextCount > 0, nextCount <= 8, previousCount <= 8 else {
            throw BenchError("Temporal noise filter does not support these dimensions or bounded references")
        }
        self.configuration = configuration; self.strength = strength
        self.nextCount = nextCount; self.previousCount = previousCount
        pool = try makePool(attributes: configuration.destinationPixelBufferAttributes, width: width, height: height)
        try processor.startSession(configuration: configuration)
    }

    func end() { processor.endSession(); previous.removeAll() }

    func process(source: CVPixelBuffer, pts: CMTime, next: [VTFrameProcessorFrame]) async throws -> CVPixelBuffer {
        let destination = try await allocate(pool)
        CVBufferPropagateAttachments(source, destination)
        guard let frame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: pts),
              let output = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: pts),
              let parameters = VTTemporalNoiseFilterParameters(sourceFrame: frame, nextFrames: next,
                previousFrames: previous, destinationFrame: output, filterStrength: strength,
                hasDiscontinuity: first) else { throw BenchError("Invalid temporal filter references") }
        try await processor.process(parameters: parameters)
        CVBufferPropagateAttachments(source, destination)
        previous.append(frame)
        previous = Array(previous.suffix(previousCount))
        first = false
        return destination
    }
}
