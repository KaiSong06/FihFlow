import AVFoundation
import Foundation

enum MeetingAudioTests {
    static func run() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("synthetic.wav")
            var writer: MeetingPCMWriter? = try MeetingPCMWriter(url: url)
            // A synthetic 48 kHz stereo device stream must become mono 16 kHz.
            let sample = makeSample(frames: 4_800)
            try writer?.append(sample, at: 0)
            try writer?.append(sample, at: 1)
            // A duplicate callback cannot duplicate audio or shift its timeline.
            try writer?.append(sample, at: 1)
            TestSupport.expect(writer?.receivedAudio == true, "Audio samples should be received")
            writer = nil
            let audio = try AVAudioFile(forReading: url)
            TestSupport.expectEqual(audio.processingFormat.channelCount, 1)
            TestSupport.expectEqual(audio.processingFormat.sampleRate, 16_000)
            TestSupport.expect(abs(audio.length - 17_600) < 100, "Resampling and silence must preserve the presentation timeline")
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
            try audio.read(into: buffer)
            let samples = buffer.floatChannelData![0]
            TestSupport.expectApproximatelyEqual(Double(samples[8_000]), 0, accuracy: 0.0001)
            TestSupport.expect(abs(samples[16_200]) > 0.1, "Converted samples must retain audible signal")
        } catch { fatalError("Synthetic PCM capture test failed: \(error)") }
    }

    private static func makeSample(frames: Int) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        var description: CMAudioFormatDescription?
        TestSupport.expectEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        let values = [Float](repeating: 0.25, count: frames * 2)
        var block: CMBlockBuffer?
        let bytes = values.count * MemoryLayout<Float>.size
        TestSupport.expectEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block), noErr)
        values.withUnsafeBytes { raw in
            TestSupport.expectEqual(CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes), noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = MemoryLayout<Float>.size * 2
        var sample: CMSampleBuffer?
        TestSupport.expectEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return sample!
    }
}
