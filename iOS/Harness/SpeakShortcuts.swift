import AppIntents
import Combine
import Foundation

/// The intent runs in the containing app. It never asks the keyboard to own a microphone.
@MainActor
final class SpeakShortcutRouter: ObservableObject {
    static let shared = SpeakShortcutRouter()
    @Published private(set) var activationID: UUID?
    func requestActivation() { activationID = UUID() }
    func consume(_ id: UUID) -> Bool {
        guard activationID == id else { return false }
        activationID = nil
        return true
    }
}

struct ActivateSpeakIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Speak"
    static var description = IntentDescription("Open Harness and start a microphone session for the Speak keyboard. Subscription and microphone permission are checked in the app.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await SpeakShortcutRouter.shared.requestActivation()
        return .result()
    }
}

struct HarnessSpeakShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ActivateSpeakIntent(), phrases: ["Start Speak in \(.applicationName)", "Start dictation in \(.applicationName)"], shortTitle: "Start Speak", systemImageName: "mic")
    }
}
