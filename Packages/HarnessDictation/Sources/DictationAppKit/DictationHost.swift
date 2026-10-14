#if os(iOS)
import AVFoundation
import Combine
import Foundation
import DictationCore
import DictationEngine

/// The app-side dictation service. It owns the microphone, runs the warm session, transcribes on
/// the chosen route, cleans the text, and answers the keyboard through the App Group bridge.
///
/// Create one at app launch, keep it alive for the app's lifetime, and forward `onOpenURL` and
/// scene-phase changes to it (see Integration/App/HarnessApp+Dictation.swift).
@MainActor
public final class DictationHost: ObservableObject {
    public struct Dependencies {
        public var group: AppGroupConfiguration
        public var credentials: CredentialProvider
        /// The paired-computer feature, if the user has paired one.
        public var computer: PairedComputerTranscription?
        /// On-device model for Fix, Rewrite and AI polish.
        public var rewriter: TextRewriter
        /// Optional: GOD / ModelRouter, used for Fix and Rewrite only when the on-device model is
        /// unavailable. It applies its own routing and permission rules.
        public var fallbackRewriter: TextRewriter?
        /// Evaluated at every session event. Harness injects verified subscription access;
        /// independent library clients retain their existing unrestricted behavior by default.
        public var checkAccess: @MainActor () -> DictationAccessDecision

        public init(
            group: AppGroupConfiguration = AppGroupConfiguration(),
            credentials: CredentialProvider = KeychainCredentialProvider(),
            computer: PairedComputerTranscription? = nil,
            rewriter: TextRewriter = OnDeviceRewriter(),
            fallbackRewriter: TextRewriter? = nil,
            checkAccess: @escaping @MainActor () -> DictationAccessDecision = { .allowed }
        ) {
            self.group = group
            self.credentials = credentials
            self.computer = computer
            self.rewriter = rewriter
            self.fallbackRewriter = fallbackRewriter
            self.checkAccess = checkAccess
        }
    }

    // MARK: Published state for the app UI

    @Published public private(set) var status = HostStatus()
    /// Show the full-screen "Listening — swipe back to your app" view.
    @Published public var showsHandoff = false
    /// The latest finished dictation started inside the app (Try it).
    @Published public private(set) var latestLocalOutcome: DictationOutcome?
    @Published public private(set) var history = TranscriptHistory()
    /// A section of the Dictation tab the app should navigate to (from a deep link).
    @Published public var requestedSection: String?
    @Published public private(set) var lastError: String?
    @Published public private(set) var accessDecision: DictationAccessDecision = .allowed

    /// Called when the keyboard hands text to GOD. The app opens the GOD conversation with it.
    /// Handoffs that arrive before this is set (cold launch) are delivered when it is.
    public var onAskGOD: ((GODHandoff) -> Void)? {
        didSet {
            guard let onAskGOD, !pendingHandoffs.isEmpty else { return }
            let handoffs = pendingHandoffs
            pendingHandoffs.removeAll()
            handoffs.forEach(onAskGOD)
        }
    }
    private var pendingHandoffs: [GODHandoff] = []

    public let settingsStore: DictationSettingsStore
    public let instructionsStore: DictationInstructionsStore
    public var settings: DictationSettings { settingsStore.settings }

    // MARK: Private

    private let deps: Dependencies
    private let files: BridgeFiles?
    private let capture = AudioCapture()
    private let gate = AudioGate()
    private let network = NetworkMonitor()
    private let historyStore = HistoryStore()
    private var machine: SessionMachine
    private var commandObserver: DarwinNotificationObserver?
    private var timer: Timer?
    private var transcriber: SpeechStreamTranscriber?
    private var activeRoute: TranscriptionRoute?
    private var activeSuggestion: ModeSuggester.Suggestion?
    private var localRequestIDs = Set<UUID>()
    private var pendingForegroundStart: DictationRequest?
    private var isAppActive = false
    private var publishScheduled = false
    private var lastHeartbeatWrite = Date.distantPast
    private var settingsCancellable: AnyCancellable?
    private var rewriteTask: Task<Void, Never>?
    private var activeRewriteID: UUID?
    private var finishTask: Task<Void, Never>?

