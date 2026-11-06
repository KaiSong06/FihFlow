import Foundation

struct MeetingSegment: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

struct MeetingSpeaker: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var source: String
}

struct MeetingSpeakerObservation: Codable, Equatable, Sendable {
    var time: Double
    var name: String
}

struct MeetingTranscript: Codable, Sendable {
    var segments: [MeetingSegment]
    var speakers: [MeetingSpeaker]
}

struct MeetingActionItem: Codable, Equatable, Sendable {
    var assignee: String
    var task: String
    var due: String
    var evidence: [String]
}

struct MeetingBrief: Codable, Equatable, Sendable {
    var summary: String
    var decisions: [String]
    var actions: [MeetingActionItem]
}

struct MeetingRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    var startedAt = Date()
    var duration: Double = 0
    var status = "recording"
    var myAliases: [String] = []
    var observations: [MeetingSpeakerObservation] = []
    var transcript = MeetingTranscript(segments: [], speakers: [])
    var brief: MeetingBrief?
    var requestedActions: [String: [MeetingActionItem]] = [:]
    var keepAudio = false
    var captureIssue: String?

    var transcriptText: String {
        transcript.segments.map { segment in
            let name = transcript.speakers.first { $0.id == segment.speaker }?.name ?? segment.speaker
            return "[\(Self.timestamp(segment.start))] \(name): \(segment.text)"
        }.joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

struct MeetingDetectionEvidence: Sendable {
    var bundleID: String
    var urls: [String]
    var controls: [String]
    var labels: [String]
}

enum MeetingDetectionRules {
    static let browsers = ["com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "org.mozilla.firefox"]
    static let nativeApps = ["us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams", "com.cisco.webexmeetingsapp": "Webex", "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack"]

    static func platform(_ evidence: MeetingDetectionEvidence) -> String? {
        let controls = evidence.controls.map { $0.lowercased() }
        let endControls = ["leave call", "leave meeting", "end call", "end meeting", "hang up", "hangup", "disconnect", "leave huddle"]
        let explicitEnd = controls.contains(where: { label in endControls.contains(where: { label == $0 || label.hasPrefix($0 + ",") || label.hasPrefix($0 + " (") }) })
        let nativeLeave = nativeApps[evidence.bundleID] != nil
            && controls.contains(where: { $0 == "leave" || $0.hasPrefix("leave (") })
            && controls.contains(where: { $0.contains("mute") || $0.contains("microphone") })
        guard explicitEnd || nativeLeave else { return nil }
        if let native = nativeApps[evidence.bundleID] { return native }
        guard browsers.contains(evidence.bundleID) else { return nil }
        for value in evidence.urls {
            guard let host = URL(string: value)?.host?.lowercased() else { continue }
            if host == "meet.google.com" { return "Google Meet" }
            if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com") || host == "teams.live.com" || host == "teams.cloud.microsoft" { return "Teams" }
            if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
            if host.hasSuffix(".webex.com") { return "Webex" }
            if host == "app.slack.com" { return "Slack" }
        }
        return nil
    }

    /// Only an explicit speaking label is evidence of a name, never tile order.
    static func speakingName(in labels: [String]) -> String? {
        let patterns = [#"^(.{1,80}) is speaking$"#, #"^Speaking: (.{1,80})$"#, #"^(.{1,80}), speaking$"#]
        var names = Set<String>()
        for label in labels {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                      let range = Range(match.range(at: 1), in: label) else { continue }
                let name = String(label[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !["you", "me"].contains(name.lowercased()) && !name.contains("\n") { names.insert(name) }
            }
        }
        return names.count == 1 ? names.first : nil
    }
}

/// PCM timelines share the capture's host clock. Gaps stay silent; overlaps
/// are trimmed so a device restart cannot shift the rest of the meeting.
enum MeetingTimeline {
    static func alignment(writtenFrames: Int64, presentationSeconds: Double, frameCount: Int, sampleRate: Double = 16_000) -> (silence: Int64, skip: Int) {
        let target = max(0, Int64((presentationSeconds * sampleRate).rounded()))
        return (max(0, target - writtenFrames), min(frameCount, Int(max(0, writtenFrames - target))))
    }
}

enum MeetingError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct MeetingStore {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppName.displayName).appendingPathComponent("Meetings")
    }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    func save(_ meeting: MeetingRecord) throws {
        let folder = directory(meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = folder.appendingPathComponent("meeting.json")
        try encoder.encode(meeting).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func load() throws -> [MeetingRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")),
                  var meeting = try? decoder.decode(MeetingRecord.self, from: data) else { return nil }
            if ["recording", "transcribing", "summarizing"].contains(meeting.status) {
                meeting.status = "interrupted"
            }
            return meeting
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(id)) }

    func removeAudio(_ id: UUID) throws {
        for name in ["microphone.wav", "system.wav"] {
            let file = directory(id).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
