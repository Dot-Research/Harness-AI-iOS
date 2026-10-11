#if os(iOS)
import AVFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Speech
import DictationCore

/// A streaming speech-to-text engine. `append` is called on the audio thread.
public protocol SpeechStreamTranscriber: AnyObject, Sendable {
    /// Live text for display: (best text so far, isFinal). Called on an arbitrary thread.
    var onPartial: ((String) -> Void)? { get set }
    func prepare() async throws
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws -> String
    func cancel() async
}

public enum TranscriberError: LocalizedError {
    case unsupportedLanguage(String)
    case modelUnavailable
    case noAudioFormat
    case notPrepared
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case let .unsupportedLanguage(code): return "On-device transcription doesn't support \(code) on this iPhone."
        case .modelUnavailable: return "The on-device speech model couldn't be downloaded."
        case .noAudioFormat: return "The speech model can't read microphone audio."
        case .notPrepared: return "Transcription wasn't ready."
        case .emptyAudio: return "No speech was captured."
        }
    }
}

// MARK: - On device (SpeechAnalyzer)

/// Apple's on-device speech models through SpeechAnalyzer. Uses SpeechTranscriber where the device
/// supports it and DictationTranscriber (the system dictation model) otherwise.
public final class OnDeviceTranscriber: SpeechStreamTranscriber, @unchecked Sendable {
    public struct Support: Sendable {
        public var supported: Bool
        public var installed: Bool
        public var locale: Locale?
    }

    public var onPartial: ((String) -> Void)?

    private let requestedLocale: Locale
    private let contextualStrings: [String]
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: PCMConverter?
    private var resultsTask: Task<Void, Error>?
    private var accumulator = TranscriptAccumulator()
    /// Audio that arrives while the model is still loading. Bounded to about 30 seconds.
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFrameCount = 0
    private var cancelled = false

    public init(locale: Locale, contextualStrings: [String]) {
        requestedLocale = locale
        self.contextualStrings = contextualStrings
    }

    /// Whether this language works on device, and whether its model is already installed.
    public static func support(for locale: Locale) async -> Support {
        if SpeechTranscriber.isAvailable, let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }
            return Support(supported: true, installed: installed, locale: resolved)
        }
        if let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let installed = await DictationTranscriber.installedLocales.contains { $0.identifier(.bcp47) == resolved.identifier(.bcp47) }
            return Support(supported: true, installed: installed, locale: resolved)
        }
        return Support(supported: false, installed: false, locale: nil)
    }

    public func prepare() async throws {
        let modules: [any SpeechModule]
        let resultsTask: Task<Void, Error>

        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            modules = [transcriber]
            try await Self.ensureInstalled(modules)
            resultsTask = Task { [weak self] in
                for try await result in transcriber.results {
                    self?.receive(String(result.text.characters), isFinal: result.isFinal)
                }
            }
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) {
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            modules = [transcriber]
            try await Self.ensureInstalled(modules)
            resultsTask = Task { [weak self] in
                for try await result in transcriber.results {
                    self?.receive(String(result.text.characters), isFinal: result.isFinal)
                }
            }
        } else {
            throw TranscriberError.unsupportedLanguage(requestedLocale.identifier(.bcp47))
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            resultsTask.cancel()
            throw TranscriberError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)

        let backlog: [AVAudioPCMBuffer]? = lock.withLock {
            // Cancelled while the model was loading: don't leave an analyzer running.
            if cancelled { return nil }
            self.analyzer = analyzer
            self.resultsTask = resultsTask
            self.converter = PCMConverter(outputFormat: format)
            self.continuation = continuation
            let backlog = pending
            pending.removeAll()
            pendingFrames = 0
            return backlog
        }
        guard let backlog else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            resultsTask.cancel()
            return
        }
        for buffer in backlog { feed(buffer) }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if cancelled { lock.unlock(); return }
        if continuation == nil {
            // Still preparing: keep a copy (the tap reuses its buffer).
            if pendingFrames < AVAudioFrameCount(buffer.format.sampleRate * 30), let copy = buffer.copy() as? AVAudioPCMBuffer {
                pending.append(copy)
                pendingFrames += buffer.frameLength
            }
            lock.unlock()
            return
        }
        lock.unlock()
        feed(buffer)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let converter = self.converter
        let continuation = self.continuation
        lock.unlock()
        guard let converter, let continuation else { return }
        guard let converted = try? converter.convert(buffer), converted.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    private func receive(_ text: String, isFinal: Bool) {
        lock.lock()
        accumulator.apply(text, isFinal: isFinal)
        let current = accumulator.current
        lock.unlock()
        onPartial?(current)
    }

    public func finish() async throws -> String {
        let (continuation, analyzer, resultsTask) = lock.withLock { (self.continuation, self.analyzer, self.resultsTask) }
        guard let continuation, let analyzer else { throw TranscriberError.notPrepared }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        return lock.withLock { accumulator.current }
    }

    public func cancel() async {
        let (continuation, analyzer, resultsTask) = lock.withLock { () -> (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, Task<Void, Error>?) in
            cancelled = true
            pending.removeAll()
            return (self.continuation, self.analyzer, self.resultsTask)
        }
        continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
    }

    private static func ensureInstalled(_ modules: [any SpeechModule]) async throws {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriberError.modelUnavailable
        }
    }
}

