// FihFlow's optional receiver for Boring Notch v2.7.3.
// Appended to ContentView.swift by prepare.py, together with the shared protocol.
import AppKit
import SwiftUI

@MainActor
final class FihFlowActivity: ObservableObject {
    static let shared = FihFlowActivity()
    @Published private(set) var packet: NotchActivityPacket?
    private var observer: NSObjectProtocol?
    private var expiryTimer: Timer?
    private var lastReceivedAt = 0.0
    private var inbox = NotchActivityInbox()

    var isActive: Bool { packet != nil }

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NotchActivityProtocol.state, object: nil, queue: .main
        ) { [weak self] note in
            let object = note.object as? String
            Task { @MainActor in self?.receive(object) }
        }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.packet != nil else { return }
                if Date.timeIntervalSinceReferenceDate - self.lastReceivedAt > NotchActivityProtocol.leaseDuration {
                    self.packet = nil
                }
            }
        }
    }

    private func receive(_ object: String?) {
        let now = Date.timeIntervalSinceReferenceDate
        guard let incoming = NotchActivityPacket.decode(object, now: now),
              let app = NSRunningApplication(processIdentifier: incoming.senderPID),
              app.bundleIdentifier == "com.kaisong.fihflow", !app.isTerminated else { return }
        guard inbox.accept(incoming) else { return }
        lastReceivedAt = now
        if incoming.phase == .idle {
            packet = nil
        } else {
            packet = incoming
            DistributedNotificationCenter.default().postNotificationName(
                NotchActivityProtocol.acknowledgement, object: incoming.encoded,
                userInfo: nil, deliverImmediately: true)
        }
    }

    func stopRecording() {
        guard let packet, packet.phase == .recording, packet.canStop else { return }
        DistributedNotificationCenter.default().postNotificationName(
            NotchActivityProtocol.stop, object: packet.encoded,
            userInfo: nil, deliverImmediately: true)
    }
}

@MainActor
struct FihFlowNotchActivityView: View {
    @ObservedObject var activity: FihFlowActivity
    let notchWidth: CGFloat
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String {
        switch activity.packet?.phase {
        case .initializing: return "Starting"
        case .recording: return "Listening"
        case .processing: return "Processing"
        case .error: return "Check FihFlow"
        case .update: return "Update ready"
        default: return "FihFlow"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.pink)
                if activity.packet?.phase == .recording {
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(0..<5) { index in
                            Capsule()
                                .fill(Color.pink)
                                .frame(width: 3, height: barHeight(index))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: activity.packet?.level)
                } else if activity.packet?.phase == .error {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else if activity.packet?.phase == .update {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.pink)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                }
            }
            .frame(width: 72)
            Color.clear.frame(width: max(0, notchWidth - 20))
            Group {
                if activity.packet?.canStop == true {
                    Button(action: activity.stopRecording) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 22)
                            .background(Color.pink.opacity(0.3), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Finish FihFlow dictation")
                    .accessibilityLabel("Finish FihFlow dictation")
                } else {
                    Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 72)
        }
        .frame(height: max(24, height))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("FihFlow: \(label)")
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let weights = [0.45, 0.8, 1.0, 0.65, 0.35]
        return 3 + 16 * (activity.packet?.level ?? 0) * weights[index]
    }
}
