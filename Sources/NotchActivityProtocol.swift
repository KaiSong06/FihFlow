import Foundation

/// Shared with the optional Boring Notch receiver. Only bounded UI state crosses
/// this local connection: never audio, transcript text, error messages or keys.
enum NotchActivityProtocol {
    static let state = Notification.Name("com.kaisong.fihflow.notch.state.v1")
    static let acknowledgement = Notification.Name("com.kaisong.fihflow.notch.ack.v1")
    static let stop = Notification.Name("com.kaisong.fihflow.notch.stop.v1")
    static let preferenceKey = "use_boring_notch"
    static let leaseDuration: TimeInterval = 2
}

struct NotchActivityPacket: Codable, Equatable {
    enum Phase: String, Codable {
        case initializing, recording, processing, error, update, idle
    }

    let version: Int
    let session: UUID
    let sequence: Int
    let senderPID: Int32
    let phase: Phase
    let level: Double
    let canStop: Bool
    let sentAt: TimeInterval

    init(session: UUID, sequence: Int, senderPID: Int32, phase: Phase,
         level: Double, canStop: Bool, sentAt: TimeInterval) {
        version = 1
        self.session = session
        self.sequence = sequence
        self.senderPID = senderPID
        self.phase = phase
        self.level = level.isFinite ? min(1, max(0, level)) : 0
        self.canStop = canStop && phase == .recording
        self.sentAt = sentAt
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ object: Any?, now: TimeInterval) -> Self? {
        guard let string = object as? String, string.utf8.count <= 1024,
              let data = string.data(using: .utf8),
              let packet = try? JSONDecoder().decode(Self.self, from: data),
              packet.version == 1, packet.sequence >= 0, packet.senderPID > 0,
              packet.level.isFinite, (0...1).contains(packet.level),
              packet.sentAt.isFinite, abs(now - packet.sentAt) <= NotchActivityProtocol.leaseDuration,
              !packet.canStop || packet.phase == .recording else { return nil }
        return packet
    }
}

/// A short handshake prevents the two overlays flashing together. A missing or
/// crashed receiver restores FihFlow's controls instead of hiding them forever.
struct NotchActivityLease {
    let startedAt: TimeInterval
    private(set) var acknowledgedAt: TimeInterval?

    mutating func acknowledge(at time: TimeInterval) { acknowledgedAt = time }

    func suppressesLocalOverlay(at time: TimeInterval) -> Bool {
        if let acknowledgedAt {
            return time - acknowledgedAt < NotchActivityProtocol.leaseDuration
        }
        return time - startedAt < 0.4
    }
}

/// Keep the last idle packet too, so a late meter update cannot resurrect an
/// activity after dismissal. Sequence numbers are scoped to a recording session.
struct NotchActivityInbox {
    private(set) var latest: NotchActivityPacket?

    mutating func accept(_ packet: NotchActivityPacket) -> Bool {
        if let latest {
            if packet.session == latest.session {
                guard packet.sequence > latest.sequence else { return false }
            } else {
                guard packet.sentAt > latest.sentAt else { return false }
            }
        }
        latest = packet
        return true
    }
}