    public init(dependencies: Dependencies = Dependencies()) {
        deps = dependencies
        accessDecision = dependencies.checkAccess()
        files = BridgeFiles(group: dependencies.group)
        let store = DictationSettingsStore(group: dependencies.group)
        settingsStore = store
        instructionsStore = DictationInstructionsStore(group: dependencies.group)
        machine = SessionMachine(config: Self.machineConfig(from: store.settings))
        history = historyStore.load()

        // Pick up whatever the app last published so lastProcessedSeq survives relaunches; but a
        // fresh launch never has a running microphone.
        var restored = files?.readStatus() ?? HostStatus()
        restored.phase = .inactive
        restored.activeRequestID = nil
        restored.partialText = nil
        restored.level = 0
        restored.warmUntil = nil
        status = restored

        // Runs on the audio thread: hand straight to the gate, never touch main-actor state here.
        let gate = self.gate
        capture.onBuffer = { @Sendable buffer in gate.route(buffer) }
        capture.onInterruption = { @Sendable [weak self] in
            Task { @MainActor in self?.handleInterruption() }
        }
        commandObserver = DarwinNotificationObserver(name: BridgeNames.commandsPosted) { [weak self] in
            Task { @MainActor in self?.processCommands() }
        }
        settingsCancellable = settingsStore.$settings.sink { [weak self] settings in
            Task { @MainActor in self?.machine.config = Self.machineConfig(from: settings) }
        }
        publish()
    }

    // MARK: App hooks

