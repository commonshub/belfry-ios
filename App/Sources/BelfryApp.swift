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
                case .signedOut: SignInView()
                case .ready: RootView()
                }
            }
            .environmentObject(model)
            .tint(.bronze)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.wake() }
            }
        }
    }
}

extension Color {
    static let bronze = Color(red: 0xa4 / 255, green: 0x53 / 255, blue: 0x2b / 255)
}
