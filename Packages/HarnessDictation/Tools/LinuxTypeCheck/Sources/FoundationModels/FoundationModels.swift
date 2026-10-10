@_exported import Foundation


public final class SystemLanguageModel: @unchecked Sendable {
    public static let `default` = SystemLanguageModel()
    public var isAvailable: Bool { fatalError() }
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
    public func respond(options: GenerationOptions = GenerationOptions(), @PromptBuilder prompt: () throws -> Prompt) async throws -> Response<String> { fatalError() }
}

