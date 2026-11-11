import BelfryCore
import SwiftUI

@main
struct BelfryApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SwiftUI.Group {
                switch model.phase {
                case .signedOut:
                    if let invite = model.pendingInvite { JoinScreen(invite: invite) } else { SignInView() }
                case .ready: RootView()
                }
            }
            .environmentObject(model)
            .tint(.bronze)
            .onOpenURL { model.handle(url: $0) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { act in if let u = act.webpageURL { model.handle(url: u) } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.wake() }
            }
        }
    }
}

extension Color {
    static let bronze = Color(red: 0xa4 / 255, green: 0x53 / 255, blue: 0x2b / 255)
}
