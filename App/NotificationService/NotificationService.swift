import BelfryCore
import UserNotifications

// Notification Service Extension (docs/push.md §2, §6): APNs brings a placeholder alert and `b`,
// the notification encrypted to this device's key K (NIP-44 v2, K as the conversation key). Here
// it is opened and the title, body, thread and the address to open on a tap are set. When K is
// missing or `b` doesn't open, the placeholder ("New notification") is shown as it came.

final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let mutable = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content = mutable
        let group = Bundle.main.object(forInfoDictionaryKey: "BelfryKeychainGroup") as? String
        if let b = request.content.userInfo["b"] as? String, let stored = PushKeyStore.load(group: group),
           let c = Push.open(b, key: stored.key), c.domain == stored.domain {
            mutable.title = c.title
            mutable.body = c.body
            mutable.threadIdentifier = c.threadId
            var info = mutable.userInfo
            info["b"] = nil
            info["domain"] = c.domain
            if let u = c.url { info["url"] = u }
            mutable.userInfo = info
        }
        contentHandler(mutable)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}
