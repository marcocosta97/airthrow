import AVFoundation
import CoreImage
import Foundation
import Metal
import VideoToolbox

/// Numeric diagnostics only. GPU execution time covers Core Image kernels, not
/// VideoToolbox's decoder, encoder or ML implementation.
public struct NativeVideoDiagnostics: Sendable, Codable {
    public var frames = 0
    public var hardwareDecodedFrames = 0
    public var metalPasses = 0
    public var metalSeconds = 0.0
    public var fetchSeconds = 0.0
    public var processingSeconds = 0.0
    public var compressedInputBytes: Int64 = 0
    public var prefetchedClipsDuringProcessing = 0
}
final class NativeVideoMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var value = NativeVideoDiagnostics()
    private var activeProcessing = 0
    func beginProcessing() { lock.withLock { activeProcessing += 1 } }
    func endProcessing() { lock.withLock { activeProcessing -= 1 } }
    var snapshot: NativeVideoDiagnostics { lock.withLock { value } }
    func fetched(seconds: Double, bytes: Int64) {
        lock.withLock { value.fetchSeconds += seconds; value.compressedInputBytes += bytes
            if activeProcessing > 0 { value.prefetchedClipsDuringProcessing += 1 } }
    }
    func processed(_ result: NativeVideoDiagnostics) {
        lock.withLock {
            value.frames += result.frames; value.hardwareDecodedFrames += result.hardwareDecodedFrames
            value.metalPasses += result.metalPasses; value.metalSeconds += result.metalSeconds
            value.processingSeconds += result.processingSeconds
        }
    }
}

/// Only two compressed clips can be retained: the clip in use and one ahead.
/// The task owns the workspace lease through its fetch closure. Cancellation
/// never deletes a directory while a helper is still using it.
final class NativeInputClip: @unchecked Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
final class NativeInputPrefetch: @unchecked Sendable {
    typealias Fetch = @Sendable (Int, Double, Double) async throws -> NativeInputClip
    private let lock = NSLock()
    private let duration: Double
    private let fetch: Fetch
    private var pending: (index: Int, id: UUID, task: Task<NativeInputClip, Error>)?
    private var draining: [UUID: Task<NativeInputClip, Error>] = [:]
    private var stopped = false
    init(duration: Double, fetch: @escaping Fetch) { self.duration = duration; self.fetch = fetch }
    private func job(_ index: Int) throws -> (UUID, Task<NativeInputClip, Error>) {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            if let pending, pending.index == index { return (pending.id, pending.task) }
            if let old = pending { old.task.cancel(); retire(old.task) }
            let fetch = fetch, duration = duration, id = UUID()
            let task = Task { try await fetch(index, Double(index) * 6, min(6, duration - Double(index) * 6)) }
            pending = (index, id, task)
            return (id, task)
        }
    }
    // Called under lock. Drop each canceled result as soon as its helper exits,
    // rather than retaining old compressed clips until playback ends.
    private func retire(_ task: Task<NativeInputClip, Error>) {
        let id = UUID(); draining[id] = task
        Task { [weak self] in
            _ = try? await task.value
            self?.lock.withLock { self?.draining[id] = nil }
        }
    }
    func take(index: Int) async throws -> NativeInputClip {
        let (id, task) = try job(index)
        let clip = try await withTaskCancellationHandler { try await task.value } onCancel: {
            self.lock.withLock {
                if self.pending?.id == id { task.cancel(); self.pending = nil; self.retire(task) }
            }
        }
        try Task.checkCancellation()
        lock.withLock { if pending?.id == id { pending = nil } }
        if Double(index + 1) * 6 < duration { _ = try job(index + 1) }
        return clip
    }
    func stop() {
        lock.withLock {
            stopped = true
            if let pending { pending.task.cancel(); retire(pending.task); self.pending = nil }
            draining.values.forEach { $0.cancel() }
        }
    }
    func wait() async {
        let jobs = lock.withLock { let jobs = Array(draining.values); draining.removeAll(); return jobs }
        for task in jobs { _ = try? await task.value }
    }
    deinit { pending?.task.cancel(); draining.values.forEach { $0.cancel() } }
}

