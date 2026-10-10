import Foundation

// The keyboard extension cannot record audio, so the main app records and transcribes while the
// keyboard shows status and inserts the result. They talk through two small JSON files in the App
// Group container plus Darwin notifications as a doorbell:
//
//   commands.json  written only by the keyboard: an ordered queue of BridgeCommand
//   status.json    written only by the app: one HostStatus snapshot
//
// One writer per file means no write races. Every command carries an increasing sequence number;
// the app records the last one it processed in the status, and the keyboard prunes everything up to
// it. Transcript text sits in status.json only until the keyboard acknowledges it (or 60 seconds).

public struct DictationRequest: Codable, Hashable, Identifiable, Sendable {
    public enum Origin: String, Codable, Hashable, Sendable {
        /// Started from the Harness Keyboard; the keyboard inserts the result.
        case keyboard
        /// Started inside the Harness app (Try it, GOD composer); the app uses the result.
        case app
    }

    public var id: UUID
    public var modeID: String
    public var languageCode: String?
    public var field: FieldTraits?
    public var createdAt: Date
    /// nil is treated as `.keyboard`.
    public var origin: Origin?

    public init(id: UUID = UUID(), modeID: String, languageCode: String? = nil, field: FieldTraits? = nil, createdAt: Date = Date(), origin: Origin = .keyboard) {
        self.id = id
        self.modeID = modeID
        self.languageCode = languageCode
        self.field = field
        self.createdAt = createdAt
        self.origin = origin
    }
}

public enum RewriteAction: Codable, Hashable, Sendable {
    /// Fix grammar, punctuation and dictation mistakes. Keep the wording.
    case fix
    /// Rewrite for clarity in the style of a mode.
    case rewrite(modeID: String)
    /// Apply the user's own instruction ("make it friendlier", "translate to Spanish").
    case instruct(String)
}

public struct RewriteJob: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var action: RewriteAction
    public var text: String

    public init(id: UUID = UUID(), action: RewriteAction, text: String) {
        self.id = id
        self.action = action
        self.text = text
    }
}

/// Text the user sends from the keyboard to GOD. The app opens the GOD conversation with it.
public struct GODHandoff: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

public enum BridgeCommandKind: Codable, Hashable, Sendable {
    case start(DictationRequest)
    case stop(requestID: UUID)
    case cancel(requestID: UUID)
    /// The keyboard inserted the result; the app should clear it from shared storage.
    case acknowledge(requestID: UUID)
    case rewrite(RewriteJob)
    case acknowledgeRewrite(jobID: UUID)
    case askGOD(GODHandoff)
    /// The keyboard is visible; keep the warm session alive a little longer.
    case keepWarm
    /// The user turned the microphone session off from the keyboard.
    case endSession
}

public struct BridgeCommand: Codable, Hashable, Identifiable, Sendable {
    public var seq: Int
    public var id: UUID
    public var issuedAt: Date
    public var kind: BridgeCommandKind
}

/// The keyboard's outbox.
public struct CommandQueue: Codable, Hashable, Sendable {
    public private(set) var commands: [BridgeCommand]
    public private(set) var nextSeq: Int

    public init() {
        commands = []
        nextSeq = 1
    }

    @discardableResult
    public mutating func append(_ kind: BridgeCommandKind, now: Date = Date()) -> BridgeCommand {
        let command = BridgeCommand(seq: nextSeq, id: UUID(), issuedAt: now, kind: kind)
        nextSeq += 1
        commands.append(command)
        // A queue that is never drained (app not running) must not grow forever.
        if commands.count > 64 { commands.removeFirst(commands.count - 64) }
        return command
    }

    /// Drop commands the app has processed and commands too old to matter.
    public mutating func prune(processedThrough seq: Int, now: Date = Date(), maxAge: TimeInterval = 120) {
        commands.removeAll { $0.seq <= seq || now.timeIntervalSince($0.issuedAt) > maxAge }
    }

    public func pending(after seq: Int) -> [BridgeCommand] {
        commands.filter { $0.seq > seq }.sorted { $0.seq < $1.seq }
    }
}

public enum HostPhase: String, Codable, Hashable, Sendable {
    /// No microphone session. Starting dictation needs the app in the foreground.
    case inactive
    /// Microphone session ready; audio is discarded until a request starts.
    case warm
    /// Capturing and transcribing a request.
    case listening
    /// Capture stopped; finishing transcription and cleanup.
    case finishing
}

