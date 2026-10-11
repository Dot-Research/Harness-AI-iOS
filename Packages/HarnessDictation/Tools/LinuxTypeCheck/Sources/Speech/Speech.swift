// Shaped after the iOS 26 Speech framework docs (SpeechAnalyzer, SpeechTranscriber,
// DictationTranscriber, AssetInventory, AnalysisContext). Type-check only.
@_exported import AVFoundation

public protocol SpeechModule: AnyObject, Sendable {}
public protocol LocaleDependentSpeechModule: SpeechModule {}

public struct AnalyzerInput: Sendable {
    public init(buffer: AVAudioPCMBuffer) { fatalError() }
}

public final class SpeechTranscriber: LocaleDependentSpeechModule, @unchecked Sendable {
    public struct Preset: Hashable, Sendable {
        public static let transcription = Preset()
        public static let progressiveTranscription = Preset()
    }
    public struct Result: Sendable {
        public var text: AttributedString
        public var isFinal: Bool
    }
    public convenience init(locale: Locale, preset: Preset) { fatalError() }
    private init() {}
    public static var isAvailable: Bool { fatalError() }
    public static var installedLocales: [Locale] { get async { fatalError() } }
    public static var supportedLocales: [Locale] { get async { fatalError() } }
    public static func supportedLocale(equivalentTo locale: Locale) async -> Locale? { fatalError() }
    public var results: AsyncThrowingStream<Result, Error> { fatalError() }
}

public final class DictationTranscriber: LocaleDependentSpeechModule, @unchecked Sendable {
    public struct Preset: Hashable, Sendable {
        public static let shortDictation = Preset()
        public static let progressiveLongDictation = Preset()
    }
    public struct Result: Sendable {
        public var text: AttributedString
        public var isFinal: Bool
    }
    public convenience init(locale: Locale, preset: Preset) { fatalError() }
    private init() {}
    public static var installedLocales: [Locale] { get async { fatalError() } }
    public static var supportedLocales: [Locale] { get async { fatalError() } }
    public static func supportedLocale(equivalentTo locale: Locale) async -> Locale? { fatalError() }
    public var results: AsyncThrowingStream<Result, Error> { fatalError() }
}

public final class AnalysisContext: @unchecked Sendable {
    public struct ContextualStringsTag: Hashable, Sendable {
        public static let general = ContextualStringsTag()
    }
    public init() {}
    public var contextualStrings: [ContextualStringsTag: [String]] = [:]
}

public final actor SpeechAnalyzer {
    public struct Options: Sendable {}
    public init(modules: [any SpeechModule], options: Options? = nil) { fatalError() }
    public static func bestAvailableAudioFormat(compatibleWith modules: [any SpeechModule]) async -> AVAudioFormat? { fatalError() }
    public func setContext(_ context: AnalysisContext) async throws { fatalError() }
    public func start<InputSequence: AsyncSequence & Sendable>(inputSequence: InputSequence) async throws where InputSequence.Element == AnalyzerInput { fatalError() }
    public func finalizeAndFinishThroughEndOfInput() async throws { fatalError() }
    public func cancelAndFinishNow() async { fatalError() }
}

public final class AssetInstallationRequest: @unchecked Sendable {
    public func downloadAndInstall() async throws { fatalError() }
}

public enum AssetInventory {
    public static func assetInstallationRequest(supporting modules: [any SpeechModule]) async throws -> AssetInstallationRequest? { fatalError() }
}
