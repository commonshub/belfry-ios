import BelfryCore
import SwiftUI

@main
struct BelfryApp: App {
    @StateObject private var model = AppModel()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SwiftUI.Group {
                if let o = model.opening {
                    // a guest link: one loading screen until its channel can be drawn (SPEC 19.26)
                    OpeningScreen(opening: o)
                } else {
                    switch model.phase {
                    case .signedOut:
                        // a code is on its way: that screen first, a guest link waits behind it
                        if model.pendingCode == nil, !model.inviteSignInFirst, let invite = model.pendingInvite {
                            if let p = model.inviteProblem { InviteProblemScreen(problem: p) }
                            else { OpeningScreen(opening: Opening()).onAppear { model.openInvite(invite) } }
                        } else {
                            SignInView(domainHint: model.signInDomainHint ?? model.pendingInvite?.domain)
                        }
                    case .ready: RootView()
                    }
                }
            }
            .environmentObject(model)
            .tint(.bronze)
            .onOpenURL { model.handle(url: $0) }
            .onAppear {
                AppDelegate.model = model
                if let t = AppDelegate.pendingTap { AppDelegate.pendingTap = nil; model.openPush(t) }
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { act in if let u = act.webpageURL { model.handle(url: u) } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.wake()
                    if model.phase == .ready { Task { await model.checkPush() } }
                }
            }
        }
    }
}

extension Color {
    static let bronze = Color(red: 0xa4 / 255, green: 0x53 / 255, blue: 0x2b / 255)
}
