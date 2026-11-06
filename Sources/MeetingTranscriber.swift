import Foundation

final class MeetingTranscriber: @unchecked Sendable {
    static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FihFlow/meeting-models")
    }
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let models: URL
    private let workerURL: URL?

    init(models: URL = MeetingTranscriber.modelDirectory, workerURL: URL? = nil) {
        self.models = models
        self.workerURL = workerURL
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    static func validate(_ configuration: LocalCohereConfiguration, models: URL = modelDirectory) throws {
        try configuration.validate()
        for name in ["segmentation.onnx", "embedding.onnx"] {
            guard FileManager.default.fileExists(atPath: models.appendingPathComponent(name).path) else {
                throw MeetingError.message("Install meeting speaker models with scripts/setup-meeting-models.sh before recording.")
            }
        }
    }

    func transcribe(directory: URL, configuration: LocalCohereConfiguration, language: String,
                    observations: [MeetingSpeakerObservation], progress: @escaping @Sendable (String) -> Void) async throws -> MeetingTranscript {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.run(directory: directory, configuration: configuration, language: language, observations: observations, progress: progress)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }

    private func run(directory: URL, configuration: LocalCohereConfiguration, language: String,
                     observations: [MeetingSpeakerObservation], progress: (String) -> Void) throws -> MeetingTranscript {
        try Self.validate(configuration, models: models)
        guard let worker = workerURL ?? Bundle.main.url(forResource: "meeting_worker", withExtension: "py") else {
            throw MeetingError.message("The meeting helper is missing. Rebuild FihFlow.")
        }
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        if FileManager.default.fileExists(atPath: transcriptURL.path) {
            try FileManager.default.removeItem(at: transcriptURL)
        }
        let child = Process()
        let input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: configuration.pythonPath)
        child.currentDirectoryURL = directory
        child.arguments = ["-u", worker.path]
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run() } catch { lock.unlock(); throw MeetingError.message("The local meeting helper could not start.") }
        process = child
        lock.unlock()
        defer {
            if child.isRunning { child.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            lock.lock(); process = nil; lock.unlock()
        }
        let observationData = try JSONEncoder().encode(observations)
        let request: [String: Any] = ["directory": directory.path, "model": configuration.modelPath,
            "speakerModels": models.path, "language": language.isEmpty ? "en" : language,
            "observations": try JSONSerialization.jsonObject(with: observationData)]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        var line = Data(), done = false
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 {
                if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    if let status = message["progress"] as? String { progress(String(status.prefix(120))) }
                    if message["done"] as? Bool == true { done = true }
                }
                line.removeAll(keepingCapacity: true)
            } else { line.append(byte) }
            guard line.count < 4096 else { throw MeetingError.message("The meeting helper returned invalid progress.") }
        }
        child.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard done && child.terminationStatus == 0 else {
            throw MeetingError.message("Local meeting transcription failed. Check the runtime, language, models and available memory. Audio is saved for retry.")
        }
        let transcript = try JSONDecoder().decode(MeetingTranscript.self, from: Data(contentsOf: transcriptURL))
        let ids = Set(transcript.speakers.map(\.id))
        guard Set(transcript.segments.map(\.id)).count == transcript.segments.count,
              transcript.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && ids.contains($0.speaker) }) else {
            throw MeetingError.message("The local transcript was invalid. Audio is saved for retry.")
        }
        return transcript
    }
}
