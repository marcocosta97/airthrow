import AVFoundation
import CoreVideo
import Foundation

// Synthetic two-second test fixture. Usage: OUTPUT.mp4|mov [h264|hevc]. Never bundled with the app.
guard (2...3).contains(CommandLine.arguments.count) else { fatalError("Usage: OUTPUT.mp4|mov [h264|hevc]") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard ["mp4", "mov"].contains(output.pathExtension.lowercased()),
      CommandLine.arguments.count <= 3 else { fatalError("Usage: OUTPUT.mp4|mov [h264|hevc]") }
let codec = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "h264"
guard ["h264", "hevc"].contains(codec) else { fatalError("Codec must be h264 or hevc") }
let writer = try AVAssetWriter(outputURL: output, fileType: output.pathExtension.lowercased() == "mov" ? .mov : .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: codec == "hevc" ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
    AVVideoWidthKey: 320,
    AVVideoHeightKey: 180
])
let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: 320,
    kCVPixelBufferHeightKey as String: 180,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
])
writer.add(input)
guard writer.startWriting() else { fatalError("Could not start fixture writer") }
writer.startSession(atSourceTime: .zero)
for frame in 0..<48 {
    let deadline = Date().addingTimeInterval(5)
    while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    guard input.isReadyForMoreMediaData else { fatalError("Fixture encoding timed out") }
    var pixel: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &pixel)
    let buffer = pixel!
    CVPixelBufferLockBaseAddress(buffer, [])
    let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<180 {
        for x in 0..<320 {
            let offset = y * stride + x * 4
            address[offset] = 255
            address[offset + 1] = UInt8(20 + frame * 3)
            address[offset + 2] = UInt8(x / 2)
            address[offset + 3] = UInt8(y)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else { fatalError("Fixture encoding failed") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
guard done.wait(timeout: .now() + 10) == .success, writer.status == .completed else { fatalError("Could not finish test fixture") }
print(output.path)
