import Foundation

enum MeetingTests {
    static func run() async {
        detection()
        timeline()
        persistence()
        await summaries()
    }

    private static func detection() {
        var evidence = MeetingDetectionEvidence(bundleID: "com.google.Chrome", urls: ["https://meet.google.com/abc-defg-hij"], controls: ["Join now"], labels: [])
        TestSupport.expectEqual(MeetingDetectionRules.platform(evidence), nil)
        evidence.controls = ["Leave call"]
        TestSupport.expectEqual(MeetingDetectionRules.platform(evidence), "Google Meet")
        evidence.urls = ["https://meet.google.com.example.test/"]
        TestSupport.expectEqual(MeetingDetectionRules.platform(evidence), nil)
        evidence.urls = ["https://teams.microsoft.com/meeting"]
        TestSupport.expectEqual(MeetingDetectionRules.platform(evidence), "Teams")
        evidence.urls = ["https://teams.cloud.microsoft/v2/"]
        TestSupport.expectEqual(MeetingDetectionRules.platform(evidence), "Teams")
        evidence.bundleID = "us.zoom.xos"
        evidence.controls = ["Leave", "Mute My Audio"]
        TestSupport.expectEqual(MeetingDetectionRules.platform(evidence), "Zoom")
        evidence.controls = ["Leave"]
        TestSupport.expectEqual(MeetingDetectionRules.platform(evidence), nil)
        TestSupport.expectEqual(MeetingDetectionRules.speakingName(in: ["Taylor", "Morgan"]), nil)
        TestSupport.expectEqual(MeetingDetectionRules.speakingName(in: ["Taylor is speaking"]), "Taylor")
        TestSupport.expectEqual(MeetingDetectionRules.speakingName(in: ["Taylor is speaking", "Morgan is speaking"]), nil)
        TestSupport.expectEqual(MeetingDetectionRules.speakingName(in: ["You is speaking"]), nil)
    }

    private static func timeline() {
        let gap = MeetingTimeline.alignment(writtenFrames: 16_000, presentationSeconds: 3, frameCount: 160)
        TestSupport.expectEqual(gap.silence, 32_000)
        TestSupport.expectEqual(gap.skip, 0)
        let overlap = MeetingTimeline.alignment(writtenFrames: 16_080, presentationSeconds: 1, frameCount: 160)
        TestSupport.expectEqual(overlap.silence, 0)
        TestSupport.expectEqual(overlap.skip, 80)
        TestSupport.expectEqual(MeetingTimeline.alignment(writtenFrames: 32_000, presentationSeconds: 1, frameCount: 160).skip, 160)
        TestSupport.expectEqual(MeetingRecord.timestamp(3_661), "01:01:01")
    }