/// A decoder session is required to use hardware. Compressed samples come from
/// AVAssetReader; pixel data is never mapped into CPU memory by this pipeline.
private final class HardwareVideoFrames: @unchecked Sendable {
    struct Frame { let buffer: CVPixelBuffer; let pts: CMTime; let duration: CMTime }
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var decoder: VTDecompressionSession?
    private let lock = NSLock()
    private var queue: [Frame] = []
    private var callbackFailed = false
    private var ended = false
    private let length: Double
    private let reorder: Int
    private let minimumPTS: Double
    init(asset: AVAsset, track: AVAssetTrack, length: Double, reorder: Int, minimumPTS: Double) throws {
        self.length = length; self.minimumPTS = minimumPTS; self.reorder = min(16, max(2, reorder + 2))
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 120000))
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PreparationFailure.unsupported }
        reader.add(output)
        guard reader.startReading() else { throw PreparationFailure.failed }
    }
    deinit { reader.cancelReading(); if let decoder { VTDecompressionSessionInvalidate(decoder) } }
    private func receive(status: OSStatus, buffer: CVImageBuffer?, pts: CMTime, duration: CMTime) {
        lock.withLock {
            guard status == noErr else { callbackFailed = true; return }
            guard let buffer, pts.isNumeric, pts.seconds >= minimumPTS - 0.00001, pts.seconds < length - 0.00001 else { return }
            guard CVPixelBufferGetIOSurface(buffer) != nil, queue.count < 64 else { callbackFailed = true; return }
            queue.append(Frame(buffer: buffer, pts: pts, duration: duration))
            queue.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
        }
    }
    func next() throws -> Frame? {
        while !ended && lock.withLock({ queue.count <= reorder }) {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer() else {
                guard reader.status == .completed else { throw PreparationFailure.failed }
                ended = true
                if let decoder {
                    let finish = VTDecompressionSessionFinishDelayedFrames(decoder)
                    let wait = VTDecompressionSessionWaitForAsynchronousFrames(decoder)
                    guard finish == noErr, wait == noErr else { throw PreparationFailure.failed }
                }
                break
            }
            // AVAssetReader emits empty edit-list boundary markers without a
            // format description. They are timing markers, not decoder packets.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            guard let format = CMSampleBufferGetFormatDescription(sample) else { throw PreparationFailure.failed }
            if decoder == nil {
                let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
                let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
                guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                    decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: nil,
                    decompressionSessionOut: &decoder) == noErr, let decoder else {
                    throw AppFailure(.unsupportedOperation, "Hardware decoding is unavailable for GPU cleanup. Choose FFmpeg cleanup.")
                }
                var hardware: Unmanaged<CFTypeRef>?
                guard VTSessionCopyProperty(decoder, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                    allocator: nil, valueOut: &hardware) == noErr,
                    (hardware?.takeRetainedValue() as? NSNumber)?.boolValue == true else { throw PreparationFailure.unsupported }
            }
            guard let decoder, VTDecompressionSessionCanAcceptFormatDescription(decoder, formatDescription: format) else { throw PreparationFailure.unsupported }
            let result = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                [weak self] status, _, buffer, pts, duration in self?.receive(status: status, buffer: buffer, pts: pts, duration: duration)
            }
            guard result == noErr, !lock.withLock({ callbackFailed }) else { throw PreparationFailure.failed }
        }
        return try lock.withLock {
            guard !callbackFailed else { throw PreparationFailure.failed }
            return queue.isEmpty ? nil : queue.removeFirst()
        }
    }
}

@MainActor
struct MetalVideoRenderer {
    let context: CIContext
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw AppFailure(.unsupportedOperation, "Metal processing is unavailable. Choose FFmpeg cleanup.")
        }
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }
    func render(_ image: CIImage, to buffer: CVPixelBuffer) throws -> CIRenderInfo {
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = CGColorSpace(name: CGColorSpace.itur_709)
        let task = try context.startTask(toRender: image, to: destination)
        return try task.waitUntilCompleted()
    }
}

