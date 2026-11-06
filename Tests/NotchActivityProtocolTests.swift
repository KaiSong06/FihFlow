import Foundation

enum NotchActivityProtocolTests {
    static func run() {
        let session = UUID()
        let packet = NotchActivityPacket(session: session, sequence: 1, senderPID: 42,
            phase: .recording, level: 0.7, canStop: true, sentAt: 100)
        TestSupport.expectEqual(NotchActivityPacket.decode(packet.encoded, now: 100), packet)
        TestSupport.expect(NotchActivityPacket.decode(packet.encoded, now: 103) == nil, "Stale events must expire")
        TestSupport.expect(NotchActivityPacket.decode(packet.encoded, now: 90) == nil, "Future events must be rejected")
        TestSupport.expect(NotchActivityPacket.decode(String(repeating: "x", count: 1025), now: 100) == nil, "Bound IPC payload size")
        TestSupport.expect(NotchActivityPacket.decode("{}", now: 100) == nil, "Reject incomplete payloads")
        let processing = NotchActivityPacket(session: session, sequence: 2, senderPID: 42,
            phase: .processing, level: .nan, canStop: true, sentAt: 100)
        TestSupport.expectEqual(processing.level, 0)
        TestSupport.expect(!processing.canStop, "Only recording may expose stop")
        let object = try! JSONSerialization.jsonObject(with: Data(packet.encoded!.utf8)) as! [String: Any]
        TestSupport.expectEqual(Set(object.keys), Set(["version", "session", "sequence", "senderPID", "phase", "level", "canStop", "sentAt"]))
        for (key, value) in [("version", 99), ("senderPID", 0), ("sequence", -1)] {
            var invalid = object
            invalid[key] = value
            let text = String(data: try! JSONSerialization.data(withJSONObject: invalid), encoding: .utf8)
            TestSupport.expect(NotchActivityPacket.decode(text, now: 100) == nil, "Reject invalid \(key)")
        }
        var lease = NotchActivityLease(startedAt: 100)
        TestSupport.expect(lease.suppressesLocalOverlay(at: 100.2), "Wait briefly for receiver without duplicate overlays")
        TestSupport.expect(!lease.suppressesLocalOverlay(at: 100.5), "Missing receiver must restore controls")
        lease.acknowledge(at: 100.5)
        TestSupport.expect(lease.suppressesLocalOverlay(at: 101), "Acknowledged receiver owns presentation")
        TestSupport.expect(!lease.suppressesLocalOverlay(at: 102.6), "Receiver crash must restore controls")
        var inbox = NotchActivityInbox()
        TestSupport.expect(inbox.accept(packet), "Accept the first frame")
        TestSupport.expect(!inbox.accept(packet), "Reject duplicate frames")
        let idle = NotchActivityPacket(session: session, sequence: 3, senderPID: 42,
            phase: .idle, level: 0, canStop: false, sentAt: 101)
        TestSupport.expect(inbox.accept(idle), "Accept dismissal")
        TestSupport.expect(!inbox.accept(processing), "A delayed frame must not resurrect a dismissed activity")
        let staleSession = NotchActivityPacket(session: UUID(), sequence: 9, senderPID: 42,
            phase: .recording, level: 0, canStop: true, sentAt: 99)
        TestSupport.expect(!inbox.accept(staleSession), "A previous session must not replace current state")
    }
}
