import SwiftUI
import DictationCore
import DictationAppKit
import DictationEngine

@main
struct HarnessApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var subscription: SubscriptionModel
    // Owns the microphone for the Harness Keyboard; one instance for the app's lifetime.
    @StateObject private var dictation: DictationHost
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speakShortcuts = SpeakShortcutRouter.shared

    init() {
        let subscription = SubscriptionModel()
        _subscription = StateObject(wrappedValue: subscription)
        _dictation = StateObject(wrappedValue: DictationHost(dependencies: .init(
            group: AppGroupConfiguration(identifier: "group.org.harness.ios"),
            credentials: KeychainCredentialProvider(),
            computer: nil,
            rewriter: ConfiguredAppleRewriter(group: AppGroupConfiguration(identifier: "group.org.harness.ios")),
            fallbackRewriter: nil,
            checkAccess: { subscription.accessDecision }
        )))
    }

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model).environmentObject(dictation).environmentObject(subscription)
                .preferredColorScheme(.dark)
                .tint(HarnessTheme.coral)
                .fullScreenCover(isPresented: $dictation.showsHandoff) {
                    HandoffListeningView(host: dictation).preferredColorScheme(.dark)
                }
                .onOpenURL { url in
                    switch HarnessLink.parse(url) {
                    case .dictationTab, .dictate: model.selectedTab = .dictation
                    default: break
                    }
                    dictation.handle(url: url)
                }
                .onAppear {
                    // Ask Harness from the keyboard: open GOD with the text in the composer.
                    let appModel = model
                    dictation.onAskGOD = { handoff in appModel.prefillComposer(handoff.text) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    dictation.refreshAccess()
                    dictation.setAppActive(phase == .active)
                    if phase == .background { model.cancel() }
                    if phase == .active {
                        Task { await model.reactivate() }
                        Task {
                            await subscription.refresh()
                            activatePendingSpeakShortcut()
                        }
                    }
                }
                .onChange(of: subscription.state, initial: true) { _, _ in
                    dictation.refreshAccess()
                    activatePendingSpeakShortcut()
                }
                .onChange(of: speakShortcuts.activationID, initial: true) { _, id in
                    guard id != nil else { return }
                    model.selectedTab = .dictation
                    Task {
                        await subscription.refresh()
                        activatePendingSpeakShortcut()
                    }
                }
        }
    }

    @MainActor private func activatePendingSpeakShortcut() {
        guard scenePhase == .active, let id = speakShortcuts.activationID else { return }
        if case .checking = subscription.state { return }
        guard speakShortcuts.consume(id) else { return }
        model.selectedTab = .dictation
        Task {
            await dictation.activate()
            dictation.showsHandoff = dictation.status.phase != .inactive
        }
    }
}
