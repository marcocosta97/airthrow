import AVFoundation
import Foundation

// Add an original 440 Hz tone to the synthetic fixture, for audio-track checks.
// Usage: swift scripts/add-test-audio.swift INPUT.mp4 OUTPUT.mp4
let source = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let wav = FileManager.default.temporaryDirectory.appendingPathComponent("airplayer-tone-\(UUID()).wav")
defer { try? FileManager.default.removeItem(at: wav) }
let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
buffer.frameLength = buffer.frameCapacity
for frame in 0..<Int(buffer.frameLength) {
    buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.2)
}
// Close the file before AVFoundation loads it.
do {
    let file = try AVAudioFile(forWriting: wav, settings: format.settings)
    try file.write(from: buffer)
}
let composition = AVMutableComposition()
let videoTrack = try await source.loadTracks(withMediaType: .video).first!
let audioAsset = AVURLAsset(url: wav)
let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first!
let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: videoTrack, at: .zero)
try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
    .insertTimeRange(range, of: audioTrack, at: .zero)
let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
exporter.outputURL = output
exporter.outputFileType = output.pathExtension.lowercased() == "mov" ? .mov : .mp4
await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    exporter.exportAsynchronously { continuation.resume() }
}
guard exporter.status == .completed else { fatalError("Could not export audio fixture") }
print(output.path)