    /// Forward `.onOpenURL`. Returns true if the URL belonged to dictation.
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let destination = HarnessLink.parse(url) else { return false }
        switch destination {
        case .dictate:
            Task {
                await activate()
                showsHandoff = machine.phase != .inactive
            }
        case .askGOD:
            processCommands()
        case let .dictationTab(section):
            requestedSection = section ?? "setup"
        }
        return true
    }

    /// Forward scene phase changes (`.active` true/false).
    public func setAppActive(_ active: Bool) {
        isAppActive = active
        if active {
            processCommands()
            if let request = pendingForegroundStart {
                pendingForegroundStart = nil
                Task { await activateAndStart(request) }
            }
        } else if showsHandoff, status.phase == .inactive {
            showsHandoff = false
        }
    }

    /// Starts the microphone session. Call only while the app is in the foreground.
    public func activate() async {
        guard refreshAccess().isAllowed else {
            return failPendingStarts(.subscriptionRequired, accessDecision.denialMessage ?? "A Harness subscription is required.")
        }
        switch AudioCapture.permission {
        case .undetermined:
            guard await AudioCapture.requestPermission() else { return failPendingStarts(.microphoneDenied, "Microphone access is off for Harness.") }
        case .denied:
            return failPendingStarts(.microphoneDenied, "Microphone access is off for Harness. Turn it on in Settings > Harness.")
        default:
            break
        }
        apply(sessionEffects(.activate, now: Date()))
        processCommands()
    }

    private func handleInterruption() {
        apply(sessionEffects(.audioInterrupted, now: Date()))
    }

    /// Turn the microphone off now (the "Stop mic" button).
    public func endSession() {
        apply(sessionEffects(.endSession, now: Date()))
        showsHandoff = false
    }

    // MARK: In-app dictation (Try it, and any Harness text field)

    /// Starts dictating inside the app. The result arrives in `latestLocalOutcome`.
    @discardableResult
    public func startLocalDictation(modeID: String? = nil) async -> UUID {
        let request = DictationRequest(modeID: modeID ?? settings.defaultModeID, languageCode: settings.languageCode, origin: .app)
        localRequestIDs.insert(request.id)
        await activateAndStart(request)
        return request.id
    }

    /// Turns the mic on if needed, then starts `request`. Tries once: if the microphone can't start
    /// (permission off, audio session refused), the request fails instead of retrying.
    private func activateAndStart(_ request: DictationRequest) async {
        guard refreshAccess().isAllowed else {
            apply(sessionEffects(.start(request), now: Date()))
            return
        }
        if machine.phase == .inactive { await activate() }
        guard machine.phase != .inactive else {
            let code: BridgeError.Code = accessDecision.isAllowed ? (AudioCapture.permission == .granted ? .interrupted : .microphoneDenied) : .subscriptionRequired
            deliver(DictationOutcome(requestID: request.id, text: nil, route: nil, duration: 0, completedAt: Date(),
                                     error: BridgeError(code, lastError ?? "Couldn't turn on the microphone.")))
            return
        }
        apply(sessionEffects(.start(request), now: Date()))
    }

    public func stopLocalDictation(_ id: UUID) {
        apply(sessionEffects(.stop(id), now: Date()))
    }

    public func cancelLocalDictation(_ id: UUID) {
        localRequestIDs.remove(id)
        apply(sessionEffects(.cancel(id), now: Date()))
    }

    /// Refresh after entitlement changes or returning to the foreground. A revoked subscription
    /// ends a warm session immediately; each event also rechecks for expiration independently.
    @discardableResult
    public func refreshAccess() -> DictationAccessDecision {
        let decision = deps.checkAccess()
        let previousDenial = accessDecision.denialMessage
        accessDecision = decision
        if let message = decision.denialMessage {
            lastError = message
            status.notice = message
            apply(machine.handle(.tick, now: Date(), access: decision))
            showsHandoff = false
        } else if let previousDenial {
            if lastError == previousDenial { lastError = nil }
            if status.notice == previousDenial { status.notice = nil }
            publish()
        }
        return decision
    }

    private func sessionEffects(_ event: SessionMachine.Event, now: Date) -> [SessionMachine.Effect] {
        let decision = deps.checkAccess()
        accessDecision = decision
        if let message = decision.denialMessage {
            status.notice = message
            lastError = message
        }
        return machine.handle(event, now: now, access: decision)
    }

    // MARK: History

    public func deleteHistoryEntry(_ id: UUID) {
        history.remove(id: id)
        historyStore.save(history)
    }

    public func clearHistory() {
        history.removeAll()
        historyStore.erase()
    }

    // MARK: Availability for the UI

    public func routeAvailability(languageCode: String?) async -> RouteAvailability {
        let locale = languageCode.map(Locale.init(identifier:)) ?? Locale.current
        let support = await OnDeviceTranscriber.support(for: locale)
        let computerPaired = deps.computer?.isPaired ?? false
        let computerReachable = computerPaired ? await (deps.computer?.isReachable() ?? false) : false
        let cloudConfigured: Bool = {
            guard let endpoint = settings.cloudEndpoint else { return false }
            guard let id = endpoint.credentialID else { return true }
            return deps.credentials.secret(for: id) != nil
        }()
        return RouteAvailability(
            onDeviceSupported: support.supported,
            onDeviceInstalled: support.installed,
            computerPaired: computerPaired,
            computerReachable: computerReachable,
            cloudConfigured: cloudConfigured,
            networkAvailable: network.isOnline
        )
    }

    // MARK: Commands from the keyboard

    private func processCommands() {
        guard let files else { return }
        let queue = files.readQueue()
        let pending = queue.pending(after: status.lastProcessedSeq)
        guard !pending.isEmpty else { return }
        let now = Date()
        for command in pending {
            status.lastProcessedSeq = command.seq
            // Commands from long ago (the app wasn't running) are no longer what the user wants.
            let age = now.timeIntervalSince(command.issuedAt)
            switch command.kind {
            case let .start(request):
                guard age < 60 else { continue }
                apply(sessionEffects(.start(request), now: now))
            case let .stop(id):
                apply(sessionEffects(.stop(id), now: now))
            case let .cancel(id):
                apply(sessionEffects(.cancel(id), now: now))
            case let .acknowledge(id):
                if status.outcome?.requestID == id { status.outcome = nil }
            case let .rewrite(job):
                guard age < 60 else { continue }
                runRewrite(job)
            case let .cancelRewrite(jobID):
                cancelRewrite(jobID)
            case let .acknowledgeRewrite(jobID):
                if status.rewrite?.jobID == jobID { status.rewrite = nil }
            case let .askGOD(handoff):
                guard age < 300 else { continue }
                if let onAskGOD { onAskGOD(handoff) } else { pendingHandoffs.append(handoff) }
            case .keepWarm:
                apply(sessionEffects(.keepWarm, now: now))
            case .endSession:
                endSession()
            }
        }
        publish()
    }

    // MARK: Effects

    private func apply(_ effects: [SessionMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startAudio:
                do {
                    try capture.start()
                    startTimer()
                    lastError = nil
                } catch {
                    lastError = error.localizedDescription
                    status.notice = error.localizedDescription
                    apply(sessionEffects(.endSession, now: Date()))
                }
            case .stopAudio:
                capture.stop()
                showsHandoff = false
            case let .beginCapture(request):
                Task { await beginCapture(request) }
            case let .finishCapture(id):
                finishCapture(id)
            case let .abortCapture(id):
                abortCapture(id)
            case let .fail(id, error):
                deliver(DictationOutcome(requestID: id, text: nil, route: nil, duration: 0, completedAt: Date(), error: error))
            case let .requireForeground(request):
                if isAppActive {
                    Task { await activateAndStart(request) }
                } else {
                    // The keyboard opens the app for this; remember the request until it does.
                    pendingForegroundStart = request
                }
            }
        }
        publish()
    }

    private func beginCapture(_ request: DictationRequest) async {
        guard machine.activeRequest?.id == request.id else { return }
        let settings = self.settings
        let suggestion = settings.smartModeFromField
            ? ModeSuggester.suggest(for: request.field, userDefaultModeID: request.modeID)
            : ModeSuggester.Suggestion(modeID: request.modeID, allowsAIPolish: true, dropFinalPeriod: false)
        activeSuggestion = suggestion
        let languageCode = request.languageCode ?? settings.languageCode
        let locale = languageCode.map(Locale.init(identifier:)) ?? Locale.current

        let availability = await routeAvailability(languageCode: languageCode)
        let decision = RouteSelector.select(preference: settings.routePreference, allowCloudFallback: settings.allowCloudFallback, availability: availability)
        guard machine.activeRequest?.id == request.id else { return } // cancelled while deciding
        guard let route = decision.route else {
            failActive(request.id, BridgeError(.routeUnavailable, decision.explanation))
            return
        }
        activeRoute = route
        status.route = route
        status.notice = decision.fellBack || decision.needsModelDownload ? decision.explanation : nil

        let engine: SpeechStreamTranscriber
        switch route {
        case .onDevice:
            engine = OnDeviceTranscriber(locale: locale, contextualStrings: settings.dictionary.contextualStrings)
        case .myComputer:
            let target = await deps.computer?.transcriptionEndpoint()
            guard machine.activeRequest?.id == request.id else { return }
            guard let target else {
                failActive(request.id, BridgeError(.routeUnavailable, "Your computer isn't reachable right now."))
                return
            }
            engine = RemoteTranscriber(endpoint: target.endpoint, bearerToken: target.bearerToken, languageCode: languageCode,
                                       vocabularyPrompt: TranscriptionAPI.vocabularyPrompt(from: settings.dictionary),
                                       maxSeconds: settings.maxUtteranceSeconds)
        case .cloud:
            guard let endpoint = settings.cloudEndpoint else {
                failActive(request.id, BridgeError(.routeUnavailable, "No cloud endpoint is set up."))
                return
            }
            let token = endpoint.credentialID.flatMap { deps.credentials.secret(for: $0) }
            engine = RemoteTranscriber(endpoint: endpoint, bearerToken: token, languageCode: languageCode,
                                       vocabularyPrompt: TranscriptionAPI.vocabularyPrompt(from: settings.dictionary),
                                       maxSeconds: settings.maxUtteranceSeconds)
        }
        guard machine.activeRequest?.id == request.id else { await engine.cancel(); return }
        transcriber = engine
        // Called from the recognizer's thread: hop to the main actor explicitly.
        engine.onPartial = { @Sendable [weak self] text in
            Task { @MainActor in self?.receivePartial(text, for: request.id) }
        }
        // Attach first so no speech is lost while the model loads; the transcriber buffers it.
        gate.attach(engine, silenceAutoStopSeconds: settings.silenceAutoStopSeconds) { @Sendable [weak self] meter in
            Task { @MainActor in self?.receiveMeter(meter, for: request.id) }
        }
        do {
            try await engine.prepare()
            guard machine.activeRequest?.id == request.id else { await engine.cancel(); return }
            if decision.needsModelDownload { status.notice = nil; publishSoon() }
        } catch {
            guard machine.activeRequest?.id == request.id else { await engine.cancel(); return }
            gate.detach()
            failActive(request.id, BridgeError(.modelUnavailable, error.localizedDescription))
        }
    }

    private func receivePartial(_ text: String, for id: UUID) {
        guard machine.activeRequest?.id == id, machine.phase == .listening else { return }
        status.partialText = String(text.suffix(400))
        publishSoon()
    }

    private func receiveMeter(_ meter: AudioGate.Meter, for id: UUID) {
        guard machine.activeRequest?.id == id else { return }
        status.level = meter.level
        if meter.silenceReached {
            apply(sessionEffects(.silence(id), now: Date()))
        } else {
            publishSoon()
        }
    }

    private func finishCapture(_ id: UUID) {
        gate.detach()
        status.level = 0
        guard let engine = transcriber, let request = machine.activeRequest, request.id == id else {
            apply(sessionEffects(.finished(id), now: Date()))
            return
        }
        let started = request.createdAt
        let route = activeRoute
        let suggestion = activeSuggestion
        finishTask?.cancel()
        finishTask = Task {
            do {
                let raw = try await engine.finish()
                guard !Task.isCancelled, machine.activeRequest?.id == id else { return }
                let text = await postProcess(raw, request: request, suggestion: suggestion)
                guard !Task.isCancelled, machine.activeRequest?.id == id else { return }
                if text.isEmpty {
                    deliver(DictationOutcome(requestID: id, text: nil, route: route, duration: Date().timeIntervalSince(started), completedAt: Date(),
                                             error: BridgeError(.emptyTranscript, "Didn't catch that. Try again a little closer to the mic.")))
                } else {
                    deliver(DictationOutcome(requestID: id, text: text, route: route, duration: Date().timeIntervalSince(started), completedAt: Date(), error: nil))
                    recordHistory(text: text, modeID: suggestion?.modeID ?? request.modeID, route: route)
                }
            } catch {
                guard !Task.isCancelled, machine.activeRequest?.id == id else { return }
                let code: BridgeError.Code = (error as? URLError) != nil ? .network : .internalFailure
                deliver(DictationOutcome(requestID: id, text: nil, route: route, duration: Date().timeIntervalSince(started), completedAt: Date(),
                                         error: BridgeError(code, error.localizedDescription)))
            }
            transcriber = nil
            finishTask = nil
            apply(sessionEffects(.finished(id), now: Date()))
        }
    }

    private func abortCapture(_ id: UUID) {
        finishTask?.cancel()
        finishTask = nil
        let engine = gate.detach() ?? transcriber
        transcriber = nil
        status.partialText = nil
        status.level = 0
        localRequestIDs.remove(id)
        Task { await engine?.cancel() }
    }

    private func failActive(_ id: UUID, _ error: BridgeError) {
        guard machine.activeRequest?.id == id else { return }
        gate.detach()
        let engine = transcriber
        transcriber = nil
        Task { await engine?.cancel() }
        deliver(DictationOutcome(requestID: id, text: nil, route: activeRoute, duration: 0, completedAt: Date(), error: error))
        apply(sessionEffects(.finished(id), now: Date()))
    }

    private func failPendingStarts(_ code: BridgeError.Code, _ message: String) {
        lastError = message
        if let files {
            for command in files.readQueue().pending(after: status.lastProcessedSeq) {
                if case let .start(request) = command.kind {
                    deliver(DictationOutcome(requestID: request.id, text: nil, route: nil, duration: 0, completedAt: Date(), error: BridgeError(code, message)))
                }
                status.lastProcessedSeq = command.seq
            }
        }
        if let pending = pendingForegroundStart {
            pendingForegroundStart = nil
            deliver(DictationOutcome(requestID: pending.id, text: nil, route: nil, duration: 0, completedAt: Date(), error: BridgeError(code, message)))
        }
        publish()
    }

    private func postProcess(_ raw: String, request: DictationRequest, suggestion: ModeSuggester.Suggestion?) async -> String {
        let settings = self.settings
        let mode = settings.mode(id: suggestion?.modeID ?? request.modeID)
        var options = mode.cleanupOptions(base: settings.cleanup, languageCode: request.languageCode ?? settings.languageCode ?? Locale.current.language.languageCode?.identifier)
        if suggestion?.dropFinalPeriod == true { options.dropFinalPeriodForShortMessages = true }
        var text = TranscriptCleaner(options: options).clean(raw)
        text = settings.dictionary.apply(to: text)
        let polishAllowed = suggestion?.allowsAIPolish ?? true
        if mode.aiPolish, polishAllowed, !text.isEmpty {
            guard deps.rewriter.isAvailable else {
                let notice = "AI cleanup is unavailable for the selected route. Kept the locally cleaned transcript. Check Speak's AI rewrite route."
                status.notice = notice
                lastError = notice
                return text
            }
            do {
                let voice = try instructionsStore.load()
                let polished = try await deps.rewriter.rewrite(text, instructions: RewritePromptBuilder.polishInstructions(for: mode, userInstructions: voice))
                try Task.checkCancellation()
                text = settings.dictionary.apply(to: try RewriteOutputSanitizer.clean(polished, original: text))
            } catch is CancellationError {
                return text
            } catch {
                // Rule-based dictation remains usable; expose why the requested polish was skipped.
                let notice = "AI polish wasn't applied: \(error.localizedDescription) Kept the locally cleaned transcript."
                status.notice = notice
                lastError = notice
            }
        }
        return text
    }

    private func deliver(_ outcome: DictationOutcome) {
        status.partialText = nil
        if localRequestIDs.remove(outcome.requestID) != nil {
            latestLocalOutcome = outcome
        } else {
            status.outcome = outcome
        }
        if let error = outcome.error { lastError = error.message }
        publish()
    }

    private func recordHistory(text: String, modeID: String, route: TranscriptionRoute?) {
        guard settings.historyEnabled else { return }
        history.add(.init(text: text, modeID: modeID, route: route, createdAt: Date()), retentionDays: settings.historyRetentionDays)
        historyStore.save(history)
    }

    // MARK: Rewrite jobs

    private func runRewrite(_ job: RewriteJob) {
        rewriteTask?.cancel()
        rewriteTask = nil
        activeRewriteID = job.id
        status.rewrite = nil
        let rewriter: TextRewriter?
        if deps.rewriter.isAvailable {
            rewriter = deps.rewriter
        } else if let fallback = deps.fallbackRewriter, fallback.isAvailable {
            rewriter = fallback
        } else {
            rewriter = nil
        }
        guard let rewriter else {
            activeRewriteID = nil
            status.rewrite = RewriteOutcome(jobID: job.id, text: nil, error: BridgeError(.rewriteUnavailable, "The selected AI route is unavailable. Check AI rewrite route in Speak settings. Your text is unchanged."), completedAt: Date())
            publish()
            return
        }
        let instructions: String
        do {
            instructions = RewritePromptBuilder.instructions(for: job.action, modes: settings.modes, userInstructions: try instructionsStore.load())
        } catch {
            activeRewriteID = nil
            status.rewrite = RewriteOutcome(jobID: job.id, text: nil, error: BridgeError(.rewriteUnavailable, error.localizedDescription), completedAt: Date())
            publish()
            return
        }
        let dictionary = settings.dictionary
        rewriteTask = Task {
            do {
                let text = try await rewriter.rewrite(job.text, instructions: instructions)
                guard !Task.isCancelled, activeRewriteID == job.id else { return }
                let cleaned = try RewriteOutputSanitizer.clean(text, original: job.text)
                status.rewrite = RewriteOutcome(jobID: job.id, text: dictionary.apply(to: cleaned), error: nil, completedAt: Date())
            } catch {
                guard !Task.isCancelled, activeRewriteID == job.id else { return }
                status.rewrite = RewriteOutcome(jobID: job.id, text: nil, error: BridgeError(.rewriteUnavailable, "Couldn't rewrite that: \(error.localizedDescription) Your text is unchanged."), completedAt: Date())
            }
            activeRewriteID = nil
            rewriteTask = nil
            publish()
        }
    }

    private func cancelRewrite(_ jobID: UUID) {
        if activeRewriteID == jobID {
            activeRewriteID = nil
            rewriteTask?.cancel()
            rewriteTask = nil
        }
        if status.rewrite?.jobID == jobID { status.rewrite = nil }
    }

    // MARK: Status publishing

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let effects = sessionEffects(.tick, now: Date())
        if !effects.isEmpty {
            apply(effects)
        } else if Date().timeIntervalSince(lastHeartbeatWrite) >= 1 {
            publish()
        }
        if machine.phase == .inactive {
            timer?.invalidate()
            timer = nil
        }
    }

    private func publishSoon() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 15.0) { [weak self] in
            Task { @MainActor in
                self?.publishScheduled = false
                self?.publish()
            }
        }
    }

    private func publish() {
        let now = Date()
        status.heartbeat = now
        status.phase = machine.phase
        status.warmUntil = machine.warmUntil
        status.activeRequestID = machine.activeRequest?.id
        status.activeRequestOrigin = machine.activeRequest?.origin
        if machine.phase != .listening { status.level = 0 }
        status.expireResults(now: now)
        lastHeartbeatWrite = now
        files?.writeStatus(status)
        DarwinNotificationObserver.post(BridgeNames.statusChanged)
    }

    private static func machineConfig(from settings: DictationSettings) -> SessionMachine.Config {
        SessionMachine.Config(
            warmDuration: settings.warmSessionDuration,
            maxUtterance: TimeInterval(settings.maxUtteranceSeconds),
            finishTimeout: 30
        )
    }
}
#endif
