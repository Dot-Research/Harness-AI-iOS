import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
}

public struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var name: String; public var arguments: [String: JSONValue]
    public init(id: String = UUID().uuidString, name: String, arguments: [String: JSONValue] = [:]) {
        self.id = id; self.name = name; self.arguments = arguments
    }
}
public struct AgentMessage: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var id: UUID; public var role: Role; public var content: String; public var date: Date
    public var toolCalls: [ToolCall]; public var toolCallID: String?
    public init(id: UUID = UUID(), role: Role, content: String, date: Date = Date(), toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.id = id; self.role = role; self.content = content; self.date = date; self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }
}
public struct AgentSession: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID; public var title: String; public var messages: [AgentMessage]; public var updatedAt: Date
    public var summary: String; public var agentID: String
    public init(id: UUID = UUID(), title: String = "New conversation", messages: [AgentMessage] = [], updatedAt: Date = Date(), summary: String = "", agentID: String = "god") {
        self.id = id; self.title = title; self.messages = messages; self.updatedAt = updatedAt; self.summary = summary; self.agentID = agentID
    }
}
public enum Capability: String, Codable, CaseIterable, Sendable {
    case localRead = "local.read", localWrite = "local.write", networkRequest = "network.request"
    case computerRead = "computer.readFile", computerWrite = "computer.writeFile", computerExecute = "computer.execute"
    case homeRead = "home.read", homeLights = "home.changeLights", homeUnlock = "home.unlockDoor", messagesSend = "messages.send"
}
public enum ToolRisk: String, Codable, Sendable { case low, elevated, sensitive }
public struct ToolDefinition: Codable, Equatable, Sendable, Identifiable {
    public var name: String; public var description: String; public var capability: Capability; public var risk: ToolRisk
    public var parameters: [String: JSONValue]; public var id: String { name }
    public init(name: String, description: String, capability: Capability, risk: ToolRisk = .low, parameters: [String: JSONValue] = [:]) {
        self.name = name; self.description = description; self.capability = capability; self.risk = risk; self.parameters = parameters
    }
}
public enum PermissionDecision: String, Codable, Sendable { case allow, ask, biometric, deny }
public enum PermissionAnswer: Sendable { case allowOnce, alwaysAllow, denyOnce, alwaysDeny }
public struct PermissionRequest: Sendable, Identifiable {
    public var id = UUID(); public var agentName: String; public var tool: ToolDefinition; public var detail: String
    public init(agentName: String, tool: ToolDefinition, detail: String) { self.agentName = agentName; self.tool = tool; self.detail = detail }
}
public typealias PermissionHandler = @Sendable (PermissionRequest, PermissionDecision) async -> PermissionAnswer
public struct AgentProfile: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var name: String; public var purpose: String; public var instructions: String
    public var capabilities: Set<Capability>; public var allowedSkills: [String]; public var external: Bool
    public init(id: String, name: String, purpose: String, instructions: String = "", capabilities: Set<Capability> = [.localRead], allowedSkills: [String] = [], external: Bool = false) {
        self.id = id; self.name = name; self.purpose = purpose; self.instructions = instructions; self.capabilities = capabilities; self.allowedSkills = allowedSkills; self.external = external
    }
}
public struct Skill: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var name: String; public var description: String; public var markdown: String; public var keywords: [String]
    public var requiredCapabilities: Set<Capability>; public var enabled: Bool; public var version: Int
    public var usageCount: Int; public var successCount: Int; public var lastUsed: Date?; public var rating: Int?
    public init(id: String = UUID().uuidString, name: String, description: String, markdown: String, keywords: [String] = [], requiredCapabilities: Set<Capability> = [.localRead], enabled: Bool = true, version: Int = 1, usageCount: Int = 0, successCount: Int = 0, lastUsed: Date? = nil, rating: Int? = nil) {
        self.id = id; self.name = name; self.description = description; self.markdown = markdown; self.keywords = keywords; self.requiredCapabilities = requiredCapabilities; self.enabled = enabled; self.version = version; self.usageCount = usageCount; self.successCount = successCount; self.lastUsed = lastUsed; self.rating = rating
    }
}
public enum AgentFile: String, Codable, CaseIterable, Sendable { case soul = "SOUL.md", user = "USER.md", memory = "MEMORY.md", agents = "AGENTS.md" }
public enum LearningMode: String, Codable, CaseIterable, Sendable { case off = "Off", ask = "Ask Me", automatic = "Automatic" }
public struct LearningProposal: Codable, Equatable, Sendable, Identifiable {
    public enum Target: String, Codable, Sendable { case user, memory, newSkill, skillPatch }
    public var id: UUID; public var target: Target; public var title: String; public var evidence: String; public var before: String; public var after: String
    public var skillID: String?; public var date: Date
    public init(id: UUID = UUID(), target: Target, title: String, evidence: String, before: String, after: String, skillID: String? = nil, date: Date = Date()) {
        self.id = id; self.target = target; self.title = title; self.evidence = evidence; self.before = before; self.after = after; self.skillID = skillID; self.date = date
    }
}
public struct JourneyEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID; public var title: String; public var date: Date; public var proposal: LearningProposal; public var reverted: Bool
    public init(id: UUID = UUID(), title: String, date: Date = Date(), proposal: LearningProposal, reverted: Bool = false) { self.id = id; self.title = title; self.date = date; self.proposal = proposal; self.reverted = reverted }
}
public struct ActivityEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID; public var date: Date; public var title: String; public var detail: String; public var destination: String?
    public init(id: UUID = UUID(), date: Date = Date(), title: String, detail: String = "", destination: String? = nil) { self.id = id; self.date = date; self.title = title; self.detail = detail; self.destination = destination }
}
public struct ProviderConfiguration: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case apple, openRouter, openAICompatible }
    public var id: String; public var name: String; public var kind: Kind; public var endpoint: String; public var model: String; public var enabled: Bool
    public init(id: String, name: String, kind: Kind, endpoint: String = "", model: String = "", enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.endpoint = endpoint; self.model = model; self.enabled = enabled
    }
}
public enum RoutingPreference: String, Codable, CaseIterable, Sendable { case localOnly = "On device only", balanced = "Balanced", cloud = "Cloud preferred" }
public struct PairedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String; public var name: String; public var url: String; public var fingerprint: String; public var capabilities: Set<Capability>
    public var availableCapabilities: Set<Capability>
    public var credentialID: String?
    public init(id: String, name: String, url: String, fingerprint: String, capabilities: Set<Capability>, availableCapabilities: Set<Capability>? = nil, credentialID: String? = nil) {
        self.id = id; self.name = name; self.url = url; self.fingerprint = fingerprint
        self.capabilities = capabilities; self.availableCapabilities = availableCapabilities ?? capabilities; self.credentialID = credentialID
    }
}
public struct HarnessState: Codable, Equatable, Sendable {
    public var sessions: [AgentSession] = []; public var files: [String: String] = [:]; public var skills: [Skill] = []
    public var agents: [AgentProfile] = []; public var proposals: [LearningProposal] = []; public var journey: [JourneyEntry] = []
    public var activity: [ActivityEntry] = []; public var providers: [ProviderConfiguration] = []; public var devices: [PairedDevice] = []
    /// Optional for backward-compatible decoding of existing local settings.
    public var remoteAgents: [RemoteAgentConnection]?
    public var remoteAgentConnections: [RemoteAgentConnection] { remoteAgents ?? [] }
    public var permissionRules: [String: PermissionDecision] = [:]; public var learningMode: LearningMode = .ask
    public var routingPreference: RoutingPreference = .localOnly; public var directorName = "General Orchestrator Director"; public var auditPrompt = "Act as a security and CTF researcher. Inspect Harness for vulnerabilities and determine whether my data is transmitted, retained, logged or exposed. Show evidence for every finding and distinguish verified findings from assumptions."
    public init() {}
}
public protocol HarnessStore: Sendable {
    func load() async throws -> HarnessState
    func update(_ change: @Sendable (inout HarnessState) -> Void) async throws
}
public struct ModelRequest: Sendable {
    public var messages: [AgentMessage]; public var tools: [ToolDefinition]; public var model: String
    public init(messages: [AgentMessage], tools: [ToolDefinition] = [], model: String = "") { self.messages = messages; self.tools = tools; self.model = model }
}
public struct ModelResponse: Sendable {
    public var content: String; public var toolCalls: [ToolCall]; public var inputTokens: Int?; public var outputTokens: Int?
    public init(content: String, toolCalls: [ToolCall] = [], inputTokens: Int? = nil, outputTokens: Int? = nil) { self.content = content; self.toolCalls = toolCalls; self.inputTokens = inputTokens; self.outputTokens = outputTokens }
}
public protocol ModelProvider: Sendable {
    var id: String { get }
    var isLocal: Bool { get }
    var supportsToolCalling: Bool { get }
    func complete(_ request: ModelRequest) async throws -> ModelResponse
}
public extension ModelProvider { var supportsToolCalling: Bool { true } }
public protocol ExternalToolExecutor: Sendable {
    func execute(_ call: ToolCall, device: PairedDevice) async throws -> String
}
