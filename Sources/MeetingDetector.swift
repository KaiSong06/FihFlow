import AppKit
import ApplicationServices

struct DetectedMeeting: Identifiable, Sendable {
    var id: String
    var platform: String
    var pid: pid_t
    var speakerName: String?
}

enum MeetingDetector {
    /// Bounded, read-only Accessibility inspection. Never persists raw UI text or URLs.
    static func scan(preferredPID: pid_t? = nil) -> [DetectedMeeting] {
        guard AXIsProcessTrusted() else { return [] }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return MeetingDetectionRules.nativeApps[id] != nil || MeetingDetectionRules.browsers.contains(id)
        }.sorted { ($0.processIdentifier == preferredPID ? 0 : 1) < ($1.processIdentifier == preferredPID ? 0 : 1) }
        var results: [DetectedMeeting] = []
        let deadline = Date().addingTimeInterval(2)
        for app in candidates where Date() < deadline {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            for (index, window) in children(element, kAXWindowsAttribute).enumerated() where Date() < deadline {
                var evidence = MeetingDetectionEvidence(bundleID: app.bundleIdentifier ?? "", urls: [], controls: [], labels: [])
                var pending = [window]
                var cursor = 0
                while cursor < pending.count && cursor < 1600 && Date() < deadline {
                    let item = pending[cursor]
                    cursor += 1
                    let role = string(item, kAXRoleAttribute)
                    let labels = [string(item, kAXTitleAttribute), string(item, kAXDescriptionAttribute), string(item, kAXHelpAttribute), role == kAXStaticTextRole ? string(item, kAXValueAttribute) : ""].filter { !$0.isEmpty }
                    if [kAXButtonRole, kAXCheckBoxRole, kAXMenuButtonRole].contains(role) { evidence.controls += labels }
                    evidence.labels += labels
                    for attribute in [kAXURLAttribute, kAXDocumentAttribute] {
                        let url = string(item, attribute)
                        if url.hasPrefix("https://") { evidence.urls.append(url) }
                    }
                    pending += children(item, kAXChildrenAttribute).prefix(max(0, 1600 - pending.count))
                }
                if let platform = MeetingDetectionRules.platform(evidence) {
                    results.append(DetectedMeeting(id: "\(app.processIdentifier):\(index):\(platform)", platform: platform, pid: app.processIdentifier, speakerName: MeetingDetectionRules.speakingName(in: evidence.labels)))
                }
            }
        }
        return results
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        if let value = value as? String { return String(value.prefix(500)) }
        if let value = value as? URL { return value.absoluteString }
        return ""
    }

    private static func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
