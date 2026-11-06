import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class MeetingManager: ObservableObject {
    @Published var records: [MeetingRecord] = []
    @Published var selection: UUID?
    @Published var detected: DetectedMeeting?
    @Published var activeID: UUID?
    @Published var phase = ""
    @Published var progress = ""
    @Published var error: String?
    @Published var detectMeetings = UserDefaults.standard.bool(forKey: "meetings.detect") {
        didSet { UserDefaults.standard.set(detectMeetings, forKey: "meetings.detect"); if !detectMeetings { detected = nil } }
    }
    @Published var automaticRecording = UserDefaults.standard.bool(forKey: "meetings.automatic") {
        didSet { UserDefaults.standard.set(automaticRecording, forKey: "meetings.automatic") }
    }
    @Published var aliases = UserDefaults.standard.string(forKey: "meetings.aliases") ?? "" {
        didSet { UserDefaults.standard.set(aliases, forKey: "meetings.aliases") }
    }
    @Published var keepAudio = UserDefaults.standard.bool(forKey: "meetings.keepAudio") {
        didSet { UserDefaults.standard.set(keepAudio, forKey: "meetings.keepAudio") }
    }
    let store = MeetingStore()
    private let appState: AppState
    private var capture: MeetingAudioCapture?
    private var operation: Task<Void, Never>?
    private var scanner: Task<Void, Never>?
    private var ignored: [String: Date] = [:]
    private var recordingCandidate: String?
    private var recordingPID: pid_t?
    private var earlyCaptureFailure: String?
    private var activity: NSObjectProtocol?
    private var startedUptime: TimeInterval = 0
    var isRecording: Bool { phase == "recording" }
    var isBusy: Bool { activeID != nil }

    init(appState: AppState) {
        self.appState = appState
        do { records = try store.load(); selection = records.first?.id }
        catch { self.error = "Saved meetings could not be read. Check file access and free disk space." }
        scanner = Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    self.checkpoint()
                    if self.detectMeetings { await self.poll() }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func ignoreDetected() {
        if let detected { ignored[detected.id] = Date() }
        detected = nil
    }

    private func poll() async {
        let preferredPID = recordingPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let found = await Task.detached(priority: .utility) { MeetingDetector.scan(preferredPID: preferredPID) }.value
        guard detectMeetings else { return }
        let now = Date()
        for candidate in found where ignored[candidate.id] != nil { ignored[candidate.id] = now }
        ignored = ignored.filter { now.timeIntervalSince($0.value) < 60 }
        if isRecording, let id = activeID, let index = records.firstIndex(where: { $0.id == id }) {
            if let candidate = found.first(where: { $0.id == recordingCandidate }), let name = candidate.speakerName {
                records[index].observations.append(.init(time: ProcessInfo.processInfo.systemUptime - startedUptime, name: name))
            }
            return
        }
        guard !isBusy else { return }
        let next = found.first { ignored[$0.id] == nil }
        let changed = next?.id != detected?.id
        detected = next
        if changed, let next {
            if automaticRecording { start(next) }
            else { NotificationCenter.default.post(name: .showMeetings, object: nil) }
        }
    }

    private func checkpoint() {
        guard isRecording, let id = activeID, let index = records.firstIndex(where: { $0.id == id }) else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedUptime
        if elapsed - records[index].duration >= 15 {
            records[index].duration = elapsed
            do { try store.save(records[index]) } catch { self.error = "Meeting metadata could not be saved. Finish recording and check disk space." }
        }
        if elapsed >= 12 * 60 * 60 { finish(captureIssue: "Recording stopped at the 12-hour limit.") }
    }

    func start(_ candidate: DetectedMeeting? = nil) {
        guard !isBusy else { return }
        guard !appState.isRecording && !appState.isTranscribing else { error = "Finish dictation before starting a meeting recording."; return }
        let configuration = LocalCohereConfiguration(pythonPath: appState.localCoherePythonPath, modelPath: appState.localCohereModelPath)
        do { try MeetingTranscriber.validate(configuration) } catch { self.error = error.localizedDescription; return }
        var record = MeetingRecord(title: candidate.map { "\($0.platform) meeting" } ?? "Meeting")
        record.myAliases = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        record.keepAudio = keepAudio
        do { try store.save(record) } catch { self.error = "Could not create a meeting recording. Check file access and disk space."; return }
        records.insert(record, at: 0)
        selection = record.id
        begin(record.id, phase: "starting")
        if let candidate { ignored[candidate.id] = Date() }
        detected = nil
        recordingCandidate = candidate?.id
        recordingPID = candidate?.pid
        earlyCaptureFailure = nil
        let audio = MeetingAudioCapture()
        capture = audio
        audio.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                if self.phase == "starting" { self.earlyCaptureFailure = message }
                else { self.finish(captureIssue: message) }
            }
        }
        operation = Task {
            do {
                startedUptime = ProcessInfo.processInfo.systemUptime
                try await audio.start(directory: store.directory(record.id), applicationPID: candidate?.pid)
                phase = "recording"
                progress = "Recording microphone and \(candidate?.platform ?? "system") audio"
                NotificationCenter.default.post(name: .showMeetings, object: nil)
                if let earlyCaptureFailure { finish(captureIssue: earlyCaptureFailure) }
            } catch {
                self.capture = nil
                fail(record.id, message: error.localizedDescription)
            }
        }
    }

    func finish(captureIssue: String? = nil) {
        guard isRecording, let id = activeID, let capture else { return }
        phase = "transcribing"
        progress = "Finishing audio recording"
        operation = Task {
            let issue = await capture.stop()
            self.capture = nil
            guard let index = records.firstIndex(where: { $0.id == id }) else { end(); return }
            records[index].duration = ProcessInfo.processInfo.systemUptime - startedUptime
            records[index].captureIssue = captureIssue ?? issue
            await process(id)
        }
    }

    func retry(_ id: UUID) {
        guard !isBusy else { return }
        begin(id, phase: "transcribing")
        operation = Task { await process(id) }
    }

    private func process(_ id: UUID) async {
        guard let index = records.firstIndex(where: { $0.id == id }) else { end(); return }
        do {
            if records[index].transcript.segments.isEmpty {
                records[index].status = "transcribing"
                try store.save(records[index])
                phase = "transcribing"
                let worker = MeetingTranscriber()
                let transcript = try await worker.transcribe(directory: store.directory(id), configuration: .init(pythonPath: appState.localCoherePythonPath, modelPath: appState.localCohereModelPath), language: appState.transcriptionLanguage, observations: records[index].observations) { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.activeID == id, self.phase == "transcribing" else { return }
                        self.progress = status
                    }
                }
                try Task.checkCancellation()
                records[index].transcript = transcript
                records[index].status = "transcribed"
                try store.save(records[index])
                guard !transcript.segments.isEmpty else { throw MeetingError.message("No speech was found. Check the microphone, system audio permissions and input volume.") }
                if !records[index].keepAudio { try store.removeAudio(id) }
            }
            phase = "summarizing"
            progress = "Summarizing with your configured model"
            records[index].status = "summarizing"
            try store.save(records[index])
            records[index].brief = try await summaryService.summarize(records[index])
            records[index].status = "complete"
            try store.save(records[index])
            end()
        } catch is CancellationError { fail(id, message: "Processing cancelled. Saved meeting data is available for retry.") }
        catch { fail(id, message: error is MeetingError || error is LocalCohereError ? error.localizedDescription : "Meeting processing or saving failed. Check file access and disk space, then retry.") }
    }

    func actions(for speaker: String, in id: UUID) {
        guard !isBusy, let index = records.firstIndex(where: { $0.id == id }) else { return }
        begin(id, phase: "summarizing")
        progress = "Finding this participant’s action items"
        operation = Task {
            do {
                records[index].requestedActions[speaker] = try await summaryService.summarize(records[index], target: speaker).actions
                try store.save(records[index])
                end()
            } catch { fail(id, message: error is MeetingError ? error.localizedDescription : "Action item generation was interrupted. Retry when ready.") }
        }
    }

    func renameSpeaker(_ speaker: String, in id: UUID, name: String) {
        guard !isBusy, let i = records.firstIndex(where: { $0.id == id }), let j = records[i].transcript.speakers.firstIndex(where: { $0.id == speaker }) else { return }
        records[i].transcript.speakers[j].name = String(name.prefix(80))
        records[i].transcript.speakers[j].source = "edited"
        persist(i)
    }

    func updateAliases(_ id: UUID, value: String) {
        guard !isBusy, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].myAliases = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        records[index].brief = nil
        records[index].requestedActions = [:]
        records[index].status = "transcribed"
        persist(index)
    }

    func delete(_ id: UUID) {
        guard !isBusy else { return }
        do { try store.delete(id); records.removeAll { $0.id == id }; selection = records.first?.id; error = nil }
        catch { self.error = "The meeting could not be deleted. Check file access." }
    }

    func cancelProcessing() { if phase != "starting" && !isRecording { operation?.cancel() } }

    private var summaryService: MeetingSummaryService { .init(apiKey: appState.apiKey, baseURL: appState.apiBaseURL, model: appState.postProcessingModel) }
    private func persist(_ index: Int) {
        do { try store.save(records[index]) } catch { self.error = "Your edit could not be saved. Check file access and disk space." }
    }
    private func begin(_ id: UUID, phase: String) {
        activeID = id; self.phase = phase; error = nil
        appState.meetingActive = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording or processing a meeting")
    }
    private func end() {
        activeID = nil; phase = ""; progress = ""; appState.meetingActive = false
        recordingPID = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
    }
    private func fail(_ id: UUID, message: String) {
        if let i = records.firstIndex(where: { $0.id == id }) {
            records[i].status = records[i].transcript.segments.isEmpty ? "interrupted" : "transcribed"
            persist(i)
        }
        error = message
        end()
    }
}