    private static func persistence() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        do {
            var record = MeetingRecord(title: "Synthetic meeting")
            record.transcript = .init(segments: [.init(id: "s1", start: 1, end: 3, speaker: "me", text: "I will send the draft.")], speakers: [.init(id: "me", name: "Me", source: "microphone")])
            try store.save(record)
            let saved = try store.load()
            TestSupport.expectEqual(saved.count, 1)
            TestSupport.expectEqual(saved[0].status, "interrupted")
            TestSupport.expectEqual(saved[0].transcriptText, "[00:00:01] Me: I will send the draft.")
            let permissions = try FileManager.default.attributesOfItem(atPath: store.directory(record.id).appendingPathComponent("meeting.json").path)[.posixPermissions] as? NSNumber
            TestSupport.expectEqual(permissions?.intValue, 0o600)
            for name in ["microphone.wav", "system.wav"] { try Data().write(to: store.directory(record.id).appendingPathComponent(name)) }
            try store.removeAudio(record.id)
            let afterAudioRemoval = try store.load()
            TestSupport.expectEqual(afterAudioRemoval.count, 1)
            TestSupport.expect(!FileManager.default.fileExists(atPath: store.directory(record.id).appendingPathComponent("system.wav").path), "Audio should be removed without deleting notes")
            try store.delete(record.id)
            let afterDeletion = try store.load()
            TestSupport.expectEqual(afterDeletion.count, 0)
        } catch { fatalError("Synthetic meeting persistence failed") }
    }

    private static func summaries() async {
        let segments = (0..<30).map { MeetingSegment(id: "s\($0)", start: Double($0), end: Double($0 + 1), speaker: "me", text: String(repeating: "Synthetic discussion. ", count: 100)) }
        let chunks = MeetingSummaryService.chunks(segments)
        TestSupport.expect(chunks.count > 6, "Large meetings should be processed in multiple chunks")
        TestSupport.expectEqual(Set(chunks.flatMap { $0.map(\.id) }), Set(segments.map(\.id)))
        TestSupport.expectEqual(chunks[1].first?.id, chunks[0].suffix(2).first?.id)
        let action = MeetingActionItem(assignee: "me", task: "Send the draft", due: "Friday", evidence: ["s0"])
        let other = MeetingActionItem(assignee: "remote-0", task: "Send the budget", due: "", evidence: ["s0"])
        let invented = MeetingActionItem(assignee: "me", task: "Invented task", due: "", evidence: ["missing"])
        TestSupport.expectEqual(MeetingSummaryService.validActions([action, other, invented], target: "me", segments: segments), [action])
        var record = MeetingRecord(title: "Synthetic meeting")
        record.transcript = .init(segments: segments, speakers: [.init(id: "me", name: "Me", source: "microphone")])
        var sent = Set<String>(), calls = 0
        var service = MeetingSummaryService(apiKey: "synthetic-test-key", baseURL: "https://example.test/v1", model: "synthetic-model") { request in
            calls += 1
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            TestSupport.expectEqual(payload["model"] as? String, "synthetic-model")
            let messages = payload["messages"] as! [[String: String]]
            let content = messages[1]["content"]!
            var actions: [MeetingActionItem] = []
            if let input = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] {
                TestSupport.expectEqual(input["target"] as? String, "me")
                let current = input["segments"] as! [[String: Any]]
                let ids = current.map { $0["id"] as! String }
                sent.formUnion(ids)
                if ids.contains("s0") { actions = [action, other, invented] }
            }
            return try response(MeetingBrief(summary: "A synthetic summary", decisions: ["Keep the launch date"], actions: actions), url: request.url!)
        }
        do {
            let result = try await service.summarize(record)
            TestSupport.expectEqual(sent, Set(segments.map(\.id)))
            TestSupport.expect(calls > chunks.count, "Summary must reduce every chunk")
            TestSupport.expectEqual(result.actions, [action])
            service.transport = { request in
                let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let messages = payload["messages"] as! [[String: String]]
                let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
                TestSupport.expectEqual(input["target"] as? String, "remote-0")
                return try response(MeetingBrief(summary: "", decisions: [], actions: [action, other]), url: request.url!)
            }
            record.transcript.segments = [segments[0]]
            let requested = try await service.summarize(record, target: "remote-0")
            TestSupport.expectEqual(requested.actions, [other])
            service.transport = { request in try response(MeetingBrief(summary: "truncated", decisions: [], actions: []), url: request.url!, finish: "length") }
            do { _ = try await service.summarize(record); fatalError("Truncated responses must not be saved as complete") }
            catch is MeetingError { }
            service.transport = { request in (Data("SYNTHETIC_PRIVATE_PROVIDER_ERROR".utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!) }
            do { _ = try await service.summarize(record); fatalError("Rejected requests must fail") }
            catch { TestSupport.expect(!error.localizedDescription.contains("SYNTHETIC_PRIVATE"), "Provider response must not leak into errors") }
        } catch { fatalError("Synthetic meeting summary failed: \(error)") }
    }

    private static func response(_ brief: MeetingBrief, url: URL, finish: String = "stop") throws -> (Data, URLResponse) {
        let content = String(decoding: try JSONEncoder().encode(brief), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": finish, "message": ["content": content]]]])
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
