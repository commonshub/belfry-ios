import BelfryCore
import Foundation
import SwiftUI
import UIKit
import UserNotifications

// Push notifications (collective-belfry docs/push.md): ask at a moment that explains it (never at
// launch), register on every start once allowed (a fresh device key K per belfry, shared with the
// Notification Service Extension through the keychain group), remove on sign-out before the
// session is revoked, settings (four switches + a level per channel), a tap opens the channel at
// the message after checking the address is chat.<domain> of this belfry.

enum PushState: Equatable { case unknown, notAsked, on, denied }

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static weak var model: AppModel?
    @MainActor static var pendingTap: [AnyHashable: Any]?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AppDelegate.model?.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            if let m = AppDelegate.model { m.openPush(info) } else { AppDelegate.pendingTap = info }
        }
    }
}

extension AppModel {
    var keychainGroup: String? {
        (Bundle.main.object(forInfoDictionaryKey: "BelfryKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// At start (and when the app comes back): what the system says, and register when allowed.
    func checkPush() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            pushState = .on
            if !isDemo { UIApplication.shared.registerForRemoteNotifications() }
        case .denied: pushState = .denied
        case .notDetermined: pushState = .notAsked
        @unknown default: pushState = .unknown
        }
    }

    /// "Turn on notifications": the system question, then registration.
    func turnOnPush() async {
        UserDefaults.standard.set(true, forKey: "belfry-push-asked")
        let ok = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if ok { pushState = .on; if !isDemo { UIApplication.shared.registerForRemoteNotifications() } } else { await checkPush() }
    }

    /// Whether to offer notifications in a channel (once, until answered or dismissed).
    var offerPush: Bool { pushState == .notAsked && !UserDefaults.standard.bool(forKey: "belfry-push-asked") }

    func dismissPushOffer() {
        UserDefaults.standard.set(true, forKey: "belfry-push-asked")
        objectWillChange.send()
    }

    /// APNs gave a token: register it with K (a new K when this belfry has none yet).
    func didRegister(token: Data) async {
        guard phase == .ready, !isDemo, engine != nil else { return }
        let domain = config.domain
        var key = PushKeyStore.load(group: keychainGroup).flatMap { $0.domain == domain ? $0.key : nil }
        if key == nil {
            let k = Push.newKey()
            PushKeyStore.save(domain: domain, key: k, group: keychainGroup)
            key = k
        }
        UserDefaults.standard.set(token.hex, forKey: "belfry-push-token")
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        _ = try? await api.addPushDevice(token: token, sandbox: sandbox, key: key!, name: UIDevice.current.model)
    }

    /// Sign-out: this device leaves the belfry's push list (before the session is revoked).
    func removePushDevice() async {
        defer {
            PushKeyStore.clear(group: keychainGroup)
            UserDefaults.standard.removeObject(forKey: "belfry-push-token")
        }
        guard !isDemo, let hex = UserDefaults.standard.string(forKey: "belfry-push-token"), let token = Data(hex: hex) else { return }
        try? await api.removePushDevice(token: token)
    }

    /// A tap on a notification: the channel at the message, or Messages, only for this belfry.
    func openPush(_ info: [AnyHashable: Any]) {
        guard phase == .ready, (info["domain"] as? String) == config.domain else { return }
        switch Push.route(info["url"] as? String, domain: config.domain) {
        case .channel(let id, let message): pushOpen = PushOpen(channel: id, message: message)
        case .messages: pushOpen = PushOpen(channel: nil, message: nil)
        case .home: break
        }
    }

    // ---- settings -------------------------------------------------------------------------------

    func loadNotificationSettings() async -> Result<NotificationSettings, ApiError> {
        if isDemo { return .success(demoNotifications) }
        do { return .success(try await api.notificationSettings()) }
        catch let e as ApiError { return .failure(e) } catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    func setNotificationSettings(_ set: [String: Any]) async -> Result<NotificationSettings, ApiError> {
        if isDemo {
            var s = demoNotifications
            for (k, v) in set {
                switch k {
                case "dms": s.dms = v as? Bool ?? s.dms
                case "mentions": s.mentions = v as? Bool ?? s.mentions
                case "announcements": s.announcements = v as? Bool ?? s.announcements
                case "pins": s.pins = v as? Bool ?? s.pins
                case "channels": for (g, l) in v as? [String: String] ?? [:] { s.channels[g] = l }
                default: break
                }
            }
            demoNotifications = s
            return .success(s)
        }
        do { return .success(try await api.notificationSettings(set: set)) }
        catch let e as ApiError { return .failure(e) } catch { return .failure(ApiError("network", 0, BelfryAPI.network)) }
    }

    func pushDevices() async -> [PushDevice] {
        if isDemo { return [] }
        return (try? await api.pushDevices()) ?? []
    }
}

struct PushOpen: Equatable { let channel: String?; let message: String? }

/// "Get notified": shown once in a channel, until answered.
struct PushOffer: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.badge").foregroundStyle(Color.bronze)
            Text("Get a notification when someone mentions you, replies or writes to you.").font(.footnote)
            Spacer(minLength: 4)
            BusyButton("Turn on") { await model.turnOnPush() }.buttonStyle(.borderedProminent).controlSize(.small)
            Button { model.dismissPushOffer() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Not now")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Me → Notifications: the system permission, the four switches, a level per channel, devices.
struct NotificationsView: View {
    @EnvironmentObject var model: AppModel
    @State private var settings: NotificationSettings?
    @State private var devices = [PushDevice]()
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            Section {
                switch model.pushState {
                case .on: Label("Notifications are on for this phone", systemImage: "bell.fill")
                case .denied:
                    Label("Notifications are off in the phone's settings", systemImage: "bell.slash")
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                default:
                    Text("Get a notification when someone mentions you, replies to you, writes to you, or an admin announces or pins something.").font(.footnote)
                    BusyButton("Turn on notifications") { await model.turnOnPush() }.buttonStyle(.borderedProminent)
                }
            }
            if let s = settings {
                Section("Notify me of") {
                    toggle("Direct messages and e-mails", s.dms) { ["dms": $0] }
                    toggle("Mentions and replies", s.mentions) { ["mentions": $0] }
                    toggle("Announcements", s.announcements) { ["announcements": $0] }
                    toggle("Pinned messages", s.pins) { ["pins": $0] }
                }
                Section {
                    ForEach(model.groups.filter { $0.members.contains(model.me) || $0.admins.contains(model.me) }) { g in
                        Picker(selection: Binding(get: { s.level(g.id) }, set: { l in set(["channels": [g.id: l]]) })) {
                            ForEach(NotificationSettings.levels, id: \.id) { Text($0.label).tag($0.id) }
                        } label: { HStack(spacing: 8) { ChannelGlyph(group: g, size: 18); Text(g.name) } }
                    }
                } header: { Text("Channels") } footer: { Text("Default: mentions, replies, announcements and pins. All: every message too.") }
            } else if error == nil {
                Section { ProgressView() }
            }
            if !devices.isEmpty {
                Section("Phones that get notifications") {
                    ForEach(devices) { d in LabeledContent(d.name.isEmpty ? d.app : d.name, value: String(d.since.prefix(10))) }
                }
            }
            if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
        }
        .navigationTitle("Notifications")
        .disabled(busy)
        .task {
            await model.checkPush()
            switch await model.loadNotificationSettings() {
            case .success(let s): settings = s
            case .failure(let e): error = e.message
            }
            devices = await model.pushDevices()
        }
    }

    func toggle(_ title: String, _ on: Bool, _ body: @escaping (Bool) -> [String: Any]) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { set(body($0)) }))
    }

    func set(_ change: [String: Any]) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            switch await model.setNotificationSettings(change) {
            case .success(let s): settings = s
            case .failure(let e): error = e.message
            }
            busy = false
        }
    }
}

/// A channel's push level, next to its e-mail follow in the bell section.
struct PushLevelPicker: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @State private var level: String?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(get: { level ?? "default" }, set: { set($0) })) {
                ForEach(NotificationSettings.levels, id: \.id) { Text($0.label).tag($0.id) }
            } label: {
                HStack { Label("Notifications on this phone", systemImage: "app.badge"); if busy { ProgressView().controlSize(.small) } }
            }
            .disabled(busy || level == nil)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task {
            if case .success(let s) = await model.loadNotificationSettings() { level = s.level(id) }
        }
    }
    func set(_ l: String) {
        guard !busy else { return }
        busy = true
        Task {
            switch await model.setNotificationSettings(["channels": [id: l]]) {
            case .success(let s): level = s.level(id)
            case .failure(let e): error = e.message
            }
            busy = false
        }
    }
}
