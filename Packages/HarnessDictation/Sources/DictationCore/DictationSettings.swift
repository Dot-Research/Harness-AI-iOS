import Foundation

/// Everything the user can configure in the Dictation tab. Shared with the keyboard through the
/// App Group so the keyboard shows the right mode and route. Contains no secrets: cloud keys live
/// in the Keychain and only the main app reads them.
public struct DictationSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var routePreference: RoutePreference
    /// Off by default. When off, Harness never sends audio to a cloud service on its own.
    public var allowCloudFallback: Bool
    /// BCP-47 code, or nil to follow the system language.
    public var languageCode: String?
    public var defaultModeID: String
    public var modes: [DictationMode]
    /// Pick the mode from the text field (email field -> verbatim, Send key -> message).
    public var smartModeFromField: Bool
    public var cleanup: CleanupOptions
    public var dictionary: PersonalDictionary
    /// How long the microphone session stays ready after the last dictation so the keyboard can
    /// start instantly without switching apps. 0 means stop right after each dictation.
    public var warmSessionMinutes: Int
    /// Stop automatically after this many seconds of silence. 0 disables.
    public var silenceAutoStopSeconds: Int
    public var maxUtteranceSeconds: Int
    /// Text-only history in the app (never audio). Off by default.
    public var historyEnabled: Bool
    public var historyRetentionDays: Int
    public var haptics: Bool
    /// The cloud endpoint, if the user set one up. The key is in the Keychain under `credentialID`.
    public var cloudEndpoint: TranscriptionEndpoint?

    public init(
        routePreference: RoutePreference = .automatic,
        allowCloudFallback: Bool = false,
        languageCode: String? = nil,
        defaultModeID: String = DictationMode.message.id,
        modes: [DictationMode] = DictationMode.builtIns,
        smartModeFromField: Bool = true,
        cleanup: CleanupOptions = CleanupOptions(),
        dictionary: PersonalDictionary = PersonalDictionary(),
        warmSessionMinutes: Int = 5,
        silenceAutoStopSeconds: Int = 0,
        maxUtteranceSeconds: Int = 600,
        historyEnabled: Bool = false,
        historyRetentionDays: Int = 7,
        haptics: Bool = true,
        cloudEndpoint: TranscriptionEndpoint? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.routePreference = routePreference
        self.allowCloudFallback = allowCloudFallback
        self.languageCode = languageCode
        self.defaultModeID = defaultModeID
        self.modes = modes
        self.smartModeFromField = smartModeFromField
        self.cleanup = cleanup
        self.dictionary = dictionary
        self.warmSessionMinutes = warmSessionMinutes
        self.silenceAutoStopSeconds = silenceAutoStopSeconds
        self.maxUtteranceSeconds = maxUtteranceSeconds
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = historyRetentionDays
        self.haptics = haptics
        self.cloudEndpoint = cloudEndpoint
    }

    public func mode(id: String) -> DictationMode {
        modes.first(where: { $0.id == id }) ?? modes.first(where: { $0.id == defaultModeID }) ?? .message
    }

    public var warmSessionDuration: TimeInterval { TimeInterval(max(0, warmSessionMinutes)) * 60 }

    /// Decodes stored settings, filling anything missing or unreadable with defaults so an app
    /// update never wipes the user's dictionary or modes.
    public static func decode(_ data: Data?) -> DictationSettings {
        guard let data else { return DictationSettings() }
        let decoder = JSONDecoder()
        if let settings = try? decoder.decode(DictationSettings.self, from: data) {
            return settings.migrated()
        }
        // Partial recovery: keep the dictionary and modes if the rest fails to decode.
        struct Salvage: Decodable {
            var dictionary: PersonalDictionary?
            var modes: [DictationMode]?
        }
        var fallback = DictationSettings()
        if let salvage = try? decoder.decode(Salvage.self, from: data) {
            if let dictionary = salvage.dictionary { fallback.dictionary = dictionary }
            if let modes = salvage.modes, !modes.isEmpty { fallback.modes = modes }
        }
        return fallback
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    func migrated() -> DictationSettings {
        var copy = self
        // Make sure built-in modes exist even if an older version removed one.
        for builtIn in DictationMode.builtIns where !copy.modes.contains(where: { $0.id == builtIn.id }) {
            copy.modes.append(builtIn)
        }
        copy.warmSessionMinutes = min(max(copy.warmSessionMinutes, 0), 60)
        copy.maxUtteranceSeconds = min(max(copy.maxUtteranceSeconds, 30), 1800)
        copy.historyRetentionDays = min(max(copy.historyRetentionDays, 1), 90)
        copy.schemaVersion = Self.currentSchemaVersion
        return copy
    }
}
