import SwiftUI

struct LocalCohereSettingsFields: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio stays on this Mac. The model loads on the first dictation and stays in memory until the app quits. Local failures never fall back to cloud transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("Model folder").font(.caption.weight(.semibold))
                Spacer()
                Button("Choose…") { choosePath(directory: true) }
            }
            TextField("Cohere Transcribe MLX model folder", text: $appState.localCohereModelPath)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Python runtime").font(.caption.weight(.semibold))
                Spacer()
                Button("Choose…") { choosePath(directory: false) }
            }
            TextField("Local runtime Python executable", text: $appState.localCoherePythonPath)
                .textFieldStyle(.roundedBorder)
            Text("Install once with scripts/setup-local-cohere.sh. The default model folder reuses your Superwhisper Cohere download.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem = configurationProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("Runtime and model files found", systemImage: "checkmark.circle")
                    .font(.caption)
            }
        }
    }

    private var configurationProblem: String? {
        do {
            try LocalCohereConfiguration(pythonPath: appState.localCoherePythonPath, modelPath: appState.localCohereModelPath).validate()
            return nil
        } catch { return error.localizedDescription }
    }

    private func choosePath(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if directory { appState.localCohereModelPath = url.path }
        else { appState.localCoherePythonPath = url.path }
    }
}
