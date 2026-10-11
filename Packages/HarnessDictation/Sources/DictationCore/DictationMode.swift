import Foundation

/// How dictated text is cleaned up and styled. Modes are user-editable; the four built-ins cover
/// chat, email, notes and exact transcription (for codes, addresses, search boxes).
public struct DictationMode: Codable, Hashable, Identifiable, Sendable {
    public enum Style: String, Codable, Hashable, Sendable, CaseIterable {
        case message, email, note, verbatim, custom
    }

    public var id: String
    public var name: String
    public var style: Style
    /// Extra instruction for the on-device model when `aiPolish` is on, e.g. "Answer in Spanish" or
    /// "Write like a real estate agent texting a client: warm, brief, no emoji".
    public var instruction: String?
    /// Run the on-device language model after rule-based cleanup. Off for verbatim.
    public var aiPolish: Bool

    public init(id: String, name: String, style: Style, instruction: String? = nil, aiPolish: Bool = false) {
        self.id = id
        self.name = name
        self.style = style
        self.instruction = instruction
        self.aiPolish = aiPolish
    }

    public static let message = DictationMode(id: "message", name: "Message", style: .message)
    public static let email = DictationMode(id: "email", name: "Email", style: .email)
    public static let note = DictationMode(id: "note", name: "Note", style: .note)
    public static let verbatim = DictationMode(id: "verbatim", name: "Verbatim", style: .verbatim)

    public static let builtIns: [DictationMode] = [.message, .email, .note, .verbatim]

    /// The rule-based cleanup this mode applies.
    public func cleanupOptions(base: CleanupOptions, languageCode: String?) -> CleanupOptions {
        var options = base
        options.languageCode = languageCode ?? base.languageCode
        switch style {
        case .verbatim:
            options.removeFillers = false
            options.removeRepetitions = false
            options.applySelfCorrections = false
            options.formatLists = false
            options.dropFinalPeriodForShortMessages = false
        case .message:
            options.formatLists = false
        case .email, .note, .custom:
            options.dropFinalPeriodForShortMessages = false
        }
        return options
    }
}

/// Rule-based cleanup switches. Everything here runs on device, offline, in a few milliseconds.
public struct CleanupOptions: Codable, Hashable, Sendable {
    /// "um", "uh", ", you know,", ", like,".
    public var removeFillers: Bool
    /// "the the", "I think I think".
    public var removeRepetitions: Bool
    /// "Tuesday, no wait, Thursday" keeps only "Thursday".
    public var applySelfCorrections: Bool
    /// "new line", "new paragraph", "bullet point", "scratch that".
    public var spokenCommands: Bool
    /// "comma", "period", "question mark". Off by default: "the trial period" is a real phrase.
    public var spokenPunctuation: Bool
    /// "first ..., second ..., third ..." becomes a numbered list.
    public var formatLists: Bool
    /// Capitalize sentence starts and the pronoun "I".
    public var smartCapitalization: Bool
    /// A one-sentence chat message ends without a period, the way people text.
    public var dropFinalPeriodForShortMessages: Bool
    /// BCP-47 language code of the dictation, e.g. "en", "es", "zh". English-specific rules only
    /// run for English.
    public var languageCode: String?

    public init(
        removeFillers: Bool = true,
        removeRepetitions: Bool = true,
        applySelfCorrections: Bool = true,
        spokenCommands: Bool = true,
        spokenPunctuation: Bool = false,
        formatLists: Bool = true,
        smartCapitalization: Bool = true,
        dropFinalPeriodForShortMessages: Bool = true,
        languageCode: String? = "en"
    ) {
        self.removeFillers = removeFillers
        self.removeRepetitions = removeRepetitions
        self.applySelfCorrections = applySelfCorrections
        self.spokenCommands = spokenCommands
        self.spokenPunctuation = spokenPunctuation
        self.formatLists = formatLists
        self.smartCapitalization = smartCapitalization
        self.dropFinalPeriodForShortMessages = dropFinalPeriodForShortMessages
        self.languageCode = languageCode
    }

    var isEnglish: Bool {
        guard let code = languageCode?.lowercased() else { return true }
        return code == "en" || code.hasPrefix("en-") || code.hasPrefix("en_")
    }
}

/// What the keyboard can learn about the text field it is typing into. The keyboard extension maps
/// UIKit's `keyboardType`, `returnKeyType` and `textContentType` to these strings.
public struct FieldTraits: Codable, Hashable, Sendable {
    public var keyboardType: String?
    public var returnKeyType: String?
    public var textContentType: String?

    public init(keyboardType: String? = nil, returnKeyType: String? = nil, textContentType: String? = nil) {
        self.keyboardType = keyboardType
        self.returnKeyType = returnKeyType
        self.textContentType = textContentType
    }
}

/// Picks a sensible mode from the field the user is typing into. A keyboard cannot see which app it
/// is in, so this uses the field itself: an email address field wants exact text, a field with a
/// Send key is a chat, a search box wants short text without a final period.
public enum ModeSuggester {
    public struct Suggestion: Equatable, Sendable {
        public var modeID: String
        /// False for fields where an AI rewrite would be wrong (addresses, codes, URLs, search).
        public var allowsAIPolish: Bool
        public var dropFinalPeriod: Bool

        public init(modeID: String, allowsAIPolish: Bool, dropFinalPeriod: Bool) {
            self.modeID = modeID
            self.allowsAIPolish = allowsAIPolish
            self.dropFinalPeriod = dropFinalPeriod
        }
    }

    private static let exactContentTypes: Set<String> = [
        "emailAddress", "URL", "username", "password", "newPassword", "oneTimeCode",
        "telephoneNumber", "postalCode", "creditCardNumber", "flightNumber", "shipmentTrackingNumber",
    ]

    public static func suggest(for traits: FieldTraits?, userDefaultModeID: String) -> Suggestion {
        guard let traits else {
            return Suggestion(modeID: userDefaultModeID, allowsAIPolish: true, dropFinalPeriod: false)
        }
        if let content = traits.textContentType, exactContentTypes.contains(content) {
            return Suggestion(modeID: DictationMode.verbatim.id, allowsAIPolish: false, dropFinalPeriod: true)
        }
        switch traits.keyboardType {
        case "emailAddress", "URL", "numberPad", "phonePad", "decimalPad", "asciiCapableNumberPad", "namePhonePad":
            return Suggestion(modeID: DictationMode.verbatim.id, allowsAIPolish: false, dropFinalPeriod: true)
        case "webSearch":
            return Suggestion(modeID: DictationMode.verbatim.id, allowsAIPolish: false, dropFinalPeriod: true)
        default:
            break
        }
        switch traits.returnKeyType {
        case "send":
            return Suggestion(modeID: DictationMode.message.id, allowsAIPolish: true, dropFinalPeriod: true)
        case "search", "google", "yahoo", "go", "route", "join":
            return Suggestion(modeID: DictationMode.verbatim.id, allowsAIPolish: false, dropFinalPeriod: true)
        default:
            return Suggestion(modeID: userDefaultModeID, allowsAIPolish: true, dropFinalPeriod: false)
        }
    }
}
