#if os(iOS)
import Foundation
import DictationCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Apple cloud API exists on OS 27; a compiled adapter is not an entitlement grant.
public final class PrivateCloudRewriter: TextRewriter, Sendable {
    public init() {}

    public var isAvailable: Bool {
        guard isConfigured else { return false }
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            return model.isAvailable && !model.quotaUsage.isLimitReached
        }
        #endif
        return false
    }

    public var availabilityDescription: String {
        guard isConfigured else { return "Apple Private Cloud is not enabled in this build. Harness needs Apple's developer approval and the Private Cloud Compute entitlement before this route can run." }
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            guard model.isAvailable else { return "Apple Private Cloud isn't available for this app or device. Developer approval, the PCC entitlement and Apple Intelligence are required." }
            if model.quotaUsage.isLimitReached { return "Your Apple Private Cloud daily limit has been reached. Choose on-device rewriting or wait for the limit to reset." }
            return "Available through Apple Private Cloud Compute. Your transcript and instructions are sent to Apple for this request; audio stays on the transcription route you selected."
        }
        #endif
        return "Apple Private Cloud rewriting requires iOS 27 and a build with the new Foundation Models SDK. On-device rewriting remains available on supported iOS 26 devices."
    }

    public func rewrite(_ text: String, instructions: String) async throws -> String {
        try Task.checkCancellation()
        guard isConfigured else { throw BridgeError(.rewriteUnavailable, availabilityDescription) }
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let model = PrivateCloudComputeLanguageModel()
            guard model.isAvailable, !model.quotaUsage.isLimitReached else {
                throw BridgeError(.rewriteUnavailable, availabilityDescription)
            }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: RewritePromptBuilder.prompt(for: text), options: GenerationOptions(temperature: 0.2))
            try Task.checkCancellation()
            return try RewriteOutputSanitizer.clean(response.content, original: text)
        }
        #endif
        throw BridgeError(.rewriteUnavailable, availabilityDescription)
    }
    private var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "HarnessPrivateCloudEnabled") as? Bool == true }
}

/// App-side routing reads the shared preference for each request, avoiding stale provider state.
public final class ConfiguredAppleRewriter: TextRewriter, Sendable {
    private let group: AppGroupConfiguration
    private let permitsPrivateCloud: Bool
    private let local = OnDeviceRewriter()
    private let cloud = PrivateCloudRewriter()

    public init(group: AppGroupConfiguration = AppGroupConfiguration(), permitsPrivateCloud: Bool = true) {
        self.group = group; self.permitsPrivateCloud = permitsPrivateCloud
    }
    private var candidates: [AppleRewriteBackend] {
        let settings = DictationSettings.decode(group.defaults?.data(forKey: BridgeNames.settingsKey))
        return AppleRewriteRouting.candidates(for: settings.effectiveAppleRewriteRoute,
            localAvailable: local.isAvailable, cloudAvailable: cloud.isAvailable, networkAllowed: permitsPrivateCloud)
    }
    public var isAvailable: Bool { !candidates.isEmpty }

    public func rewrite(_ text: String, instructions: String) async throws -> String {
        try Task.checkCancellation()
        let selected = candidates
        guard !selected.isEmpty else {
            throw BridgeError(.rewriteUnavailable, "The selected rewrite model is unavailable. Choose on-device or check Apple Private Cloud access in Speak settings.")
        }
        var lastError: (any Error)?
        for backend in selected {
            try Task.checkCancellation()
            do {
                let provider: any TextRewriter = backend == .onDevice ? local : cloud
                let output = try await provider.rewrite(text, instructions: instructions)
                try Task.checkCancellation()
                return output
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError ?? BridgeError(.rewriteUnavailable, "Rewriting could not complete. Your original text is unchanged.")
    }
}
#endif
