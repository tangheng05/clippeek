import AppKit
import UserNotifications

/// Says when a video finished uploading; clicking the notification opens it.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Notifications need an app bundle; a bare debug binary would crash asking for them.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func start() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func uploaded(_ url: URL, linkCopied: Bool) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Screen recording uploaded"
        content.body = linkCopied ? "Link copied. Click to open it." : "Click to open it."
        content.userInfo = ["url": url.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: text) else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
