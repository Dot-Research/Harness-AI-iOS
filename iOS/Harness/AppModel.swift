import SwiftUI
import HarnessCore
import LocalAuthentication
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    @Published var state = HarnessState()
    @Published var sessionID: UUID?
    @Published var isWorking = false
    @Published var error: String?
    @Published var pendingPermission: PermissionRequest?
    @Published var pendingDecision: PermissionDecision?
    @Published private(set) var appleModelAvailable = AppleModelProvider.isAvailable
    @Published private(set) var appleModelAvailabilityDescription = AppleModelProvider.availabilityDescription
    @Published var selectedTab: HarnessTab = .god
    @Published var directorNavigationID = UUID()
    /// Text handed to GOD from elsewhere (Ask Harness in the keyboard); the composer takes it once.
    @Published var composerPrefill: String?
    private var store: SQLiteHarnessStore?
    private var runtime: AgentRuntime?
    private var providers: [any ModelProvider] = []
    private var work: Task<Void, Never>?
    private var cancellationRequested = false
    private var permissionContinuation: CheckedContinuation<PermissionAnswer, Never>?
    private let companion = CompanionClient()
    /// Markdown notes. Agents read only folders the user marks readable (see VaultAccessPolicy).
    let vault = VaultModel()

    init() { Task { await initialize() } }
    var currentSession: AgentSession? { state.sessions.first { $0.id == sessionID } }
    private var chosenProvider: (any ModelProvider)? { try? ModelRouter.select(providers: providers, preference: state.routingPreference) }
    var hasAvailableModel: Bool { chosenProvider != nil }
    var routeUsesAppleModel: Bool { chosenProvider?.id == "apple" }
    var routeIsLocal: Bool { chosenProvider?.isLocal ?? true }
    var canSend: Bool { runtime != nil && chosenProvider != nil && !isWorking }
    var appleModelStatusDescription: String {
        guard state.providers.contains(where: { $0.kind == .apple && $0.enabled }) else {
            return "Apple Foundation Models is disabled in Harness. " + appleModelAvailabilityDescription
        }
        return appleModelAvailabilityDescription
    }
    var routeDescription: String {
        guard let provider = chosenProvider else { return "No available model" }
        guard let config = state.providers.first(where: { $0.id == provider.id }) else { return provider.id }
        if config.kind == .apple { return "On this iPhone · Apple Intelligence" }
        return "\(config.name) · \(URL(string: config.endpoint)?.host ?? "configured endpoint")"
    }
    var readinessDescription: String {
        if chosenProvider != nil { return routeIsLocal ? "Your next message stays on this device." : "Cloud context transmission requires your permission." }
        if state.routingPreference == .localOnly { return "\(appleModelStatusDescription) You can use a local endpoint or opt into a cloud provider in Me → Providers." }
        return "Configure and enable a provider with a model and API key in Me → Providers."
    }

    private func initialize() async {
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let storage = try SQLiteHarnessStore(url: base.appendingPathComponent("Harness/harness.sqlite"))
            store = storage
            let loaded = try await storage.load()
            if loaded.files.isEmpty && loaded.agents.isEmpty && loaded.providers.isEmpty {
                let seed = HarnessSeed.makeState()
                try await storage.update { $0 = seed }
            }
            if loaded.directorName == "GOD" {
                try await storage.update { state in
                    state.directorName = "General Orchestrator Director"
                    if let index = state.agents.firstIndex(where: { $0.id == "god" && $0.name == "GOD" }) {
                        state.agents[index].name = state.directorName
                        state.agents[index].purpose = "General Orchestrator Director: your main conversation in Dot."
                    }
                }
            }
            try await refresh()
            sessionID = state.sessions.sorted { $0.updatedAt > $1.updatedAt }.first?.id
        } catch { self.error = error.localizedDescription }
    }
    private func refresh() async throws {
        guard let store else { return }
        state = try await store.load()
        appleModelAvailable = AppleModelProvider.isAvailable
        appleModelAvailabilityDescription = AppleModelProvider.availabilityDescription
        var available: [any ModelProvider] = []
        for config in state.providers where config.enabled {
            if config.kind == .apple {
                if appleModelAvailable { available.append(AppleModelProvider()) }
            } else {
                guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let id = config.id
                let provider = try OpenAICompatibleProvider(configuration: config, credential: { try KeychainStore.shared.token(for: "provider:\(id)") })
                if provider.isLocal { available.append(provider) }
                else if try KeychainStore.shared.token(for: "provider:\(id)") != nil { available.append(provider) }
            }
        }
        providers = available
        if !isWorking { runtime = AgentRuntime(store: store, providers: available, externalExecutor: companion, vault: vault.store) }
    }
    private func change(_ mutation: @escaping @Sendable (inout HarnessState) -> Void) async {
        guard let store else { error = "The local store is unavailable."; return }
        do { try await store.update(mutation); try await refresh() } catch { self.error = error.localizedDescription }
    }
    func newSession(agentID: String = "god") async {
        guard !isWorking else { return }
        let session = AgentSession(agentID: agentID)
        await change { $0.sessions.append(session) }
        if state.sessions.contains(where: { $0.id == session.id }) { sessionID = session.id }
    }
    func selectSession(_ id: UUID) { if !isWorking { sessionID = id } }
    func send(_ text: String) async {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, canSend, let runtime else { return }
        // Reserve the turn before any await, including first-session creation.
        isWorking = true; cancellationRequested = false; error = nil
        if sessionID == nil {
            let session = AgentSession()
            await change { $0.sessions.append(session) }
            if state.sessions.contains(where: { $0.id == session.id }) { sessionID = session.id }
        }
        guard let id = sessionID, !cancellationRequested else { isWorking = false; return }
        let agent = currentSession?.agentID ?? "god"
        if let index = state.sessions.firstIndex(where: { $0.id == id }) {
            state.sessions[index].messages.append(AgentMessage(role: .user, content: input))
        }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await runtime.run(input: input, sessionID: id, agentID: agent, permissionHandler: { [weak self] request, decision in
                    guard let self else { return .denyOnce }
                    return await self.askPermission(request, decision: decision)
                })
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        await work?.value
        work = nil; isWorking = false
        do { try await refresh() } catch { self.error = error.localizedDescription }
    }
    func cancel() {
        cancellationRequested = true
        work?.cancel()
        completePermission(.denyOnce)
    }
    private func askPermission(_ request: PermissionRequest, decision: PermissionDecision) async -> PermissionAnswer {
        if Task.isCancelled { return .denyOnce }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                permissionContinuation = continuation
                pendingPermission = request; pendingDecision = decision
                if Task.isCancelled { completePermission(.denyOnce) }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.completePermission(.denyOnce) } }
    }
    func resolvePermission(_ answer: PermissionAnswer) {
        guard permissionContinuation != nil else { return }
        let allowed: Bool
        switch answer { case .allowOnce, .alwaysAllow: allowed = true; case .denyOnce, .alwaysDeny: allowed = false }
        if pendingDecision == .biometric && allowed {
            let requestID = pendingPermission?.id
            Task {
                do {
                    let context = LAContext()
                    let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Authorize this sensitive Harness action.")
                    guard pendingPermission?.id == requestID else { return }
                    completePermission(success ? .allowOnce : .denyOnce)
                } catch {
                    guard pendingPermission?.id == requestID else { return }
                    completePermission(.denyOnce)
                    self.error = "Biometric approval was not completed. The action was denied."
                }
            }
        } else { completePermission(answer) }
    }
    private func completePermission(_ answer: PermissionAnswer) {
        let continuation = permissionContinuation
        permissionContinuation = nil; pendingPermission = nil; pendingDecision = nil
        continuation?.resume(returning: answer)
    }
    func clearError() { error = nil }
    /// Opens the director conversation for a reviewed handoff. No message is sent automatically.
    @discardableResult func prefillComposer(_ text: String) -> Bool {
        guard !isWorking else { error = "Finish the current task before opening a new director request."; return false }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16_000))
        sessionID = state.sessions.filter { $0.agentID == "god" }.max { $0.updatedAt < $1.updatedAt }?.id
        selectedTab = .god
        directorNavigationID = UUID()
        composerPrefill = trimmed.isEmpty ? nil : trimmed
        return true
    }
    func reactivate() async {
        guard store != nil, !isWorking else { return }
        do { try await refresh() } catch { self.error = error.localizedDescription }
    }
    func saveFile(_ file: AgentFile, text: String) async {
        guard text.utf8.count <= 128 * 1024 else { error = "Agent files must be smaller than 128 KB."; return }
        await change { state in
            state.files[file.rawValue] = text
            state.activity.append(ActivityEntry(title: "\(file.rawValue) edited", detail: "Edited directly by you."))
        }
    }
    func approveLearning(_ id: UUID, edited: String? = nil) async {
        guard let store else { return }
        do {
            if let edited {
                guard edited.utf8.count <= 128 * 1024 else { error = "Learning changes must be smaller than 128 KB."; return }
                try await store.update { state in
                    if let index = state.proposals.firstIndex(where: { $0.id == id }) { state.proposals[index].after = edited }
                }
            }
            try await LearningKernel(store: store).approve(id: id)
            try await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func rejectLearning(_ id: UUID) async {
        guard let store else { return }
        do { try await LearningKernel(store: store).reject(id: id); try await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func revertLearning(_ id: UUID) async {
        guard let store else { return }
        do { try await LearningKernel(store: store).revert(entryID: id); try await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func saveSkill(_ skill: Skill) async {
        guard !skill.name.isEmpty, !skill.markdown.isEmpty, skill.markdown.utf8.count <= 128 * 1024 else { error = "Give the skill a name and Markdown instructions under 128 KB."; return }
        await change { state in
            if let index = state.skills.firstIndex(where: { $0.id == skill.id }) {
                var updated = skill; updated.version = state.skills[index].version + 1
                state.skills[index] = updated
            } else { state.skills.append(skill) }
            if skill.enabled, let director = state.agents.firstIndex(where: { $0.id == "god" }),
               !state.agents[director].allowedSkills.contains(skill.id) {
                state.agents[director].allowedSkills.append(skill.id)
            }
            state.activity.append(ActivityEntry(title: "Skill saved: \(skill.name)", detail: "Edited directly by you. Native execution privileges are unchanged."))
        }
    }
    func removeSkill(_ id: String) async {
        await change { state in
            state.skills.removeAll { $0.id == id }
            for index in state.agents.indices { state.agents[index].allowedSkills.removeAll { $0 == id } }
            state.activity.append(ActivityEntry(title: "Skill removed", detail: id))
        }
    }
    func saveProvider(_ configuration: ProviderConfiguration, key: String) async {
        guard !isWorking else { error = "Wait for the current turn before changing providers."; return }
        do {
            if configuration.kind != .apple {
                _ = try OpenAICompatibleProvider.validateEndpoint(configuration.endpoint)
                guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderFailure.missingModel }
            }
            if !key.isEmpty { try KeychainStore.shared.set(key, for: "provider:\(configuration.id)") }
            await change { state in
                if let index = state.providers.firstIndex(where: { $0.id == configuration.id }) { state.providers[index] = configuration }
                else { state.providers.append(configuration) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func removeProvider(_ id: String) async {
        guard !isWorking else { return }
        do { try KeychainStore.shared.remove("provider:\(id)"); await change { $0.providers.removeAll { $0.id == id } } }
        catch { self.error = error.localizedDescription }
    }
    func pair(_ payload: String) async {
        guard !isWorking else { error = "Finish the current turn before pairing."; return }
        do {
            var device = try await companion.pair(payload: payload, deviceName: UIDevice.current.name)
            device.capabilities = device.availableCapabilities.intersection([.computerRead])
            let paired = device
            await change { state in
                state.devices.removeAll { $0.id == paired.id }; state.devices.append(paired)
                state.activity.append(ActivityEntry(title: "Computer paired", detail: "\(paired.name): \(paired.capabilities.map(\.rawValue).sorted().joined(separator: ", "))", destination: URL(string: paired.url)?.host))
            }
        } catch { self.error = error.localizedDescription }
    }
    func unpair(_ id: String) async {
        guard !isWorking else { return }
        do { try companion.removeCredentials(for: id); await change { $0.devices.removeAll { $0.id == id }; $0.remoteAgents?.removeAll { $0.deviceID == id } } }
        catch { self.error = error.localizedDescription }
    }
    func saveRemoteAgent(_ connection: RemoteAgentConnection) async -> Bool {
        guard !isWorking else { error = "Finish the current turn before changing an agent route."; return false }
        guard let device = state.devices.first(where: { $0.id == connection.deviceID }) else { error = "Pair the computer first."; return false }
        do {
            // Validate configuration independently of the separate execution grant.
            var validationDevice = device; validationDevice.capabilities.insert(.computerExecute)
            _ = try RemoteAgentExecutionPlan(connection: connection, device: validationDevice, task: "Validate configuration")
            error = nil
            await change { state in
                var routes = state.remoteAgentConnections
                routes.removeAll { $0.id == connection.id }; routes.append(connection)
                state.remoteAgents = routes
                state.activity.append(ActivityEntry(title: "Remote agent route saved", detail: "\(connection.name): \(connection.runtime.rawValue), \(connection.routeDescription)", destination: device.name))
            }
            return error == nil
        } catch { self.error = error.localizedDescription; return false }
    }
    func removeRemoteAgent(_ id: String) async {
        guard !isWorking else { return }
        await change { $0.remoteAgents?.removeAll { $0.id == id } }
    }
    func updateDeviceCapabilities(_ id: String, capabilities: Set<Capability>) async {
        await change { state in
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            state.devices[index].capabilities = capabilities.intersection(state.devices[index].availableCapabilities)
            state.activity.append(ActivityEntry(title: "Computer permissions changed", detail: "\(state.devices[index].name): \(state.devices[index].capabilities.map(\.rawValue).sorted().joined(separator: ", "))"))
        }
    }
    func clearPermissionRule(_ key: String) async {
        await change { state in
            state.permissionRules.removeValue(forKey: key)
            state.activity.append(ActivityEntry(title: "Permission override reset", detail: key + "; capability and risk defaults now apply."))
        }
    }
    func setLearningMode(_ mode: LearningMode) async { await change { $0.learningMode = mode } }
    func setRouting(_ preference: RoutingPreference) async {
        guard !isWorking else { return }
        await change { $0.routingPreference = preference }
    }
    func renameDirector(_ name: String) async {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !trimmed.isEmpty else { return }
        await change { state in
            state.directorName = trimmed
            if let index = state.agents.firstIndex(where: { $0.id == "god" }) { state.agents[index].name = trimmed }
        }
    }
    func saveAuditPrompt(_ prompt: String) async { await change { $0.auditPrompt = String(prompt.prefix(16_000)) } }
    func runAudit() async {
        let camera: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = "allowed"; case .denied, .restricted: camera = "denied"; default: camera = "not requested"
        }
        let configured = state.providers.filter { $0.enabled }.map { "\($0.name): \(URL(string: $0.endpoint)?.host ?? "on-device")" }.joined(separator: "\n")
        let report = """
        Deterministic local inspection
        • Credentials use the iOS Keychain with device-only accessibility; raw values are excluded from session state and model context.
        • Sessions, context files, skills and audit entries use local SQLite in the protected app sandbox.
        • Current routing: \(state.routingPreference.rawValue).
        • Camera: \(camera). No Home, Messages, Contacts, or Calendar connector is implemented in this build.
        • Enabled providers: \(configured.isEmpty ? "none" : configured).
        • Paired computers: \(state.devices.count). Each connection pins the paired TLS certificate.
        • Recorded authorized requests/pairings with destinations: \(state.activity.filter { $0.destination != nil }.count).
        • Learning: \(state.learningMode.rawValue); \(state.proposals.count) pending proposals.
        This inspection does not capture network packets or establish a provider's retention practices. Review individual Activity entries for selected context sent to models. No telemetry SDK is installed.
        """
        await change { $0.activity.append(ActivityEntry(title: "Privacy audit · local inspection", detail: report)) }
        // Optional interpretation uses the normal runtime and its explicit model/network permissions.
        if canSend { await send(state.auditPrompt + "\n\nClient observations (not a security certification):\n" + report) }
    }
}
