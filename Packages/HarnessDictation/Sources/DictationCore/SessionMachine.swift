import Foundation

/// The rules for the app's microphone session, kept free of AVFoundation so they can be tested.
///
/// iOS only lets an app start recording in the foreground. Once recording, it may keep going in
/// the background. So the first dictation from the keyboard opens the app (`activate`), the session
/// stays "warm" for a few minutes, and further dictations start in place from the keyboard.
public struct SessionMachine: Sendable {
    public struct Config: Equatable, Sendable {
        /// How long the microphone stays ready after the last activity. 0 = stop after each dictation.
        public var warmDuration: TimeInterval
        public var maxUtterance: TimeInterval
        /// If transcription doesn't finish within this time after capture stops, fail the request.
        public var finishTimeout: TimeInterval

        public init(warmDuration: TimeInterval = 300, maxUtterance: TimeInterval = 600, finishTimeout: TimeInterval = 20) {
            self.warmDuration = warmDuration
            self.maxUtterance = maxUtterance
            self.finishTimeout = finishTimeout
        }
    }

    public enum Event: Equatable, Sendable {
        /// The app came to the foreground to serve dictation (deep link from the keyboard, or the
        /// user tapped the mic in the Dictation tab).
        case activate
        case start(DictationRequest)
        case stop(UUID)
        case cancel(UUID)
        /// The engine detected the configured stretch of silence.
        case silence(UUID)
        /// The engine produced final text for the request (or failed to).
        case finished(UUID)
        case audioInterrupted
        case keepWarm
        case endSession
        case tick
    }

    public enum Effect: Equatable, Sendable {
        case startAudio
        case stopAudio
        case beginCapture(DictationRequest)
        /// Stop capturing and produce the final transcript.
        case finishCapture(UUID)
        /// Stop capturing and throw the audio and text away.
        case abortCapture(UUID)
        case fail(UUID, BridgeError)
        /// A start arrived while the session is inactive; the app must be foregrounded first.
        case requireForeground(DictationRequest)
    }

    public private(set) var phase: HostPhase = .inactive
    public private(set) var activeRequest: DictationRequest?
    public private(set) var warmUntil: Date?
    public var config: Config

    private var captureStartedAt: Date?
    private var finishingStartedAt: Date?
    private var audioLost = false
    private var endAfterFinish = false

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func handle(_ event: Event, now: Date) -> [Effect] {
        switch event {
        case .activate:
            if phase == .inactive {
                phase = .warm
                audioLost = false
                endAfterFinish = false
                warmUntil = now.addingTimeInterval(max(config.warmDuration, 60))
                return [.startAudio]
            }
            extendWarm(now)
            return []

        case let .start(request):
            switch phase {
            case .inactive:
                return [.requireForeground(request)]
            case .warm:
                return begin(request, now: now)
            case .listening:
                guard let active = activeRequest, active.id != request.id else { return [] }
                // A new request supersedes one the keyboard has lost track of.
                captureStartedAt = nil
                return [.abortCapture(active.id)] + begin(request, now: now)
            case .finishing:
                if activeRequest?.id == request.id { return [] }
                return [.fail(request.id, BridgeError(.busy, "Still finishing the last dictation. Try again in a moment."))]
            }

        case let .stop(id), let .silence(id):
            guard phase == .listening, activeRequest?.id == id else { return [] }
            phase = .finishing
            finishingStartedAt = now
            return [.finishCapture(id)]

        case let .cancel(id):
            guard phase == .listening || phase == .finishing, activeRequest?.id == id else { return [] }
            activeRequest = nil
            captureStartedAt = nil
            finishingStartedAt = nil
            var effects: [Effect] = [.abortCapture(id)]
            effects += settle(now)
            return effects

        case let .finished(id):
            guard phase == .listening || phase == .finishing, activeRequest?.id == id else { return [] }
            activeRequest = nil
            captureStartedAt = nil
            finishingStartedAt = nil
            return settle(now)

        case .audioInterrupted:
            switch phase {
            case .listening:
                guard let id = activeRequest?.id else { return [] }
                audioLost = true
                phase = .finishing
                finishingStartedAt = now
                return [.finishCapture(id)]
            case .warm:
                phase = .inactive
                warmUntil = nil
                return [.stopAudio]
            case .finishing:
                audioLost = true
                return []
            case .inactive:
                return []
            }

        case .keepWarm:
            extendWarm(now)
            return []

        case .endSession:
            switch phase {
            case .inactive:
                return []
            case .warm:
                phase = .inactive
                warmUntil = nil
                return [.stopAudio]
            case .listening:
                guard let id = activeRequest?.id else { return [] }
                activeRequest = nil
                captureStartedAt = nil
                phase = .inactive
                warmUntil = nil
                return [.abortCapture(id), .stopAudio]
            case .finishing:
                // Let the transcript arrive, then stop.
                endAfterFinish = true
                return []
            }

        case .tick:
            switch phase {
            case .listening:
                if let started = captureStartedAt, let id = activeRequest?.id, now.timeIntervalSince(started) >= config.maxUtterance {
                    phase = .finishing
                    finishingStartedAt = now
                    return [.finishCapture(id)]
                }
                return []
            case .finishing:
                if let started = finishingStartedAt, let id = activeRequest?.id, now.timeIntervalSince(started) >= config.finishTimeout {
                    activeRequest = nil
                    finishingStartedAt = nil
                    return [.abortCapture(id), .fail(id, BridgeError(.internalFailure, "Transcription took too long."))] + settle(now)
                }
                return []
            case .warm:
                if let warmUntil, now >= warmUntil {
                    phase = .inactive
                    self.warmUntil = nil
                    return [.stopAudio]
                }
                return []
            case .inactive:
                return []
            }
        }
    }

    private mutating func begin(_ request: DictationRequest, now: Date) -> [Effect] {
        phase = .listening
        activeRequest = request
        captureStartedAt = now
        finishingStartedAt = nil
        extendWarm(now)
        return [.beginCapture(request)]
    }

    /// After a request ends: back to warm, or stop the microphone.
    private mutating func settle(_ now: Date) -> [Effect] {
        if audioLost || endAfterFinish || config.warmDuration <= 0 {
            phase = .inactive
            warmUntil = nil
            audioLost = false
            endAfterFinish = false
            return [.stopAudio]
        }
        phase = .warm
        warmUntil = now.addingTimeInterval(config.warmDuration)
        return []
    }

    private mutating func extendWarm(_ now: Date) {
        guard phase != .inactive else { return }
        let candidate = now.addingTimeInterval(max(config.warmDuration, 60))
        if let current = warmUntil, current >= candidate { return }
        warmUntil = candidate
    }
}

/// Merges streaming recognizer results: finalized phrases accumulate, the volatile tail is
/// replaced each time a better guess arrives.
public struct TranscriptAccumulator: Sendable {
    public private(set) var finalized: String = ""
    public private(set) var volatile: String = ""

    public init() {}

    public mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    public var current: String { Self.join(finalized, volatile) }

    public mutating func reset() {
        finalized = ""
        volatile = ""
    }

    static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespaces)
        let right = b.trimmingCharacters(in: .whitespaces)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if let l = left.last, let r = right.first, Renderer.isUnspacedScript(l) || Renderer.isUnspacedScript(r) {
            return left + right
        }
        return left + " " + right
    }
}