@available(macOS 26, *)
@MainActor
enum NativeGPUVideoEncoder {
    static func export(input: URL, output: URL, layout: SuperResolutionLayout,
                       start: Double, length: Double, rate: Double, reorder: Int,
                       noiseReduction: CleanupNoiseReduction,
                       monitor: @Sendable () throws -> Void) async throws -> NativeVideoDiagnostics {
        let started = ContinuousClock.now
        let deadline = started + .seconds(600)
        let asset = AVURLAsset(url: input)
        guard try await !asset.load(.hasProtectedContent), let track = try await asset.loadTracks(withMediaType: .video).first else { throw PreparationFailure.unsupported }
        // An edit-list seek inside a frame can expose that frame again at t=0.
        // It already belongs to the preceding job; retain only the next frame.
        let minimumPTS = max(0, ceil(start * rate - 0.00001) / rate - start)
        let frames = try HardwareVideoFrames(asset: asset, track: track, length: length, reorder: reorder, minimumPTS: minimumPTS)
        let processor = try PreparedVideoProcessor(layout: layout, noiseReduction: noiseReduction)
        defer { processor.end() }
        let renderer = try MetalVideoRenderer()
        let inputPool = try SuperResolutionEncoder.pool(attributes: processor.sourceAttributes, width: layout.inputWidth, height: layout.inputHeight)
        let outputPool = try SuperResolutionEncoder.pool(attributes: processor.destinationAttributes, width: layout.outputWidth, height: layout.outputHeight)
        let inputFormat = try SuperResolutionEncoder.pixelFormat(processor.sourceAttributes)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let fourK = layout.outputWidth > 1920 || layout.outputHeight > 1080
        let settings: [String: Any] = [AVVideoCodecKey: fourK ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: layout.outputWidth, AVVideoHeightKey: layout.outputHeight,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: fourK ? 14_000_000 : 4_000_000,
                AVVideoExpectedSourceFrameRateKey: rate, AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: fourK ? kVTProfileLevel_HEVC_Main_AutoLevel as String : kVTProfileLevel_H264_High_AutoLevel as String],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.mediaTimeScale = 120000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(writerInput) else { throw PreparationFailure.failed }
        writer.add(writerInput)
        var complete = false
        defer { if !complete { writer.cancelWriting(); try? FileManager.default.removeItem(at: output) } }
        guard writer.startWriting() else { throw PreparationFailure.failed }
        writer.startSession(atSourceTime: .zero)
        let color = CGColorSpace(name: CGColorSpace.itur_709)!
        var pending: [(CVPixelBuffer, CMTime, CMTime)] = []
        var ended = false
        var stats = NativeVideoDiagnostics()
        var lastPTS: CMTime?
        var end = CMTime.zero
        var lastMonitor = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw PreparationFailure.stalled }
            if lastMonitor.duration(to: .now) >= .milliseconds(100) { try monitor(); lastMonitor = .now }
            while pending.count <= processor.lookAhead && !ended {
                guard let frame = try frames.next() else { ended = true; break }
                let input: CVPixelBuffer
                if CVPixelBufferGetWidth(frame.buffer) == layout.inputWidth,
                   CVPixelBufferGetHeight(frame.buffer) == layout.inputHeight,
                   CVPixelBufferGetPixelFormatType(frame.buffer) == inputFormat {
                    input = frame.buffer
                } else {
                    input = try await SuperResolutionEncoder.allocate(inputPool, threshold: processor.sourceThreshold)
                    let image = CIImage(cvPixelBuffer: frame.buffer, options: [.colorSpace: color])
                    let x = Double(layout.inputWidth) / Double(CVPixelBufferGetWidth(frame.buffer))
                    let y = Double(layout.inputHeight) / Double(CVPixelBufferGetHeight(frame.buffer))
                    let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: y, kCIInputAspectRatioKey: x / y])
                    let info = try renderer.render(scaled, to: input)
                    stats.metalPasses += info.passCount; stats.metalSeconds += info.kernelExecutionTime
                }
                CVBufferPropagateAttachments(frame.buffer, input)
                pending.append((input, frame.pts, frame.duration))
                stats.hardwareDecodedFrames += 1
            }
            guard let item = pending.first else { break }
            guard lastPTS == nil || CMTimeCompare(item.1, lastPTS!) > 0 else { throw PreparationFailure.failed }
            let destination = try await SuperResolutionEncoder.allocate(outputPool)
            CVBufferPropagateAttachments(item.0, destination)
            let future = try pending.dropFirst().map { value -> VTFrameProcessorFrame in
                guard let frame = VTFrameProcessorFrame(buffer: value.0, presentationTimeStamp: value.1) else { throw PreparationFailure.failed }; return frame
            }
            try await processor.process(source: item.0, destination: destination, pts: item.1, next: future)
            let until = ContinuousClock.now + .seconds(10)
            while !writerInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if lastMonitor.duration(to: .now) >= .milliseconds(100) { try monitor(); lastMonitor = .now }
                guard writer.status == .writing, ContinuousClock.now < until else { throw PreparationFailure.stalled }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(destination, withPresentationTime: item.1) else { throw PreparationFailure.failed }
            lastPTS = item.1
            end = item.1 + (item.2.isNumeric && item.2.seconds > 0 ? item.2 : CMTime(seconds: 1 / rate, preferredTimescale: 120000))
            stats.frames += 1; pending.removeFirst()
            await Task.yield()
        }
        guard stats.frames > 0, abs(end.seconds - length) < 0.15 else { throw PreparationFailure.failed }
        // Keep the six-second job boundary exact at fractional frame rates.
        // The following clip retains its sub-frame presentation offset.
        writer.endSession(atSourceTime: CMTime(seconds: length, preferredTimescale: 120000))
        writerInput.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw PreparationFailure.failed }
        try Task.checkCancellation(); try monitor(); complete = true
        stats.metalPasses += processor.metalPasses; stats.metalSeconds += processor.metalSeconds
        let elapsed = started.duration(to: .now).components
        stats.processingSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return stats
    }
}
