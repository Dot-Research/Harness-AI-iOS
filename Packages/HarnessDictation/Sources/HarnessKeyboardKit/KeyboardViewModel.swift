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

    /// Typing layer: letters, numbers and symbols below the control bar, instead of the dictation panel.
    @Published public private(set) var showsKeys = false
    @Published public private(set) var plane: KeyboardPlane = .letters
    @Published public private(set) var shift = ShiftController()
    @Published public private(set) var returnKeyTitle: String?
    @Published public private(set) var spaceBarNeighbors: [String] = []

    weak var controller: UIInputViewController?
    private let group: AppGroupConfiguration
    private var client: KeyboardBridgeClient?
    private var settingsStore: DictationSettingsStore?
    private lazy var editor = TextProxyEditor { [weak self] in
        self?.controller?.textDocumentProxy
    }
    private let localRewriter = OnDeviceRewriter()
    private lazy var instructionsStore = DictationInstructionsStore(group: group)
    private var pendingRequestID: UUID?
    /// Requests this keyboard finished or cancelled; never picked up again from status.
    private var dismissedRequestIDs = Set<UUID>()
    private var pendingRewrite: (job: RewriteJob, target: TextProxyEditor.RewriteTarget)?
    private var rewriteTask: Task<Void, Never>?
    private var activeRewriteID: UUID?
    private var waitingSince: Date?
    /// When a rewrite was handed to the app; used to give up if the app never answers.
    private var rewriteSentAt: Date?
    private var lastSpaceAt: Date?
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
    /// Per keyboard process; the App Group is closed without Full Access, and typing must not need it.
    private static let showsKeysKey = "harness.keyboard.showsKeys"

    func appear(hasFullAccess: Bool) {
        self.hasFullAccess = hasFullAccess
        if let raw = group.defaults?.string(forKey: Self.lastHandledKey), let id = UUID(uuidString: raw) {
            dismissedRequestIDs.insert(id)
        }
        showsKeys = UserDefaults.standard.object(forKey: Self.showsKeysKey) as? Bool ?? !hasFullAccess
        plane = .letters
        refreshTypingContext()
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
        if activeRewriteID != nil || pendingRewrite != nil { cancelRewrite() }
        if phase == .rewriteMenu { phase = .idle }
    }

    func textDidChange() {
        if let pending = pendingRewrite, !editor.targetMatches(pending.target) {
            cancelRewrite()
            show("The text or selection changed. Select it again to rewrite.")
        }
        refreshUndo()
        refreshTypingContext()
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
                client.send(.cancel(requestID: request.id))
                dismissedRequestIDs.insert(request.id)
                client.setPolling(false)
                waitingSince = nil
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
        cancelRewrite()
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
        } else if let sent = rewriteSentAt, phase == .rewriting,
                  (!status.isAlive(at: now) && now.timeIntervalSince(sent) > 25) || now.timeIntervalSince(sent) > 90 {
            // The app never picked the rewrite up, or never answered.
            cancelRewrite()
            show("Harness didn't finish the rewrite. Try again.")
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
            refreshTypingContext()
            haptic()
        } else if let error = outcome.error, error.code != .cancelled {
            show(error.message)
        }
    }

    // MARK: Fix / Rewrite / Ask Harness

    /// Fix, Rewrite and Ask only start from rest. While dictation is listening or finishing, a
    /// rewrite would take over the phase and be stranded when the dictation result arrives.
    public var canUseTextActions: Bool {
        phase == .idle || phase == .rewriteMenu
    }

    public func fixTapped() {
        guard canUseTextActions else { return }
        rewrite(.fix)
    }

    public func rewriteTapped() {
        guard canUseTextActions else { return }
        phase = phase == .rewriteMenu ? .idle : .rewriteMenu
    }

    public func rewriteChosen(_ action: RewriteAction) {
        guard canUseTextActions else { return }
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
        cancelRewrite()
        guard let target = editor.rewriteTarget() else {
            show("Select text, or type something first.")
            return
        }
        let modes = self.modes
        let settings = settingsStore?.settings ?? DictationSettings()
        let job = RewriteJob(action: action, text: target.text)
        activeRewriteID = job.id
        pendingRewrite = (job, target)
        phase = .rewriting
        rewriteTask = Task {
            // On-device first, inside the keyboard.
            if settings.effectiveAppleRewriteRoute != .privateCloudOnly, localRewriter.isAvailable {
                let voice: String
                if hasFullAccess {
                    do { voice = try instructionsStore.load() }
                    catch {
                        guard !Task.isCancelled, activeRewriteID == job.id else { return }
                        cancelRewrite()
                        show(error.localizedDescription)
                        return
                    }
                } else {
                    voice = DictationInstructions.defaultText
                    show("Using the default voice. Full Access is needed for your saved instruction.md.")
                }
                let instructions = RewritePromptBuilder.instructions(for: action, modes: modes, userInstructions: voice)
                if let text = try? await localRewriter.rewrite(target.text, instructions: instructions) {
                    guard !Task.isCancelled, activeRewriteID == job.id else { return }
                    activeRewriteID = nil
                    pendingRewrite = nil
                    rewriteTask = nil
                    applyRewrite(settings.dictionary.apply(to: text), to: target)
                    return
                }
            }
            guard !Task.isCancelled, activeRewriteID == job.id else { return }
            guard editor.targetMatches(target) else {
                cancelRewrite()
                show("The text or selection changed. Select it again to rewrite.")
                return
            }
            // Otherwise ask the app (it may use GOD's model routing).
            guard hasFullAccess, let client else {
                cancelRewrite()
                show("Rewrite needs Apple Intelligence, or Full Access so Harness can help.")
                return
            }
            rewriteTask = nil
            client.send(.rewrite(job))
            client.setPolling(true)
            rewriteSentAt = Date()
            if !client.status.isAlive(at: Date()) {
                guard let controller, HostAppOpener.open(HarnessLink.url(for: .dictationTab(section: "rewrite")), from: controller) else {
                    cancelRewrite()
                    show("Open the Harness app once, then try Rewrite again.")
                    return
                }
            }
        }
    }

    private func finishRewrite(_ outcome: RewriteOutcome) {
        client?.send(.acknowledgeRewrite(jobID: outcome.jobID))
        client?.setPolling(false)
        guard let pending = pendingRewrite, pending.job.id == outcome.jobID, activeRewriteID == outcome.jobID else { return }
        pendingRewrite = nil
        activeRewriteID = nil
        rewriteTask = nil
        rewriteSentAt = nil
        if let text = outcome.text {
            applyRewrite(text, to: pending.target)
        } else {
            phase = .idle
            show(outcome.error?.message ?? "Couldn't rewrite that.")
        }
    }

    private func applyRewrite(_ text: String, to target: TextProxyEditor.RewriteTarget) {
        phase = .idle
        guard editor.replaceTarget(target, with: text) else {
            show("The text or selection changed. Select it again to rewrite.")
            return
        }
        refreshUndo()
        refreshTypingContext()
        haptic()
    }

    private func cancelRewrite() {
        if let activeRewriteID { client?.send(.cancelRewrite(jobID: activeRewriteID)) }
        activeRewriteID = nil
        rewriteTask?.cancel()
        rewriteTask = nil
        pendingRewrite = nil
        rewriteSentAt = nil
        if phase == .rewriting {
            phase = .idle
            client?.setPolling(false)
        }
    }

    public func askHarnessTapped() {
        guard canUseTextActions else { return }
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
        refreshTypingContext()
    }

    public func insert(_ text: String) {
        editor.insert(text)
        lastSpaceAt = nil
        refreshUndo()
        refreshTypingContext()
    }

    public func deleteBackward() {
        editor.deleteBackward()
        lastSpaceAt = nil
        refreshUndo()
        refreshTypingContext()
    }

    // MARK: Typing layer

    public func toggleKeys() {
        showsKeys.toggle()
        UserDefaults.standard.set(showsKeys, forKey: Self.showsKeysKey)
        if phase == .rewriteMenu { phase = .idle }
        plane = .letters
        refreshTypingContext()
    }

    public func keyTapped(_ key: TypingKey) {
        switch key {
        case .character(let character):
            let typed = plane == .letters ? shift.apply(to: character) : character
            editor.insert(typed)
            lastSpaceAt = nil
            shift.characterTyped()
            if TypingKeyboard.returnsToLetters(after: character, on: plane) { plane = .letters }
            refreshUndo()
            refreshTypingContext()
        case .shift:
            shift.tap(at: Date())
        case .delete:
            deleteBackward()
        case .plane(let next):
            plane = next
        }
    }

    public func spaceTapped() {
        let now = Date()
        let keyboardType = editor.fieldTraits.keyboardType
        if let last = lastSpaceAt, now.timeIntervalSince(last) < 0.6,
           TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: editor.textBeforeInput, keyboardType: keyboardType) {
            editor.deleteBackward()
            editor.insert(". ")
            lastSpaceAt = nil
        } else {
            editor.insert(" ")
            lastSpaceAt = now
        }
        if TypingKeyboard.returnsToLetters(after: " ", on: plane) { plane = .letters }
        refreshUndo()
        refreshTypingContext()
    }

    public func returnTapped() {
        editor.insert("\n")
        lastSpaceAt = nil
        refreshUndo()
        refreshTypingContext()
    }

    /// Re-reads the field: automatic capitals, return key title and field-specific keys.
    private func refreshTypingContext() {
        let traits = editor.fieldTraits
        returnKeyTitle = TypingKeyboard.returnKeyTitle(for: traits.returnKeyType)
        spaceBarNeighbors = TypingKeyboard.spaceBarNeighbors(keyboardType: traits.keyboardType)
        let capitalize = TypingKeyboard.shouldCapitalize(before: editor.textBeforeInput, mode: editor.autocapitalization, keyboardType: traits.keyboardType)
        var updated = shift
        updated.autoCapitalize(capitalize)
        if updated != shift { shift = updated }
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
