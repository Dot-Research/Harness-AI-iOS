import Foundation

/// What the keyboard can see around the cursor (UITextDocumentProxy gives a limited window).
public struct InsertionContext: Equatable, Sendable {
    public var before: String?
    public var after: String?
    public var selectedText: String?

    public init(before: String? = nil, after: String? = nil, selectedText: String? = nil) {
        self.before = before
        self.after = after
        self.selectedText = selectedText
    }
}

/// Fits dictated text into the text that's already there: a space when needed, a capital at the
/// start of a sentence, lowercase when continuing one, no doubled period.
public enum InsertionPlanner {
    private static let openers: Set<Character> = ["(", "[", "{", "“", "‘", "\"", "'", "/", "-", "@", "#", "$", "¿", "¡"]
    private static let attachingPunctuation: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "}", "”", "’", "%", "…"]

    /// Words that are lowercase when they continue a sentence. Anything else (names, acronyms,
    /// dictionary terms) keeps its case.
    private static let lowercaseOnContinue: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "then", "to", "of", "in", "on", "at", "for", "with", "from",
        "it", "it's", "its", "this", "that", "these", "those", "we", "you", "they", "he", "she", "my", "our",
        "your", "their", "his", "her", "is", "are", "was", "were", "be", "been", "can", "will", "would",
        "should", "could", "not", "also", "just", "maybe", "please", "thanks", "thank", "if", "when", "because",
        "as", "about", "all", "there", "here", "what", "which", "who", "how", "why", "let's", "let", "do", "does",
        "did", "have", "has", "had", "get", "got", "see", "send", "make", "need", "want", "think", "know",
    ]

    public static func fit(_ text: String, into context: InsertionContext, languageCode: String? = "en") -> String {
        guard var result = Optional(text.trimmingCharacters(in: .whitespaces)), !result.isEmpty else { return "" }
        let before = context.before ?? ""
        let after = context.after ?? ""

        let trimmedBefore = before.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
        let lastMeaningful = trimmedBefore.last
        let atSentenceStart: Bool = {
            guard let last = lastMeaningful else { return true }
            if last == "\n" { return true }
            if TextToken.sentenceEnders.contains(last) { return true }
            // List prefixes "- " and "1. " at the start of a line.
            let line = trimmedBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if line == "-" || line == "*" || line == "•" { return true }
            return false
        }()

        if let first = result.first, first.isLetter {
            if atSentenceStart {
                result = first.uppercased() + result.dropFirst()
            } else if let firstWord = result.split(separator: " ").first?.lowercased(),
                      lowercaseOnContinue.contains(String(firstWord).trimmingCharacters(in: .punctuationCharacters)) {
                result = first.lowercased() + result.dropFirst()
            }
        }

        // Leading space.
        if let prev = before.last, !prev.isWhitespace, !openers.contains(prev),
           let firstChar = result.first, !attachingPunctuation.contains(firstChar),
           !(Renderer.isUnspacedScript(prev) || Renderer.isUnspacedScript(firstChar)) {
            result = " " + result
        }

        // Don't double up a period that's already right after the cursor.
        if let nextChar = after.first, let lastChar = result.last,
           TextToken.sentenceEnders.contains(lastChar), attachingPunctuation.contains(nextChar) {
            result.removeLast()
        }

        // Trailing space when the cursor sits right before a word.
        if let nextChar = after.first, nextChar.isLetter || nextChar.isNumber,
           let lastChar = result.last, !lastChar.isWhitespace,
           !(Renderer.isUnspacedScript(nextChar) || Renderer.isUnspacedScript(lastChar)) {
            result += " "
        }
        _ = languageCode
        return result
    }
}
