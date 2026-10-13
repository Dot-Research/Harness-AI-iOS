import Foundation

/// Builds instructions for the selected language model (Fix, Rewrite, mode polish) and checks
/// what comes back before it touches the user's text field.
public enum RewritePromptBuilder {
    public static func instructions(for action: RewriteAction, modes: [DictationMode], userInstructions: String = DictationInstructions.defaultText) -> String {
        let base = """
        You edit text the user dictated or typed. Return only the edited text: no preamble, no quotes, \
        no explanation, no markdown unless the input or the user's formatting instruction calls for it. \
        Keep the user's language unless they request a translation. Preserve meaning, \
        names, numbers, links and facts exactly. Never add information. Never answer questions in the text; \
        just edit them.
        """
        let baseWithVoice = appendUserInstructions(userInstructions, to: base)
        switch action {
        case .fix:
            return baseWithVoice + "\nFix grammar, spelling, punctuation and obvious speech-recognition mistakes. Keep the wording and tone; change as little as possible."
        case let .rewrite(modeID):
            let mode = modes.first(where: { $0.id == modeID }) ?? .message
            return baseWithVoice + "\n" + styleGuide(for: mode)
        case let .instruct(instruction):
            let cleaned = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            return baseWithVoice + "\nApply this instruction from the user to the text: \(cleaned)"
        }
    }

    /// Instructions for polishing a fresh dictation in a given mode (after rule-based cleanup).
    public static func polishInstructions(for mode: DictationMode, userInstructions: String = DictationInstructions.defaultText) -> String {
        let base = """
        You clean up dictated text. Return only the cleaned text. Remove leftover filler, false starts and \
        repeated words; when the speaker corrected themselves, keep only the correction. Fix punctuation \
        and capitalization. Keep the speaker's words, meaning, names and numbers; do not summarize or add anything.
        """
        return appendUserInstructions(userInstructions, to: base) + "\n" + styleGuide(for: mode)
    }

    private static func appendUserInstructions(_ instructions: String, to base: String) -> String {
        let voice = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voice.isEmpty else { return base }
        return base + "\nUser's voice and formatting preferences (apply while preserving the facts):\n" + voice
    }

    static func styleGuide(for mode: DictationMode) -> String {
        var guide: String
        switch mode.style {
        case .message:
            guide = "Style: a casual chat message. Short sentences, natural tone, no greeting or sign-off unless spoken."
        case .email:
            guide = "Style: a clear, polite email body. Paragraphs where the speaker changed topic. Keep any greeting or sign-off that was spoken."
        case .note:
            guide = "Style: a tidy note. Use short paragraphs, and use a list when the speaker listed items."
        case .verbatim:
            guide = "Style: exactly what was said, only with punctuation fixed."
        case .custom:
            guide = "Style: clear and natural."
        }
        if let instruction = mode.instruction?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty {
            guide += " Also: \(instruction)"
        }
        return guide
    }

    public static func prompt(for text: String) -> String {
        "Text:\n\(text)"
    }
}

public enum RewriteOutputSanitizer {
    public enum Rejection: Error, Equatable, Sendable {
        case empty
        case runaway
        case refusal
    }

    private static let preambles = [
        "here is the edited text", "here's the edited text", "here is the rewritten text", "here's the rewritten text",
        "here is the corrected text", "here's the corrected text", "here is the cleaned text", "here's the cleaned text",
        "here is the text", "here's the text", "edited text", "rewritten text", "corrected text", "cleaned text",
    ]

    private static let refusals = ["i can't help with", "i cannot help with", "i'm sorry, but i can", "i am unable to", "as an ai"]

    /// Strips wrappers models like to add and rejects output that would damage the user's text.
    public static func clean(_ output: String, original: String) throws -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Code fences.
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A first line that is only a preamble ("Sure! Here's the edited text:").
        if let newline = text.firstIndex(of: "\n") {
            let firstLine = text[..<newline].lowercased().trimmingCharacters(in: .whitespaces)
            let originalFirstLine = original.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?.lowercased()
            if firstLine != originalFirstLine, isPreamble(firstLine) {
                text = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            let lower = text.lowercased()
            for preamble in preambles where lower.hasPrefix(preamble + ":") {
                text = String(text.dropFirst(preamble.count + 1)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        // Matching quotes around the whole thing, unless the original was quoted too.
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(originalTrimmed.first == open && originalTrimmed.last == close) {
                text = String(text.dropFirst().dropLast())
            }
        }

        guard !text.isEmpty else { throw Rejection.empty }
        let lower = text.lowercased()
        if refusals.contains(where: { lower.hasPrefix($0) }) { throw Rejection.refusal }
        // A rewrite should not balloon. Allow growth for short inputs and instructions like
        // "translate", but stop a model that started writing an essay.
        let limit = max(original.count * 3, original.count + 400)
        if text.count > limit { throw Rejection.runaway }
        return text
    }

    private static func isPreamble(_ line: String) -> Bool {
        var normalized = line.trimmingCharacters(in: .whitespaces)
        for courtesy in ["sure!", "sure,", "certainly!", "certainly,"] where normalized.hasPrefix(courtesy) {
            normalized = String(normalized.dropFirst(courtesy.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ":.!"))
        return preambles.contains(normalized)
    }
}

/// Deep links between the keyboard and the app.
public enum HarnessLink {
    public static let scheme = "harness"

    public enum Destination: Equatable, Sendable {
        /// Start (or continue) dictation for a keyboard request already in the command queue.
        case dictate(requestID: UUID?)
        /// Open GOD with text handed over from the keyboard.
        case askGOD(handoffID: UUID)
        /// Open the Dictation tab, optionally at a section ("setup", "dictionary", "history").
        case dictationTab(section: String?)
    }

    public static func url(for destination: Destination) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        switch destination {
        case let .dictate(requestID):
            components.host = "dictation"
            components.path = "/start"
            if let requestID { components.queryItems = [URLQueryItem(name: "request", value: requestID.uuidString)] }
        case let .askGOD(handoffID):
            components.host = "god"
            components.path = "/ask"
            components.queryItems = [URLQueryItem(name: "handoff", value: handoffID.uuidString)]
        case let .dictationTab(section):
            components.host = "dictation"
            components.path = "/settings"
            if let section { components.queryItems = [URLQueryItem(name: "section", value: section)] }
        }
        return components.url!
    }

    public static func parse(_ url: URL) -> Destination? {
        guard url.scheme?.lowercased() == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        switch (components.host?.lowercased(), components.path.lowercased()) {
        case ("dictation", "/start"):
            return .dictate(requestID: query["request"].flatMap(UUID.init(uuidString:)))
        case ("god", "/ask"):
            guard let id = query["handoff"].flatMap(UUID.init(uuidString:)) else { return nil }
            return .askGOD(handoffID: id)
        case ("dictation", "/settings"), ("dictation", ""), ("dictation", "/"):
            return .dictationTab(section: query["section"])
        default:
            return nil
        }
    }
}
