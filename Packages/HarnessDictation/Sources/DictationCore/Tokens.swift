import Foundation

/// A unit of dictated text. Cleanup works on tokens rather than raw strings so that removing a word
/// never leaves doubled spaces, orphaned commas or broken capitalization behind.
public enum TextToken: Equatable, Sendable {
    /// A word, number, email, URL, time ("3:30") or any run of letters/digits with inner joiners.
    case word(String)
    /// Sentence or clause punctuation that attaches to the previous token: . , ! ? ; : … and CJK forms.
    case punct(Character)
    /// One or more line breaks. 1 = new line, 2 = new paragraph.
    case newline(Int)
    /// A list bullet at the start of a line.
    case bullet
    /// A numbered list marker at the start of a line ("1.").
    case number(Int)
    /// Any other symbol (brackets, quotes, currency, emoji...).
    case symbol(String)

    public var wordValue: String? {
        if case let .word(w) = self { return w }
        return nil
    }

    public var isWord: Bool { wordValue != nil }

    public var isSentenceEnd: Bool {
        if case let .punct(p) = self { return TextToken.sentenceEnders.contains(p) }
        return false
    }

    public var isComma: Bool {
        if case let .punct(p) = self { return p == "," || p == "、" || p == "，" }
        return false
    }

    public var isBreak: Bool {
        switch self {
        case .newline, .bullet, .number: return true
        default: return false
        }
    }

    static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let clausePunct: Set<Character> = [".", ",", "!", "?", ";", ":", "…", "。", "，", "！", "？", "、", "；", "："]
}

public enum Tokenizer {
    /// Characters that stay inside a word when surrounded by letters or digits: "3.5", "3:30",
    /// "jane@example.com", "re-do", "don't", "a/b", "c++" is handled by the symbol path.
    private static let innerJoiners: Set<Character> = [".", ":", "@", "/", "-", "'", "’", "_", "+", "&"]

    public static func tokenize(_ text: String) -> [TextToken] {
        var tokens: [TextToken] = []
        var current = ""
        let chars = Array(text)

        func flush() {
            if !current.isEmpty {
                tokens.append(.word(current))
                current = ""
            }
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" || c == "\r" || c == "\u{2028}" || c == "\u{2029}" {
                flush()
                var count = 0
                while i < chars.count, chars[i] == "\n" || chars[i] == "\r" || chars[i] == "\u{2028}" || chars[i] == "\u{2029}" || (chars[i].isWhitespace && chars[i] != "\n") {
                    if chars[i] == "\n" || chars[i] == "\u{2028}" || chars[i] == "\u{2029}" { count += 1 }
                    i += 1
                }
                appendNewline(&tokens, max(1, min(count, 2)))
                continue
            }
            if c.isWhitespace {
                flush()
                i += 1
                continue
            }
            if isWordCharacter(c) {
                current.append(c)
                i += 1
                continue
            }
            if innerJoiners.contains(c), !current.isEmpty, i + 1 < chars.count, isWordCharacter(chars[i + 1]),
               let last = current.last, isWordCharacter(last) {
                // A joiner between two word characters stays in the word ("3.5", "don't", "e-mail").
                current.append(c)
                i += 1
                continue
            }
            if TextToken.clausePunct.contains(c) {
                flush()
                if c == "." , i + 2 < chars.count, chars[i + 1] == ".", chars[i + 2] == "." {
                    tokens.append(.punct("…"))
                    i += 3
                    continue
                }
                tokens.append(.punct(c))
                i += 1
                continue
            }
            flush()
            tokens.append(.symbol(String(c)))
            i += 1
        }
        flush()
        return tokens
    }

    private static func appendNewline(_ tokens: inout [TextToken], _ count: Int) {
        if case let .newline(existing)? = tokens.last {
            tokens[tokens.count - 1] = .newline(min(2, existing + count))
        } else {
            tokens.append(.newline(count))
        }
    }

    /// Letters and digits in any script. Combining marks arrive inside the same grapheme cluster.
    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }
}

public enum Renderer {
    private static let openers: Set<String> = ["(", "[", "{", "“", "‘", "¿", "¡", "$", "€", "£", "¥", "#", "@"]
    private static let closers: Set<String> = [")", "]", "}", "”", "’", "%"]

    public static func render(_ tokens: [TextToken]) -> String {
        var out = ""
        var previous: TextToken?
        var quoteOpen = false
        var noSpaceNext = true

        for token in tokens {
            switch token {
            case let .word(w):
                if !noSpaceNext, needsSpace(between: out.last, and: w.first) { out.append(" ") }
                out.append(w)
                noSpaceNext = false
            case let .punct(p):
                // Trim any trailing space before punctuation.
                while out.last == " " { out.removeLast() }
                out.append(p)
                noSpaceNext = false
            case let .newline(n):
                while out.last == " " { out.removeLast() }
                out.append(String(repeating: "\n", count: n))
                noSpaceNext = true
            case .bullet:
                while out.last == " " { out.removeLast() }
                if !out.isEmpty, out.last != "\n" { out.append("\n") }
                out.append("- ")
                noSpaceNext = true
            case let .number(n):
                while out.last == " " { out.removeLast() }
                if !out.isEmpty, out.last != "\n" { out.append("\n") }
                out.append("\(n). ")
                noSpaceNext = true
            case let .symbol(s):
                if s == "\"" {
                    if quoteOpen {
                        while out.last == " " { out.removeLast() }
                        out.append(s)
                        noSpaceNext = false
                    } else {
                        if !noSpaceNext, !out.isEmpty { out.append(" ") }
                        out.append(s)
                        noSpaceNext = true
                    }
                    quoteOpen.toggle()
                } else if openers.contains(s) {
                    if !noSpaceNext, !out.isEmpty { out.append(" ") }
                    out.append(s)
                    noSpaceNext = true
                } else if closers.contains(s) {
                    while out.last == " " { out.removeLast() }
                    out.append(s)
                    noSpaceNext = false
                } else {
                    // Emoji and other symbols behave like words.
                    if !noSpaceNext, !out.isEmpty { out.append(" ") }
                    out.append(s)
                    noSpaceNext = false
                }
            }
            previous = token
        }
        _ = previous
        while out.last == " " { out.removeLast() }
        return out
    }

    /// Chinese and Japanese are written without spaces between words; Korean uses spaces.
    static func needsSpace(between left: Character?, and right: Character?) -> Bool {
        guard let left, let right else { return left != nil }
        if left == "\n" { return false }
        if isUnspacedScript(left) || isUnspacedScript(right) { return false }
        return true
    }

    static func isUnspacedScript(_ c: Character) -> Bool {
        for scalar in c.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x303F, // CJK symbols and punctuation
                 0x3040...0x30FF, // Hiragana, Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0xFF00...0xFFEF: // Halfwidth and fullwidth forms
                return true
            default:
                continue
            }
        }
        return false
    }
}
