import AppKit

/// Main-queue-only publisher. The receiver must acknowledge a current session
/// before the normal overlay can remain hidden. No persistent IPC files.
final class BoringNotchBridge {
    var onPresentationChanged: (() -> Void)?
    var onStop: (() -> Void)?
    private let center = DistributedNotificationCenter.default()
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var session = UUID()
    private var sequence = 0
    private var lease: NotchActivityLease?
    private var phase: NotchActivityPacket.Phase = .idle
    private var level = 0.0
    private var canStop = false
    private var lastSentAt = 0.0
    private var lastSuppression = false
    private var stopRequested = false

    init() {
        observers.append(center.addObserver(forName: NotchActivityProtocol.acknowledgement, object: nil, queue: .main) { [weak self] note in
            guard let self, let packet = self.currentReply(note),
                  packet.sequence <= self.sequence else { return }
            self.lease?.acknowledge(at: Date.timeIntervalSinceReferenceDate)
            self.refreshPresentation()
        })
        observers.append(center.addObserver(forName: NotchActivityProtocol.stop, object: nil, queue: .main) { [weak self] note in
            guard let self, self.currentReply(note) != nil,
                  self.phase == .recording, self.canStop, !self.stopRequested else { return }
            self.stopRequested = true
            self.onStop?()
        })
    }

    deinit {
        timer?.invalidate()
        observers.forEach(center.removeObserver)
    }

    var suppressesLocalOverlay: Bool {
        lease?.suppressesLocalOverlay(at: Date.timeIntervalSinceReferenceDate) ?? false
    }

    func present(phase: NotchActivityPacket.Phase, canStop: Bool) {
        guard UserDefaults.standard.bool(forKey: NotchActivityProtocol.preferenceKey) else {
            end()
            return
        }
        if lease == nil {
            session = UUID()
            sequence = 0
            stopRequested = false
            lease = NotchActivityLease(startedAt: Date.timeIntervalSinceReferenceDate)
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.send()
                self?.refreshPresentation()
            }
        }
        self.phase = phase
        self.canStop = canStop
        send()
        lastSuppression = suppressesLocalOverlay
    }

    func updateLevel(_ value: Float) {
        level = value.isFinite ? Double(min(1, max(0, value))) : 0
        // Audio metering can arrive at a much higher frequency than the UI needs.
        if lease != nil, Date.timeIntervalSinceReferenceDate - lastSentAt >= 1.0 / 15 { send() }
    }

    func end() {
        if lease != nil {
            phase = .idle
            canStop = false
            send()
        }
        timer?.invalidate()
        timer = nil
        lease = nil
        lastSuppression = false
    }

    private func currentReply(_ note: Notification) -> NotchActivityPacket? {
        guard lease != nil,
              let packet = NotchActivityPacket.decode(note.object, now: Date.timeIntervalSinceReferenceDate),
              packet.session == session, packet.senderPID == ProcessInfo.processInfo.processIdentifier,
              packet.phase == phase, packet.sequence <= sequence else { return nil }
        return packet
    }

    private func send() {
        sequence += 1
        lastSentAt = Date.timeIntervalSinceReferenceDate
        let packet = NotchActivityPacket(session: session, sequence: sequence,
            senderPID: ProcessInfo.processInfo.processIdentifier, phase: phase,
            level: level, canStop: canStop, sentAt: lastSentAt)
        guard let object = packet.encoded else { return }
        // Sandboxed Boring Notch can receive an object string; userInfo is nil.
        center.postNotificationName(NotchActivityProtocol.state, object: object, userInfo: nil, deliverImmediately: true)
    }

    private func refreshPresentation() {
        let suppress = suppressesLocalOverlay
        guard suppress != lastSuppression else { return }
        lastSuppression = suppress
        onPresentationChanged?()
    }
}
