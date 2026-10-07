import SwiftUI

@main
struct HarnessApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(HarnessTheme.coral)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.cancel() }
                    if phase == .active { Task { await model.reactivate() } }
                }
        }
    }
}
