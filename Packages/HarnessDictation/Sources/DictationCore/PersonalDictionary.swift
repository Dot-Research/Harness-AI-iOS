import Foundation

/// A word or name the user wants written a specific way: "OpenRouter", "Feili Estates", "HOA",
/// a client's name. Each entry also biases the on-device recognizer toward that spelling.
public struct DictionaryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// How it should be written.
    public var written: String
    /// Extra ways it may come out of the recognizer ("open rooter"). Automatic forms such as
    /// "open router" and "openrouter" are generated and don't need to be listed.
    public var soundsLike: [String]

    public init(id: UUID = UUID(), written: String, soundsLike: [String] = []) {
        self.id = id
        self.written = written
        self.soundsLike = soundsLike
    }
}

public struct PersonalDictionary: Codable, Hashable, Sendable {
    public var entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }

    /// Strings to hand to the recognizer as contextual vocabulary.
    public var contextualStrings: [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let w = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, seen.insert(w.lowercased()).inserted else { return nil }
            return w
        }
    }

    /// Rewrites every spoken form of every entry to its written form. Matches whole words only,
    /// ignores case, and treats any run of spaces in a form as flexible whitespace.
    public func apply(to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        // Longest forms first so "Feili Estates" wins over "Feili".
        var rules: [(form: [String], written: String)] = []
        for entry in entries {
            let written = entry.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !written.isEmpty else { continue }
            var forms = Set(Self.automaticForms(for: written))
            for extra in entry.soundsLike {
                let normalized = Self.normalizeForm(extra)
                if !normalized.isEmpty { forms.insert(normalized) }
            }
            for form in forms {
                let words = form.split(separator: " ").map(String.init)
                if !words.isEmpty { rules.append((words, written)) }
            }
        }
        rules.sort { lhs, rhs in
            lhs.form.count != rhs.form.count ? lhs.form.count > rhs.form.count : lhs.form.joined().count > rhs.form.joined().count
        }

        // Work on word spans of the original text so punctuation and spacing are preserved.
        let spans = Self.wordSpans(in: text)
        guard !spans.isEmpty else { return text }
        var replacements: [(range: Range<String.Index>, with: String)] = []
        var i = 0
        while i < spans.count {
            var matched = false
            for rule in rules {
                let n = rule.form.count
                guard i + n <= spans.count else { continue }
                var ok = true
                for k in 0..<n where spans[i + k].lower != rule.form[k] {
                    ok = false
                    break
                }
                guard ok else { continue }
                // Words in a multi-word form must be separated only by spaces.
                if n > 1 {
                    for k in 0..<(n - 1) {
                        let gap = text[spans[i + k].range.upperBound..<spans[i + k + 1].range.lowerBound]
                        if !gap.allSatisfy({ $0 == " " }) { ok = false; break }
                    }
                }
                guard ok else { continue }
                let range = spans[i].range.lowerBound..<spans[i + n - 1].range.upperBound
                if text[range] != rule.written {
                    replacements.append((range, rule.written))
                }
                i += n
                matched = true
                break
            }
            if !matched { i += 1 }
        }
        guard !replacements.isEmpty else { return text }
        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.with)
        }
        return result
    }

    /// "OpenRouter" -> ["openrouter", "open router"]; "SwiftUI" -> ["swiftui", "swift ui", "swift u i"];
    /// "Feili Estates" -> ["feili estates"]; "iPhone" -> ["iphone", "i phone"].
    public static func automaticForms(for written: String) -> [String] {
        var forms: [String] = []
        let base = normalizeForm(written)
        forms.append(base)
        forms.append(base.replacingOccurrences(of: " ", with: ""))

        // Split camel case and letter/digit boundaries inside each word.
        var pieces: [String] = []
        var spelled: [String] = []
        for word in written.split(whereSeparator: { $0 == " " || $0 == "-" }) {
            let parts = splitCamel(String(word))
            pieces.append(contentsOf: parts.map { $0.lowercased() })
            for part in parts {
                if part.count > 1, part.allSatisfy({ $0.isUppercase }) {
                    spelled.append(contentsOf: part.lowercased().map(String.init))
                } else {
                    spelled.append(part.lowercased())
                }
            }
        }
        forms.append(pieces.joined(separator: " "))
        forms.append(spelled.joined(separator: " "))
        var seen = Set<String>()
        return forms.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func normalizeForm(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func splitCamel(_ word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let chars = Array(word)
        for (i, c) in chars.enumerated() {
            if !current.isEmpty, let prev = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let boundary =
                    (prev.isLowercase && c.isUppercase) ||
                    (prev.isLetter && c.isNumber) || (prev.isNumber && c.isLetter) ||
                    (prev.isUppercase && c.isUppercase && (next?.isLowercase ?? false) && current.count > 1)
                if boundary {
                    parts.append(current)
                    current = ""
                }
            }
            if c.isLetter || c.isNumber { current.append(c) }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    struct WordSpan {
        let range: Range<String.Index>
        let lower: String
    }

    /// Words as runs of letters, digits and inner apostrophes.
    static func wordSpans(in text: String) -> [WordSpan] {
        var spans: [WordSpan] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            let isInner = (c == "'" || c == "’") && start != nil
            if c.isLetter || c.isNumber || isInner {
                if start == nil { start = index }
            } else if let s = start {
                spans.append(WordSpan(range: s..<index, lower: text[s..<index].lowercased()))
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start {
            spans.append(WordSpan(range: s..<text.endIndex, lower: text[s..<text.endIndex].lowercased()))
        }
        return spans
    }
}
