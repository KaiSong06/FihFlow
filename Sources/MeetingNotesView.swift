import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct MeetingNotesView: View {
    @EnvironmentObject var meetings: MeetingManager
    @State private var showOptions = false
    @State private var deleteID: UUID?
    @State private var refreshPermissions = false

    var body: some View {
        NavigationSplitView {
            List(selection: $meetings.selection) {
                ForEach(meetings.records) { meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(.headline)
                        Text(meeting.startedAt, style: .date).foregroundStyle(.secondary)
                        Text(meeting.status.capitalized + " · " + MeetingRecord.timestamp(meeting.duration))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4).tag(meeting.id)
                }
            }.navigationTitle("Meetings").frame(minWidth: 210)
        } detail: {
            VStack(spacing: 0) {
                if let error = meetings.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error).textSelection(.enabled)
                        Spacer()
                        Button { meetings.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding().background(Color.orange.opacity(0.1))
                }
                if meetings.isBusy { recordingStatus }
                if let detected = meetings.detected, !meetings.isBusy {
                    HStack {
                        Text("\(detected.platform) meeting detected")
                        Spacer()
                        Button("Not now") { meetings.ignoreDetected() }
                        Button("Record meeting") { meetings.start(detected) }.buttonStyle(.borderedProminent)
                    }.padding()
                    Text("Captures microphone and this app’s audio. In a browser, audio from other tabs may also be included.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
                    Divider()
                }
                if showOptions { options; Divider() }
                if let record = meetings.records.first(where: { $0.id == meetings.selection }) {
                    MeetingDetailView(record: record, delete: { deleteID = record.id })
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "person.3.sequence").font(.largeTitle)
                        Text("Meeting notes").font(.largeTitle.weight(.semibold))
                        Text("Record both sides of a conversation. Get a speaker-labeled transcript, a summary, and action items for you.")
                        Text("Transcription and speaker grouping run locally. Summaries send transcript text and speaker names to the model configured in Provider Settings.")
                        Text("Use headphones to prevent meeting audio from appearing again on your microphone. Voice groups and suggested names should be reviewed.")
                            .foregroundStyle(.secondary)
                        Button("Set up meeting recording") { showOptions = true }
                    }.frame(maxWidth: 540, alignment: .leading).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 580)
        }
        .toolbar {
            ToolbarItem {
                Button("Record system + mic", systemImage: "record.circle") { meetings.start() }
                    .disabled(meetings.isBusy).help("Records all system audio and your default microphone until you finish.")
            }
            ToolbarItem { Button { showOptions.toggle() } label: { Label("Meeting settings", systemImage: "slider.horizontal.3") } }
        }
        .alert("Delete this meeting and its saved audio?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("Cancel", role: .cancel) { deleteID = nil }
            Button("Delete", role: .destructive) { if let deleteID { meetings.delete(deleteID) }; deleteID = nil }
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 12) {
            if meetings.isRecording { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
            else { ProgressView().controlSize(.small) }
            VStack(alignment: .leading) {
                Text(meetings.progress.isEmpty ? "Starting recording…" : meetings.progress).fontWeight(.medium)
                if meetings.isRecording, let record = meetings.records.first(where: { $0.id == meetings.activeID }) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(MeetingRecord.timestamp(context.date.timeIntervalSince(record.startedAt))).monospacedDigit()
                    }
                    Text("Recording continues until you choose Finish.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if meetings.isRecording {
                Button("Finish & create notes") { meetings.finish() }.buttonStyle(.borderedProminent)
            } else if meetings.phase != "starting" {
                Button("Cancel processing") { meetings.cancelProcessing() }
            }
        }.padding().background(Color.accentColor.opacity(0.08))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting recording").font(.headline)
            Text("macOS 15+ · Default microphone · Local Cohere transcription").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(AXIsProcessTrusted() ? "Accessibility allowed" : "Allow Accessibility") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    refreshPermissions.toggle()
                }
                Button(CGPreflightScreenCaptureAccess() ? "System audio allowed" : "Allow system audio") {
                    _ = CGRequestScreenCaptureAccess(); refreshPermissions.toggle()
                }
                Button(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Microphone allowed" : "Allow microphone") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refreshPermissions.toggle() } }
                }
            }.id(refreshPermissions)
            Toggle("Detect meetings and suggest recording", isOn: $meetings.detectMeetings)
            Toggle("Automatically record detected meetings", isOn: $meetings.automaticRecording)
                .disabled(!meetings.detectMeetings)
            Text("Detection reads meeting controls and explicit speaking labels through Accessibility. It works only when an app exposes them; you can always start manually. Automatic recording captures the detected app plus microphone and continues until Finish.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("My names in meetings (comma separated)", text: $meetings.aliases)
            Toggle("Keep audio after transcription", isOn: $meetings.keepAudio)
            Text("Transcripts and notes stay saved until deleted. By default audio is deleted after transcription. Finishing a recording sends transcript text to your configured provider for a summary and only your action items.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Provider Settings…") { NotificationCenter.default.post(name: .showSettings, object: nil) }
        }.padding().disabled(meetings.isBusy)
    }
}