// MARK: - Paired computer and cloud (OpenAI-compatible endpoints)

/// Records the utterance in memory at 16 kHz mono, then uploads it once to an OpenAI-compatible
/// transcription endpoint: the user's paired computer or their own cloud provider. The audio buffer
/// is released as soon as the request is sent; nothing touches disk.
public final class RemoteTranscriber: SpeechStreamTranscriber, @unchecked Sendable {
    public var onPartial: ((String) -> Void)?

    private let endpoint: TranscriptionEndpoint
    private let bearerToken: String?
    private let languageCode: String?
    private let vocabularyPrompt: String?
    private let maxSeconds: Int
    private let lock = NSLock()
    private var samples: [Float] = []
    private var cancelled = false
    private var activeSession: URLSession?
    private let converter: PCMConverter

    private static let sampleRate = 16_000.0

    public init(endpoint: TranscriptionEndpoint, bearerToken: String?, languageCode: String?, vocabularyPrompt: String?, maxSeconds: Int) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.languageCode = languageCode
        self.vocabularyPrompt = vocabularyPrompt
        self.maxSeconds = maxSeconds
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
        converter = PCMConverter(outputFormat: format)
        samples.reserveCapacity(Int(Self.sampleRate) * 60)
    }

    public func prepare() async throws {}

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? converter.convert(buffer), let channel = converted.firstChannelSamples else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        let limit = Int(Self.sampleRate) * maxSeconds
        let room = max(0, limit - samples.count)
        samples.append(contentsOf: channel.prefix(room))
    }

    public func finish() async throws -> String {
        let audio: [Float] = lock.withLock {
            let audio = samples
            samples = []
            return audio
        }
        guard audio.count > Int(Self.sampleRate * 0.2) else { throw TranscriberError.emptyAudio }
        let wav = WAVEncoder.encode(samples: audio, sampleRate: Int(Self.sampleRate))
        let request = try TranscriptionAPI.makeRequest(
            endpoint: endpoint,
            wav: wav,
            languageCode: languageCode,
            vocabularyPrompt: vocabularyPrompt,
            bearerToken: bearerToken
        )
        // Ephemeral: no cache, no cookies, no credential storage for audio uploads.
        let session = URLSession(configuration: .ephemeral)
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            activeSession = session
            return false
        }
        if alreadyCancelled {
            session.invalidateAndCancel()
            throw CancellationError()
        }
        defer {
            lock.withLock { activeSession = nil }
            session.finishTasksAndInvalidate()
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try TranscriptionAPI.parse(data: data, statusCode: status)
    }

    public func cancel() async {
        let session: URLSession? = lock.withLock {
            cancelled = true
            samples = []
            return activeSession
        }
        session?.invalidateAndCancel()
    }
}

// MARK: - Dependencies the rest of Harness provides

/// Secrets by ID (Settings > Providers). The default implementation reads the Keychain.
public protocol CredentialProvider: AnyObject, Sendable {
    func secret(for id: String) -> String?
}

/// The paired-computer feature exposes a transcription endpoint over its encrypted channel.
public protocol PairedComputerTranscription: AnyObject, Sendable {
    var isPaired: Bool { get }
    func isReachable() async -> Bool
    /// The endpoint and a short-lived token for this request.
    func transcriptionEndpoint() async -> (endpoint: TranscriptionEndpoint, bearerToken: String?)?
}

/// Rewrites text with a language model.
public protocol TextRewriter: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func rewrite(_ text: String, instructions: String) async throws -> String
}
#endif
