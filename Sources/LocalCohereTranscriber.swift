import Foundation

struct LocalCohereConfiguration: Equatable, Sendable {
    var pythonPath: String
    var modelPath: String

    static var defaultPythonPath: String {
        NSHomeDirectory() + "/Library/Application Support/FihFlow/runtime/bin/python3"
    }

    static var defaultModelPath: String {
        NSHomeDirectory() + "/Library/Application Support/superwhisper/models/cohere-transcribe/cohere-transcribe-q4"
    }

    func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw LocalCohereError.setup("Install the local runtime with scripts/setup-local-cohere.sh, then select its Python executable in Provider Settings.")
        }
        for file in ["config.json", "model.safetensors", "tokenizer.model", "tokenizer_config.json", "special_tokens_map.json"] {
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: modelPath).appendingPathComponent(file).path) else {
                throw LocalCohereError.setup("Select a complete Cohere Transcribe MLX model folder in Provider Settings.")
            }
        }
    }
}

enum LocalCohereError: LocalizedError {
    case setup(String)
    case workerFailed
    case unsupportedLanguage
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .setup(let message): return message
        case .workerFailed: return "Local Cohere could not transcribe. Check the runtime and model folder in Provider Settings, then retry. Audio was not sent to a cloud transcription service."
        case .unsupportedLanguage: return "This Cohere model does not support the selected language. Choose a supported transcription language in Provider Settings."
        case .timedOut(let seconds): return "Local Cohere transcription exceeded \(Int(seconds)) seconds. Retry after freeing memory or use a longer transcription timeout."
        }
    }
}

/// One serial worker keeps model weights resident. Cancelling a request kills
/// its worker, so its eventual response cannot be mistaken for the next one.
final class LocalCohereTranscriber: @unchecked Sendable {
    static let shared = LocalCohereTranscriber()
    private let queue = DispatchQueue(label: "FihFlow.LocalCohere")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var configuration: LocalCohereConfiguration?

    func transcribe(fileURL: URL, configuration: LocalCohereConfiguration, language: String?, workerURL: URL? = nil) async throws -> String {
        let job = LocalCohereJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    defer { job.detach() }
                    do {
                        try job.checkCancellation()
                        try configuration.validate()
                        let worker = workerURL ?? Bundle.main.url(forResource: "local_cohere_worker", withExtension: "py")
                        guard let worker else {
                            throw LocalCohereError.setup("The local transcription helper is missing. Rebuild FihFlow.")
                        }
                        if self.configuration != configuration || self.process?.isRunning != true {
                            self.stop()
                            let process = Process()
                            let stdin = Pipe()
                            let stdout = Pipe()
                            process.executableURL = URL(fileURLWithPath: configuration.pythonPath)
                            process.arguments = ["-u", worker.path, configuration.modelPath]
                            // Do not inherit provider credentials or Python import overrides.
                            process.environment = [
                                "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                                "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                                "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false"
                            ]
                            process.standardInput = stdin
                            process.standardOutput = stdout
                            process.standardError = FileHandle.nullDevice
                            try job.start(process)
                            self.process = process
                            self.input = stdin.fileHandleForWriting
                            self.output = stdout.fileHandleForReading
                            self.configuration = configuration
                        } else if let process = self.process {
                            try job.attach(process)
                        }
                        let request: [String: String] = ["audio": fileURL.path, "language": language ?? "en"]
                        var data = try JSONSerialization.data(withJSONObject: request)
                        data.append(0x0a)
                        try self.input?.write(contentsOf: data)
                        var line = Data()
                        while let byte = try self.output?.read(upToCount: 1), !byte.isEmpty {
                            if byte.first == 0x0a { break }
                            line.append(byte)
                            guard line.count < 4 * 1024 * 1024 else { throw LocalCohereError.workerFailed }
                        }
                        try job.checkCancellation()
                        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: String] else {
                            throw LocalCohereError.workerFailed
                        }
                        if response["error"] == "unsupported_language" { throw LocalCohereError.unsupportedLanguage }
                        guard let text = response["text"] else { throw LocalCohereError.workerFailed }
                        continuation.resume(returning: text)
                    } catch {
                        self.stop()
                        if job.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else if let error = error as? LocalCohereError { continuation.resume(throwing: error) }
                        else { continuation.resume(throwing: LocalCohereError.workerFailed) }
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    private func stop() {
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        configuration = nil
    }
}

private final class LocalCohereJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        self.process = process
    }

    func attach(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.process = process
    }

    func detach() {
        lock.lock()
        defer { lock.unlock() }
        process = nil
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