private struct MeetingDetailView: View {
    @EnvironmentObject var meetings: MeetingManager
    let record: MeetingRecord
    let delete: () -> Void
    @State private var tab = "Notes"
    @State private var otherSpeaker = ""
    @State private var aliases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title).font(.title.weight(.semibold))
                Spacer()
                Button("Export…") { export() }.disabled(record.transcript.segments.isEmpty)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }.disabled(meetings.isBusy)
            }
            if let issue = record.captureIssue { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Picker("View", selection: $tab) {
                Text("Notes").tag("Notes")
                Text("Transcript").tag("Transcript")
                Text("Speakers").tag("Speakers")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == "Transcript" { transcript }
                    else if tab == "Speakers" { speakers }
                    else { notes }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }.padding(24).onAppear { aliases = record.myAliases.joined(separator: ", ") }
        .onChange(of: record.id) { _ in aliases = record.myAliases.joined(separator: ", "); otherSpeaker = "" }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let brief = record.brief {
                Text(brief.summary).textSelection(.enabled)
                if !brief.decisions.isEmpty {
                    Text("Decisions").font(.headline)
                    ForEach(Array(brief.decisions.enumerated()), id: \.offset) { _, decision in Text("• " + decision).textSelection(.enabled) }
                }
                Text("My action items").font(.headline)
                actionList(brief.actions)
            } else {
                Text(record.transcript.segments.isEmpty ? "Your transcript and notes will appear after recording finishes." : "Your transcript is saved. Generate notes using your configured model.")
            }
            Button(record.brief == nil ? "Generate / retry notes" : "Regenerate my notes") { meetings.retry(record.id) }.disabled(meetings.isBusy)
            if !record.transcript.segments.isEmpty {
                Divider()
                Text("Action items for someone else").font(.headline)
                HStack {
                    Picker("Participant", selection: $otherSpeaker) {
                        Text("Choose participant").tag("")
                        ForEach(record.transcript.speakers.filter { $0.id != "me" }) { speaker in Text(speaker.name).tag(speaker.id) }
                    }
                    Button("Generate action items") { meetings.actions(for: otherSpeaker, in: record.id) }
                        .disabled(otherSpeaker.isEmpty || meetings.isBusy)
                }
                if let items = record.requestedActions[otherSpeaker] { actionList(items) }
            }
        }
    }

    private func actionList(_ actions: [MeetingActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if actions.isEmpty { Text("No explicit commitments found.").foregroundStyle(.secondary) }
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                VStack(alignment: .leading, spacing: 5) {
                    Text("☐ " + action.task).textSelection(.enabled)
                    if !action.due.isEmpty { Text("Due: " + action.due).font(.caption) }
                    DisclosureGroup("Supporting transcript") {
                        ForEach(record.transcript.segments.filter { action.evidence.contains($0.id) }) { segment in
                            Text(line(segment)).font(.caption).textSelection(.enabled)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(record.transcript.segments) { segment in
                Text(line(segment)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
    }

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Microphone speech is labeled Me. Remote voice groups and names inferred from speaking indicators can be wrong, especially with overlapping speech. Edit names before generating action items.")
                .foregroundStyle(.secondary)
            ForEach(record.transcript.speakers) { speaker in
                HStack {
                    Text(speaker.id == "me" ? "Me" : "Remote voice").frame(width: 100, alignment: .leading)
                    TextField("Name", text: Binding(get: { speaker.name }, set: { meetings.renameSpeaker(speaker.id, in: record.id, name: $0) }))
                    Text(speaker.source).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            TextField("Names people use for me", text: $aliases)
            Button("Save my names & clear generated notes") { meetings.updateAliases(record.id, value: aliases) }
        }.disabled(meetings.isBusy)
    }

    private func line(_ segment: MeetingSegment) -> String {
        "[\(MeetingRecord.timestamp(segment.start))] \(record.transcript.speakers.first { $0.id == segment.speaker }?.name ?? segment.speaker): \(segment.text)"
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Meeting notes.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = record.title + "\n\n"
        if let brief = record.brief {
            text += brief.summary + "\n\nDecisions\n" + brief.decisions.joined(separator: "\n")
            text += "\n\nMy action items\n" + brief.actions.map { "☐ \($0.task)\($0.due.isEmpty ? "" : " (\($0.due))")" }.joined(separator: "\n")
        }
        for speaker in record.transcript.speakers {
            if let actions = record.requestedActions[speaker.id] { text += "\n\n\(speaker.name) — requested action items\n" + actions.map(\.task).joined(separator: "\n") }
        }
        text += "\n\nTranscript\n\n" + record.transcriptText
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { meetings.error = "The export could not be saved. Choose a writable folder." }
    }
}
