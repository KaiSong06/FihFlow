import Foundation

enum MeetingTranscriberTests {
    static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["config.json", "model.safetensors", "tokenizer.model", "tokenizer_config.json", "special_tokens_map.json", "segmentation.onnx", "embedding.onnx"] {
                try Data().write(to: root.appendingPathComponent(name))
            }
            let helper = root.appendingPathComponent("worker.sh")
            try """
            IFS= read -r request
            case "$request" in
              *cancel*)
                : > started
                while :; do :; done
                ;;
              *invalid*)
                printf '{"segments":[{"id":"s1","start":0,"end":1,"speaker":"missing","text":"Synthetic"}],"speakers":[]}' > transcript.json
                ;;
              *)
                printf '{"segments":[{"id":"s1","start":0,"end":1,"speaker":"me","text":"Synthetic"}],"speakers":[{"id":"me","name":"Me","source":"microphone"}]}' > transcript.json
                ;;
            esac
            printf '{"progress":"Synthetic progress"}\\n{"done":true}\\n'
            """.write(to: helper, atomically: true, encoding: .utf8)
            let configuration = LocalCohereConfiguration(pythonPath: "/bin/sh", modelPath: root.path)
            let worker = MeetingTranscriber(models: root, workerURL: helper)
            let transcript = try await worker.transcribe(directory: root, configuration: configuration, language: "en", observations: [], progress: { _ in })
            TestSupport.expectEqual(transcript.segments.first?.text, "Synthetic")
            do {
                _ = try await MeetingTranscriber(models: root, workerURL: helper).transcribe(directory: root, configuration: configuration, language: "invalid", observations: [], progress: { _ in })
                fatalError("Unknown speaker IDs must be rejected")
            } catch is MeetingError { }
            let cancellable = MeetingTranscriber(models: root, workerURL: helper)
            let task = Task { try await cancellable.transcribe(directory: root, configuration: configuration, language: "cancel", observations: [], progress: { _ in }) }
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            TestSupport.expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), "Worker should start before cancellation")
            task.cancel()
            do { _ = try await task.value; fatalError("Cancellation must stop local meeting processing") }
            catch is CancellationError { }
            // Cancellation must not poison a subsequent attempt.
            let retry = try await MeetingTranscriber(models: root, workerURL: helper).transcribe(directory: root, configuration: configuration, language: "en", observations: [], progress: { _ in })
            TestSupport.expectEqual(retry.segments.count, 1)
        } catch { fatalError("Synthetic meeting worker test failed: \(error)") }
    }
}
