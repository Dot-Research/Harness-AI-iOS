import SwiftUI
import DictationAppKit
import DictationEngine

@main
struct HarnessApp: App {
    @StateObject private var model = AppModel()
    // Owns the microphone for the Harness Keyboard; one instance for the app's lifetime.
    @StateObject private var dictation = DictationHost(dependencies: .init(
        group: AppGroupConfiguration(identifier: "group.org.harness.ios"),
        credentials: KeychainCredentialProvider(),
        computer: nil,          // paired-computer transcription arrives with the companion endpoint
        rewriter: OnDeviceRewriter(),
        fallbackRewriter: nil
    ))
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(dictation)
                .preferredColorScheme(.dark)
                .tint(HarnessTheme.coral)
                .fullScreenCover(isPresented: $dictation.showsHandoff) {
                    HandoffListeningView(host: dictation).preferredColorScheme(.dark)
                }
                .onOpenURL { url in
                    if case .dictationTab = HarnessLink.parse(url) { model.selectedTab = .dictation }
                    dictation.handle(url: url)
                }
                .onAppear {
                    // Ask Harness from the keyboard: open GOD with the text in the composer.
                    let appModel = model
                    dictation.onAskGOD = { handoff in appModel.prefillComposer(handoff.text) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    dictation.setAppActive(phase == .active)
                    if phase == .background { model.cancel() }
                    if phase == .active { Task { await model.reactivate() } }
                }
        }
    }
}
