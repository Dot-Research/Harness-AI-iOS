import Foundation

/// The host supplies approval UI; model responses never update these rules directly.
public actor PermissionKernel {
    private let store: any HarnessStore
    public init(store: any HarnessStore) { self.store = store }

    public static func ruleKey(agentID: String, capability: Capability) -> String {
        "\(agentID):\(capability.rawValue)"
    }

    public static func decision(for tool: ToolDefinition, agent: AgentProfile, rules: [String: PermissionDecision]) -> PermissionDecision {
        guard agent.capabilities.contains(tool.capability) else { return .deny }
        let saved = rules[ruleKey(agentID: agent.id, capability: tool.capability)]
        if saved == .deny { return .deny }
        // A broad saved Allow never weakens authentication for a sensitive action.
        if tool.risk == .sensitive || tool.capability == .homeUnlock { return .biometric }
        if let saved { return saved }
        if agent.external { return .ask }
        if tool.capability == .localRead && tool.risk == .low { return .allow }
        return .ask
    }

    @discardableResult
    public func authorize(tool: ToolDefinition, agent: AgentProfile, detail: String, handler: @escaping PermissionHandler) async throws -> Bool {
        try Task.checkCancellation()
        let state = try await store.load()
        guard let currentAgent = state.agents.first(where: { $0.id == agent.id }) else { return false }
        let decision = Self.decision(for: tool, agent: currentAgent, rules: state.permissionRules)
        if decision == .deny {
            try await audit(agent: agent, tool: tool, detail: "Denied by permission profile or saved rule.")
            return false
        }
        if decision == .allow { return true }
        let answer = await handler(PermissionRequest(agentName: agent.name, tool: tool, detail: detail), decision)
        try Task.checkCancellation()
        let currentState = try await store.load()
        guard let latestAgent = currentState.agents.first(where: { $0.id == agent.id }), Self.decision(for: tool, agent: latestAgent, rules: currentState.permissionRules) != .deny else { return false }
        let allowed: Bool
        switch answer {
        case .allowOnce: allowed = true
        case .alwaysAllow:
            allowed = true
            // Biometric approval applies once. Every future sensitive action authenticates again.
            if decision != .biometric {
                let key = Self.ruleKey(agentID: agent.id, capability: tool.capability)
                try await store.update { $0.permissionRules[key] = .allow }
            }
        case .denyOnce: allowed = false
        case .alwaysDeny:
            allowed = false
            let key = Self.ruleKey(agentID: agent.id, capability: tool.capability)
            try await store.update { $0.permissionRules[key] = .deny }
        }
        try await audit(agent: agent, tool: tool, detail: "\(allowed ? "Approved" : "Denied") by user: \(detail)")
        return allowed
    }

    private func audit(agent: AgentProfile, tool: ToolDefinition, detail: String) async throws {
        let entry = ActivityEntry(title: "\(agent.name): \(tool.name)", detail: detail)
        try await store.update { $0.activity.append(entry) }
    }
}
