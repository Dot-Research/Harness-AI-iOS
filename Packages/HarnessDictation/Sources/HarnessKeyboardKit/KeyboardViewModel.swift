#if os(iOS)
import Combine
import UIKit
import DictationCore
import DictationEngine

/// Drives the Harness Keyboard. All state changes happen on the main thread.
@MainActor
public final class KeyboardViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        /// The app is being opened to start the microphone.
        case waitingForApp
        case listening
        case finishing
        case rewriteMenu
        case rewriting
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var level: Float = 0
    @Published public private(set) var partialText = ""
    @Published public private(set) var message: String?
    @Published public private(set) var canUndo = false
    @Published public private(set) var hasFullAccess = false
    @Published public private(set) var routeLabel = TranscriptionRoute.onDevice.displayName
    @Published public private(set) var micIsWarm = false
    @Published public var selectedModeID: String
    @Published public private(set) var modes: [DictationMode]
    @Published public private(set) var rewriteAvailable = false

    weak var controller: UIInputViewController?
    private let group: AppGroupConfiguration
    private var client: KeyboardBridgeClient?
    private var settingsStore: DictationSettingsStore?
    private lazy var editor = TextProxyEditor { [weak self] in
        self?.controller?.textDocumentProxy
    }
    private let localRewriter = OnDeviceRewriter()
    private var pendingRequestID: UUID?
    /// Requests this keyboard finished or cancelled; never picked up again from status.
    private var dismissedRequestIDs = Set<UUID>()
    private var pendingRewrite: (job: RewriteJob, target: (text: String, isSelection: Bool))?
    private var waitingSince: Date?
    private var messageTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(group: AppGroupConfiguration) {
        self.group = group
        let defaults = DictationSettings()
        selectedModeID = defaults.defaultModeID
        modes = defaults.modes
    }

    // MARK: Lifecycle

    private static let lastHandledKey = "harness.keyboard.lastHandledRequest"

    func appear(hasFullAccess: Bool) {
        self.hasFullAccess = hasFullAccess
        if let raw = group.defaults?.string(forKey: Self.lastHandledKey), let id = UUID(uuidString: raw) {
            dismissedRequestIDs.insert(id)
        }
        rewriteAvailable = localRewriter.isAvailable || hasFullAccess
        KeyboardPresence(lastSeen: Date(), hasFullAccess: hasFullAccess).write(to: group)
        guard hasFullAccess else { return }

        if settingsStore == nil {
            let store = DictationSettingsStore(group: group)
            settingsStore = store
            store.$settings.sink { [weak self] settings in
                Task { @MainActor in self?.apply(settings) }
            }.store(in: &cancellables)
        }
        settingsStore?.reload()

        if client == nil {
            let client = KeyboardBridgeClient(group: group)
            client.onStatus = { [weak self] status in
                Task { @MainActor in self?.receive(status) }
            }
            self.client = client
        }
        client?.startObserving()
        client?.send(.keepWarm)
        refreshUndo()
    }

    func disappear() {
        client?.stopObserving()
        if phase == .rewriteMenu { phase = .idle }
    }

    func textDidChange() {
        refreshUndo()
    }

    private func apply(_ settings: DictationSettings) {
        modes = settings.modes
        if !modes.contains(where: { $0.id == selectedModeID }) { selectedModeID = settings.defaultModeID }
        routeLabel = settings.routePreference == .automatic ? TranscriptionRoute.onDevice.displayName : settings.routePreference.displayName
    }

    // MARK: Dictation

    public func micTapped() {
        switch phase {
        case .listening:
            stop()
        case .waitingForApp, .finishing, .rewriting:
            return
        case .idle, .rewriteMenu:
            start()
        }
    }

    private func start() {
        guard hasFullAccess, let client else {
            show("Turn on Full Access for Harness Keyboard to dictate.")
            return
        }
        let settings = settingsStore?.settings ?? DictationSettings()
        let request = DictationRequest(modeID: selectedModeID, languageCode: settings.languageCode, field: editor.fieldTraits)
        pendingRequestID = request.id
        client.send(.start(request))
        client.setPolling(true)
        haptic()
        if client.status.canStartInPlace(at: Date()) {
            phase = .listening
            partialText = ""
        } else {
            phase = .waitingForApp
            waitingSince = Date()
            guard let controller, HostAppOpener.open(HarnessLink.url(for: .dictate(requestID: request.id)), from: controller) else {
                phase = .idle
                pendingRequestID = nil
                show("Open the Harness app once to turn on the mic, then come back.")
                return
            }
        }
    }

    private func stop() {
        guard let id = pendingRequestID else { return }
        client?.send(.stop(requestID: id))
        phase = .finishing
        haptic()
    }

    public func cancel() {
        if let id = pendingRequestID {
            client?.send(.cancel(requestID: id))
            dismissedRequestIDs.insert(id)
        }
        pendingRequestID = nil
        waitingSince = nil
        phase = .idle
        partialText = ""
        level = 0
        client?.setPolling(false)
    }

    public func endMicSession() {
        client?.send(.endSession)
        micIsWarm = false
    }

    private func receive(_ status: HostStatus) {
        let now = Date()
        micIsWarm = status.canStartInPlace(at: now)
        if let route = status.route { routeLabel = route.displayName }

        // iOS may relaunch the keyboard while the user is in the Harness app. Pick the keyboard's
        // dictation back up from the app's status instead of losing it.
        if pendingRequestID == nil {
            if let active = status.activeRequestID, status.activeRequestOrigin != .app,
               status.phase == .listening || status.phase == .finishing,
               !dismissedRequestIDs.contains(active), status.isAlive(at: now) {
                pendingRequestID = active
                phase = status.phase == .listening ? .listening : .finishing
                client?.setPolling(true)
            } else if let outcome = status.outcome, now.timeIntervalSince(outcome.completedAt) < 20,
                      !dismissedRequestIDs.contains(outcome.requestID) {
                pendingRequestID = outcome.requestID
            }
        }

        if let outcome = status.outcome, outcome.requestID == pendingRequestID {
            finish(with: outcome)
            return
        }
        if let rewrite = status.rewrite, rewrite.jobID == pendingRewrite?.job.id {
            finishRewrite(rewrite)
        }

        guard let id = pendingRequestID else { return }
        if status.activeRequestID == id {
            switch status.phase {
            case .listening:
                if phase != .finishing { phase = .listening }
                level = status.level
                partialText = status.partialText ?? partialText
            case .finishing:
                phase = .finishing
                level = 0
            default:
                break
            }
            waitingSince = nil
        } else if phase == .waitingForApp, let since = waitingSince, now.timeIntervalSince(since) > 25 {
            cancel()
            show("Harness didn't start the mic. Tap to try again.")
        } else if phase == .listening, !status.isAlive(at: now) {
            // The app was stopped while listening (killed, or the microphone was taken).
            cancel()
            show("Dictation stopped. Tap the mic to start again.")
        }
        if let notice = status.notice, phase == .listening || phase == .waitingForApp {
            message = notice
        }
    }

    private func finish(with outcome: DictationOutcome) {
        client?.send(.acknowledge(requestID: outcome.requestID))
        dismissedRequestIDs.insert(outcome.requestID)
        // Survives a keyboard relaunch, so a result is never inserted twice.
        group.defaults?.set(outcome.requestID.uuidString, forKey: Self.lastHandledKey)
        pendingRequestID = nil
        waitingSince = nil
        level = 0
        partialText = ""
        phase = .idle
        client?.setPolling(false)
        if let text = outcome.text, !text.isEmpty {
            let languageCode = settingsStore?.settings.languageCode
            editor.insertDictation(text, languageCode: languageCode)
            refreshUndo()
            haptic()
        } else if let error = outcome.error, error.code != .cancelled {
            show(error.message)
        }
    }

    // MARK: Fix / Rewrite / Ask Harness

    public func fixTapped() {
        rewrite(.fix)
    }

    public func rewriteTapped() {
        phase = phase == .rewriteMenu ? .idle : .rewriteMenu
    }

    public func rewriteChosen(_ action: RewriteAction) {
        phase = .idle
        rewrite(action)
    }

    public struct RewriteChoice: Identifiable {
        public var id: String { title }
        public let title: String
        public let action: RewriteAction
    }

    public var rewriteChoices: [RewriteChoice] {
        [
            RewriteChoice(title: "Clearer", action: .rewrite(modeID: selectedModeID)),
            RewriteChoice(title: "Shorter", action: .instruct("Make it shorter without losing anything important.")),
            RewriteChoice(title: "Friendlier", action: .instruct("Make it warmer and friendlier.")),
            RewriteChoice(title: "Professional", action: .instruct("Make it polished and professional.")),
        ]
    }

    private func rewrite(_ action: RewriteAction) {
        guard let target = editor.rewriteTarget() else {
            show("Select text, or type something first.")
            return
        }
        let modes = self.modes
        phase = .rewriting
        Task {
            // On-device first, inside the keyboard.
            if localRewriter.isAvailable {
                let instructions = RewritePromptBuilder.instructions(for: action, modes: modes)
                if let text = try? await localRewriter.rewrite(target.text, instructions: instructions) {
                    applyRewrite(text, to: target)
                    return
                }
            }
            // Otherwise ask the app (it may use GOD's model routing).
            guard hasFullAccess, let client else {
                phase = .idle
                show("Rewrite needs Apple Intelligence, or Full Access so Harness can help.")
                return
            }
            let job = RewriteJob(action: action, text: target.text)
            pendingRewrite = (job, target)
            client.send(.rewrite(job))
            client.setPolling(true)
            if !client.status.isAlive(at: Date()), let controller {
                HostAppOpener.open(HarnessLink.url(for: .dictationTab(section: "rewrite")), from: controller)
            }
        }
    }

    private func finishRewrite(_ outcome: RewriteOutcome) {
        client?.send(.acknowledgeRewrite(jobID: outcome.jobID))
        client?.setPolling(false)
        guard let pending = pendingRewrite else { return }
        pendingRewrite = nil
        if let text = outcome.text {
            applyRewrite(text, to: pending.target)
        } else {
            phase = .idle
            show(outcome.error?.message ?? "Couldn't rewrite that.")
        }
    }

    private func applyRewrite(_ text: String, to target: (text: String, isSelection: Bool)) {
        phase = .idle
        editor.replaceTarget(target, with: text)
        refreshUndo()
        haptic()
    }

    public func askHarnessTapped() {
        guard hasFullAccess, let client else {
            show("Turn on Full Access to send text to Harness.")
            return
        }
        let text = editor.rewriteTarget()?.text ?? ""
        let handoff = GODHandoff(text: text)
        client.send(.askGOD(handoff))
        if let controller {
            HostAppOpener.open(HarnessLink.url(for: .askGOD(handoffID: handoff.id)), from: controller)
        }
    }

    // MARK: Keys

    public func undoTapped() {
        editor.undo()
        refreshUndo()
    }

    public func insert(_ text: String) {
        editor.insert(text)
        refreshUndo()
    }

    public func deleteBackward() {
        editor.deleteBackward()
        refreshUndo()
    }

    public func openSettings() {
        guard let controller else { return }
        HostAppOpener.open(HarnessLink.url(for: .dictationTab(section: "setup")), from: controller)
    }

    private func refreshUndo() {
        canUndo = editor.canUndo
    }

    // MARK: Feedback

    private func show(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func haptic() {
        guard hasFullAccess, settingsStore?.settings.haptics ?? true else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
#endif