public struct BridgeError: Codable, Hashable, Error, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case microphoneDenied, speechDenied, modelUnavailable, routeUnavailable, network,
             interrupted, cancelled, busy, rewriteUnavailable, emptyTranscript, internalFailure
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct DictationOutcome: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var text: String?
    public var route: TranscriptionRoute?
    public var duration: TimeInterval
    public var completedAt: Date
    public var error: BridgeError?

    public init(requestID: UUID, text: String?, route: TranscriptionRoute?, duration: TimeInterval, completedAt: Date, error: BridgeError?) {
        self.requestID = requestID
        self.text = text
        self.route = route
        self.duration = duration
        self.completedAt = completedAt
        self.error = error
    }
}

public struct RewriteOutcome: Codable, Hashable, Sendable {
    public var jobID: UUID
    public var text: String?
    public var error: BridgeError?
    public var completedAt: Date

    public init(jobID: UUID, text: String?, error: BridgeError?, completedAt: Date) {
        self.jobID = jobID
        self.text = text
        self.error = error
        self.completedAt = completedAt
    }
}

/// The app's published state, as the keyboard sees it.
public struct HostStatus: Codable, Hashable, Sendable {
    public var heartbeat: Date
    public var phase: HostPhase
    public var warmUntil: Date?
    public var lastProcessedSeq: Int
    public var activeRequestID: UUID?
    public var activeRequestOrigin: DictationRequest.Origin?
    /// 0...1 microphone level for the waveform while listening.
    public var level: Float
    /// Live text while listening (volatile results), cleared when finished.
    public var partialText: String?
    public var route: TranscriptionRoute?
    public var outcome: DictationOutcome?
    public var rewrite: RewriteOutcome?
    /// A short status line ("Downloading English model…").
    public var notice: String?

    public init(
        heartbeat: Date = .distantPast,
        phase: HostPhase = .inactive,
        warmUntil: Date? = nil,
        lastProcessedSeq: Int = 0,
        activeRequestID: UUID? = nil,
        activeRequestOrigin: DictationRequest.Origin? = nil,
        level: Float = 0,
        partialText: String? = nil,
        route: TranscriptionRoute? = nil,
        outcome: DictationOutcome? = nil,
        rewrite: RewriteOutcome? = nil,
        notice: String? = nil
    ) {
        self.heartbeat = heartbeat
        self.phase = phase
        self.warmUntil = warmUntil
        self.lastProcessedSeq = lastProcessedSeq
        self.activeRequestID = activeRequestID
        self.activeRequestOrigin = activeRequestOrigin
        self.level = level
        self.partialText = partialText
        self.route = route
        self.outcome = outcome
        self.rewrite = rewrite
        self.notice = notice
    }

    /// The app is alive and can take a new request without coming to the foreground.
    public func canStartInPlace(at now: Date, heartbeatTolerance: TimeInterval = 3) -> Bool {
        guard phase == .warm || phase == .listening || phase == .finishing else { return false }
        guard now.timeIntervalSince(heartbeat) <= heartbeatTolerance else { return false }
        if let warmUntil { return warmUntil > now }
        return true
    }

    /// The app is alive enough to run a rewrite (no microphone needed).
    public func isAlive(at now: Date, heartbeatTolerance: TimeInterval = 3) -> Bool {
        phase != .inactive && now.timeIntervalSince(heartbeat) <= heartbeatTolerance
    }

    /// Forget transcript and rewrite text older than `ttl`. Run by the app before each write.
    public mutating func expireResults(now: Date, ttl: TimeInterval = 60) {
        if let outcome, now.timeIntervalSince(outcome.completedAt) > ttl { self.outcome = nil }
        if let rewrite, now.timeIntervalSince(rewrite.completedAt) > ttl { self.rewrite = nil }
    }
}

public enum BridgeCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .harnessBridge
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .harnessBridge
        return try decoder.decode(type, from: data)
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// Seconds since 1970 as a Double: lossless enough for heartbeats and portable everywhere.
    static var harnessBridge: JSONEncoder.DateEncodingStrategy { .secondsSince1970 }
}

extension JSONDecoder.DateDecodingStrategy {
    static var harnessBridge: JSONDecoder.DateDecodingStrategy { .secondsSince1970 }
}

/// Names shared by the app and the keyboard.
public enum BridgeNames {
    public static let commandsFile = "dictation-commands.json"
    public static let statusFile = "dictation-status.json"
    public static let settingsKey = "harness.dictation.settings"
    public static let keyboardSeenKey = "harness.keyboard.lastSeen"
    public static let commandsPosted = "org.harness.ios.dictation.commands" as String
    public static let statusChanged = "org.harness.ios.dictation.status" as String
    public static let settingsChanged = "org.harness.ios.dictation.settings" as String
}
