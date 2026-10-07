import Foundation
import HarnessCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Apple adapter provides real on-device text generation. Dynamic Harness
/// tools are offered by the OpenAI-compatible adapter, not silently simulated.
struct AppleModelProvider: ModelProvider {
    let id = "apple"
    let isLocal = true
    let supportsToolCalling = false

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static var availabilityDescription: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Available on this iPhone"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "Apple Intelligence is not supported on this device."
                case .appleIntelligenceNotEnabled: return "Enable Apple Intelligence in iPhone Settings."
                case .modelNotReady: return "The on-device model is still downloading or preparing."
                @unknown default: return "The on-device model is unavailable."
                }
            @unknown default: return "The on-device model is unavailable."
            }
        }
        #endif
        return "Requires iOS 26 and Apple Intelligence."
    }

    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        try Task.checkCancellation()
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { throw AppleProviderFailure.unavailable }
            let instructions = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n") + "\n\nYou are an on-device text assistant. You have no tools in this session. Never claim to have read or changed files, controlled a computer or home, sent a message, or completed another action. When an action is requested, explain that a tool-capable provider must be selected."
            let conversation = request.messages.filter { $0.role != .system }.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n\n")
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: conversation)
                try Task.checkCancellation()
                return ModelResponse(content: response.content, toolCalls: [])
            } catch is CancellationError { throw CancellationError() }
            catch let failure as LanguageModelSession.GenerationError {
                // Keep model diagnostics and any private prompt content out of logs.
                // These cases are available in the iOS 26 SDK we target.
                try Task.checkCancellation()
                switch failure {
                case .exceededContextWindowSize: throw AppleProviderFailure.contextTooLong
                case .assetsUnavailable: throw AppleProviderFailure.modelNotReady
                case .unsupportedLanguageOrLocale: throw AppleProviderFailure.unsupportedLanguage
                case .guardrailViolation, .refusal: throw AppleProviderFailure.requestDeclined
                case .rateLimited, .concurrentRequests: throw AppleProviderFailure.busy
                default: throw AppleProviderFailure.generationFailed
                }
            } catch {
                try Task.checkCancellation()
                throw AppleProviderFailure.generationFailed
            }
        }
        #endif
        throw AppleProviderFailure.unavailable
    }
}

enum AppleProviderFailure: Error, LocalizedError {
    case unavailable, modelNotReady, contextTooLong, unsupportedLanguage, requestDeclined, busy, generationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: return AppleModelProvider.availabilityDescription
        case .modelNotReady: return "Apple's on-device model is not ready. Check Apple Intelligence in iPhone Settings, then try again after its download finishes."
        case .contextTooLong: return "This conversation exceeds Apple's on-device context limit. Start a new chat or shorten your request. Earlier messages stay saved, and nothing was sent to a cloud provider."
        case .unsupportedLanguage: return "Apple's on-device model does not support the requested language or locale. Try a supported language, or choose another provider in Me → Providers."
        case .requestDeclined: return "Apple's on-device model declined this request. Try rephrasing it. Nothing was sent to a cloud provider."
        case .busy: return "Apple's on-device model is busy. Wait a moment, then try again."
        case .generationFailed: return "The on-device model could not answer this request. Try a shorter conversation or another provider."
        }
    }
}
