#if os(iOS)
import Foundation
import Network
import DictationCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - On-device rewriting (Apple Foundation Models)

/// Fix and Rewrite with the on-device Apple Intelligence model. Nothing leaves the device.
public final class OnDeviceRewriter: TextRewriter, Sendable {
    public init() {}

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    public func rewrite(_ text: String, instructions: String) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession {
            instructions
        }
        let prompt = RewritePromptBuilder.prompt(for: text)
        let response = try await session.respond(options: GenerationOptions(temperature: 0.2)) {
            prompt
        }
        return try RewriteOutputSanitizer.clean(response.content, original: text)
        #else
        throw BridgeError(.rewriteUnavailable, "On-device rewriting needs Apple Intelligence.")
        #endif
    }
}

// MARK: - Network

public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    public var isOnline: Bool { lock.withLock { online } }

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            self.lock.withLock { self.online = satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "org.harness.ios.dictation.network"))
    }

    deinit {
        monitor.cancel()
    }
}

// MARK: - History storage (app container only)

public final class HistoryStore {
    private let url: URL?

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let dir = base?.appendingPathComponent("Dictation", isDirectory: true) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("history.json")
        } else {
            url = nil
        }
    }

    public func load() -> TranscriptHistory {
        guard let url, let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(TranscriptHistory.self, from: data) else { return TranscriptHistory() }
        return history
    }

    public func save(_ history: TranscriptHistory) {
        guard let url, let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    public func erase() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
