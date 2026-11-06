import Foundation

enum LocalCohereTranscriberTests {
    static func run() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for file in ["config.json", "model.safetensors", "tokenizer.model", "tokenizer_config.json", "special_tokens_map.json"] {
                try Data().write(to: root.appendingPathComponent(file))
            }
            let helper = root.appendingPathComponent("synthetic-worker.sh")
            // /bin/sh accepts -u just like Python. No model/runtime dependency in tests.
            try """
            count=0
            while IFS= read -r line; do
              case "$line" in
                *cancel*)
                  : > "$1/started"
                  IFS= read -r blocked
                  ;;
              esac
              count=$((count + 1))
              printf '{"text":"synthetic %s"}\\n' "$count"
            done
            """.write(to: helper, atomically: true, encoding: .utf8)
            let configuration = LocalCohereConfiguration(pythonPath: "/bin/sh", modelPath: root.path)
            let service = LocalCohereTranscriber()
            let audio = root.appendingPathComponent("synthetic.wav")
            let first = try await service.transcribe(fileURL: audio, configuration: configuration, language: "en", workerURL: helper)
            let second = try await service.transcribe(fileURL: audio, configuration: configuration, language: "en", workerURL: helper)
            TestSupport.expectEqual(first, "synthetic 1")
            TestSupport.expectEqual(second, "synthetic 2")

            let cancelled = Task {
                try await service.transcribe(fileURL: audio, configuration: configuration, language: "cancel", workerURL: helper)
            }
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            TestSupport.expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path), "Synthetic request starts before cancellation")
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                TestSupport.expect(false, "Cancelled local request must throw")
            } catch is CancellationError { }
            let afterCancel = try await service.transcribe(fileURL: audio, configuration: configuration, language: "en", workerURL: helper)
            TestSupport.expectEqual(afterCancel, "synthetic 1")

            // A missing local installation must fail locally even with a stale cloud URL.
            let missing = LocalCohereConfiguration(pythonPath: root.appendingPathComponent("missing").path, modelPath: root.path)
            let local = try TranscriptionService(apiKey: "synthetic", baseURL: "not a URL", localConfiguration: missing)
            do {
                _ = try await local.transcribe(fileURL: audio)
                TestSupport.expect(false, "Missing runtime must not use cloud transcription")
            } catch is LocalCohereError { }
            // Terminate the last synthetic worker without leaving a helper behind.
            let stop = Task { try await service.transcribe(fileURL: audio, configuration: configuration, language: "cancel", workerURL: helper) }
            try await Task.sleep(nanoseconds: 30_000_000)
            stop.cancel()
            _ = try? await stop.value
        } catch {
            TestSupport.expect(false, "Synthetic local worker test failed: \(error)")
        }
    }
}
