import CoreImage
import CoreML
import Foundation

// Isolated experiment: no model or Core ML dependency is added to the app target.
@MainActor
final class MLImageScaler {
    let model: MLModel
    let inputName: String
    let outputName: String
    let width: Int
    let height: Int
    let outputScale: Int
    let tileSize: Int?
    let inputPool: CVPixelBufferPool
    let outputPool: CVPixelBufferPool
    let tilePool: CVPixelBufferPool?
    let context = CIContext(options: [.cacheIntermediates: false])
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let video = CGColorSpace(name: CGColorSpace.itur_709)!
    var compileSeconds: Double = 0
    let halo = 16

    init(url: URL, compute: String, width: Int, height: Int, outputScale: Int = 2) throws {
        self.width = width; self.height = height; self.outputScale = outputScale
        let compiled: URL
        if url.pathExtension == "mlmodelc" { compiled = url }
        else {
            let cache = url.deletingPathExtension().appendingPathExtension("mlmodelc")
            if FileManager.default.fileExists(atPath: cache.path) { compiled = cache }
            else {
                let start = Date()
                let temporary = try MLModel.compileModel(at: url)
                try FileManager.default.moveItem(at: temporary, to: cache)
                compileSeconds = Date().timeIntervalSince(start)
                compiled = cache
            }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = compute == "ane" ? .cpuAndNeuralEngine : compute == "gpu" ? .cpuAndGPU : .all
        model = try MLModel(contentsOf: compiled, configuration: configuration)
        guard let input = model.modelDescription.inputDescriptionsByName.first,
              let constraint = input.value.imageConstraint,
              let output = model.modelDescription.outputDescriptionsByName.first,
              output.value.type == .image else { throw BenchError("Requires an RGB image-input/image-output model") }
        inputName = input.key; outputName = output.key
        let sizes = constraint.sizeConstraint
        let acceptsSize: Bool
        switch sizes.type {
        case .enumerated: acceptsSize = sizes.enumeratedImageSizes.contains { $0.pixelsWide == width && $0.pixelsHigh == height }
        case .range: acceptsSize = NSLocationInRange(width, sizes.pixelsWideRange) && NSLocationInRange(height, sizes.pixelsHighRange)
        default: acceptsSize = constraint.pixelsWide == width && constraint.pixelsHigh == height
        }
        if !acceptsSize {
            guard constraint.pixelsWide == constraint.pixelsHigh, constraint.pixelsWide > 2 * halo else {
                throw BenchError("Unsupported fixed model geometry")
            }
            tileSize = constraint.pixelsWide
        } else { tileSize = nil }
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        inputPool = try makePool(attributes: attributes, width: width, height: height)
        outputPool = try makePool(attributes: attributes, width: width * outputScale, height: height * outputScale)
        if let tileSize { tilePool = try makePool(attributes: attributes, width: tileSize, height: tileSize) }
        else { tilePool = nil }
    }

    func predict(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)])
        guard let output = try model.prediction(from: features).featureValue(for: outputName)?.imageBufferValue,
              CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA else {
            throw BenchError("Model produced an unsupported image buffer")
        }
        return output
    }

    func process(source: CVPixelBuffer, destination: CVPixelBuffer) async throws {
        let input = try await allocate(inputPool)
        autoreleasepool {
            context.render(CIImage(cvPixelBuffer: source, options: [.colorSpace: video]), to: input,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: rgb)
        }
        let result: CVPixelBuffer
        if let tileSize, let tilePool {
            result = try await allocate(outputPool)
            let tile = try await allocate(tilePool)
            CVPixelBufferLockBaseAddress(input, .readOnly)
            CVPixelBufferLockBaseAddress(result, [])
            defer { CVPixelBufferUnlockBaseAddress(input, .readOnly); CVPixelBufferUnlockBaseAddress(result, []) }
            let src = CVPixelBufferGetBaseAddress(input)!.assumingMemoryBound(to: UInt8.self)
            let dst = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
            let srcStride = CVPixelBufferGetBytesPerRow(input), dstStride = CVPixelBufferGetBytesPerRow(result)
            let step = tileSize - 2 * halo
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    try Task.checkCancellation()
                    CVPixelBufferLockBaseAddress(tile, [])
                    let base = CVPixelBufferGetBaseAddress(tile)!.assumingMemoryBound(to: UInt8.self)
                    let tileStride = CVPixelBufferGetBytesPerRow(tile)
                    // Replicate edges; retain a halo wider than the released CNN's receptive radius.
                    for row in 0..<tileSize {
                        let sourceY = max(0, min(height - 1, y + row - halo))
                        for column in 0..<tileSize {
                            let sourceX = max(0, min(width - 1, x + column - halo))
                            memcpy(base + row * tileStride + column * 4, src + sourceY * srcStride + sourceX * 4, 4)
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(tile, [])
                    try autoreleasepool {
                        let prediction = try predict(tile)
                        guard CVPixelBufferGetWidth(prediction) == tileSize * outputScale,
                              CVPixelBufferGetHeight(prediction) == tileSize * outputScale else { throw BenchError("Unexpected tile output dimensions") }
                        CVPixelBufferLockBaseAddress(prediction, .readOnly)
                        defer { CVPixelBufferUnlockBaseAddress(prediction, .readOnly) }
                        let predicted = CVPixelBufferGetBaseAddress(prediction)!.assumingMemoryBound(to: UInt8.self)
                        let predictedStride = CVPixelBufferGetBytesPerRow(prediction)
                        let rows = min(step, height - y) * outputScale, columns = min(step, width - x) * outputScale
                        for row in 0..<rows {
                            memcpy(dst + (y * outputScale + row) * dstStride + x * outputScale * 4,
                                predicted + (halo * outputScale + row) * predictedStride + halo * outputScale * 4, columns * 4)
                        }
                    }
                }
            }
        } else {
            result = try autoreleasepool { try predict(input) }
            guard CVPixelBufferGetWidth(result) == width * outputScale, CVPixelBufferGetHeight(result) == height * outputScale else {
                throw BenchError("Unexpected model output dimensions")
            }
        }
        autoreleasepool {
            context.render(CIImage(cvPixelBuffer: result, options: [.colorSpace: rgb]), to: destination,
                bounds: CGRect(x: 0, y: 0, width: width * outputScale, height: height * outputScale), colorSpace: video)
        }
    }
}
