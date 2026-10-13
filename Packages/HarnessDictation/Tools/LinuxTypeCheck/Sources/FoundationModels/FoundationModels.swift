@_exported import Foundation


public protocol LanguageModel: Sendable {}

public final class SystemLanguageModel: LanguageModel, @unchecked Sendable {
    public static let `default` = SystemLanguageModel()
    public var isAvailable: Bool { fatalError() }
}

/// Shapes used by the iOS 27 provider. Availability/quota are evaluated by production
/// code, while these interfaces ensure the cloud path is type-checked on newer compilers.
@available(iOS 27.0, *)
public final class PrivateCloudComputeLanguageModel: LanguageModel, Sendable {
    public init() {}
    public var isAvailable: Bool { fatalError() }
    public var quotaUsage: QuotaUsage { fatalError() }

    public struct QuotaUsage: Sendable {
        public var isLimitReached: Bool { fatalError() }
    }
}

public struct Instructions {}
public struct Prompt {}

@resultBuilder
public struct InstructionsBuilder {
    public static func buildBlock(_ component: String) -> Instructions { Instructions() }
}

@resultBuilder
public struct PromptBuilder {
    public static func buildBlock(_ component: String) -> Prompt { Prompt() }
}

public struct GenerationOptions: Sendable {
    public init(sampling: Int? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {}
}

public final class LanguageModelSession: @unchecked Sendable {
    public struct Response<Content> {
        public let content: Content
    }
    public init(model: SystemLanguageModel = .default, tools: [Any] = [], @InstructionsBuilder instructions: () throws -> Instructions) rethrows {}
    public init<Model: LanguageModel>(model: Model, instructions: String?) {}
    public func respond(options: GenerationOptions = GenerationOptions(), @PromptBuilder prompt: () throws -> Prompt) async throws -> Response<String> { fatalError() }
    public func respond(to prompt: String, options: GenerationOptions = GenerationOptions()) async throws -> Response<String> { fatalError() }
}

