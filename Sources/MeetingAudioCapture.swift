import Foundation
import AVFoundation
import ScreenCaptureKit

final class MeetingAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FihFlow.MeetingAudio")
    private var stream: SCStream?
    private var system: MeetingPCMWriter?
    private var microphone: MeetingPCMWriter?
    private var origin: Double = 0
    private var accepting = false
    private var reportedFailure = false
    var onFailure: (@Sendable (String) -> Void)?

    func start(directory: URL, applicationPID: pid_t?) async throws {
        guard #available(macOS 15, *) else { throw MeetingError.message("Meeting capture requires macOS 15 or later.") }
        // Permission requests are only made by the explicit UI buttons.
        guard CGPreflightScreenCaptureAccess(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MeetingError.message("Allow System Audio Recording and Microphone access before recording a meeting.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw MeetingError.message("No display is available for system audio capture.") }
        let filter: SCContentFilter
        if let applicationPID {
            guard let application = content.applications.first(where: { $0.processID == applicationPID }) else {
                throw MeetingError.message("The detected meeting app is no longer available. Detect it again or choose manual system recording.")
            }
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        config.showsCursor = false
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try queue.sync {
            system = try MeetingPCMWriter(url: directory.appendingPathComponent("system.wav"))
            microphone = try MeetingPCMWriter(url: directory.appendingPathComponent("microphone.wav"))
            origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            accepting = true
        }
        stream = capture
        do { try await capture.startCapture() }
        catch {
            queue.sync { accepting = false; system = nil; microphone = nil }
            stream = nil
            throw MeetingError.message("System audio capture could not start. Check recording permissions and the selected app.")
        }
    }

    func stop() async -> String? {
        var stopFailed = false
        if let stream { do { try await stream.stopCapture() } catch { stopFailed = true } }
        stream = nil
        return queue.sync {
            accepting = false
            let missing = system?.receivedAudio != true || microphone?.receivedAudio != true
            system = nil
            microphone = nil
            if stopFailed { return "The audio stream ended unexpectedly. Review the recording for gaps." }
            if missing { return "One audio source delivered no samples. This recording may be incomplete." }
            return nil
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.fail("System audio capture stopped unexpectedly. The recorded portion has been saved.") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid else { return }
        do {
            let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds - origin
            guard seconds.isFinite && seconds >= -1 && seconds < 12 * 60 * 60 else {
                throw MeetingError.message("Meeting capture reached its 12-hour limit or encountered an invalid audio clock.")
            }
            if type == .audio { try system?.append(sampleBuffer, at: max(0, seconds)) }
            if #available(macOS 15, *), type == .microphone { try microphone?.append(sampleBuffer, at: max(0, seconds)) }
        } catch { fail("Audio could not be saved. Check free disk space; the recorded portion has been kept.") }
    }

    private func fail(_ message: String) {
        guard accepting && !reportedFailure else { return }
        accepting = false
        reportedFailure = true
        onFailure?(message)
    }
}

final class MeetingPCMWriter {
    private let file: AVAudioFile
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var frames: Int64 = 0
    private(set) var receivedAudio = false

    init(url: URL) throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func append(_ sample: CMSampleBuffer, at seconds: Double) throws {
        guard let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else {
            throw MeetingError.message("Cannot decode audio sample.")
        }
        if sourceFormat != format {
            converter = AVAudioConverter(from: format, to: target)
            sourceFormat = format
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) * 16_000 / format.sampleRate) + 64) else {
            throw MeetingError.message("Cannot convert audio.")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error && error == nil else { throw MeetingError.message("Audio conversion failed.") }
        guard converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
        receivedAudio = true
        let alignment = MeetingTimeline.alignment(writtenFrames: frames, presentationSeconds: seconds, frameCount: Int(converted.frameLength))
        var remaining = alignment.silence
        while remaining > 0 {
            let length = AVAudioFrameCount(min(remaining, 4096))
            let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: length)!
            silence.frameLength = length
            memset(silence.floatChannelData![0], 0, Int(length) * MemoryLayout<Float>.size)
            try file.write(from: silence)
            remaining -= Int64(length)
            frames += Int64(length)
        }
        let length = Int(converted.frameLength) - alignment.skip
        guard length > 0 else { return }
        if alignment.skip > 0 { memmove(samples, samples.advanced(by: alignment.skip), length * MemoryLayout<Float>.size) }
        converted.frameLength = AVAudioFrameCount(length)
        try file.write(from: converted)
        frames += Int64(length)
    }
}
