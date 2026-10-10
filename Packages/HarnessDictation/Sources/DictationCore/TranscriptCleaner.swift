import Foundation

/// Turns raw speech-to-text output into text a person would have typed.
///
/// Runs entirely on device with no model: filler removal, stutter removal, self-corrections,
/// spoken commands, list formatting, punctuation repair and capitalization. The optional
/// on-device language-model polish (see `RewritePromptBuilder`) runs after this, so the model gets
/// clean input and the result is still good when no model is available.
public struct TranscriptCleaner: Sendable {
    public var options: CleanupOptions

    public init(options: CleanupOptions = CleanupOptions()) {
        self.options = options
    }

    public func clean(_ raw: String) -> String {
        var tokens = Tokenizer.tokenize(raw)
        guard !tokens.isEmpty else { return "" }
        let english = options.isEnglish

        if options.spokenCommands { tokens = SpokenCommands.apply(tokens, english: english, punctuationWords: options.spokenPunctuation) }
        if options.removeFillers { tokens = Fillers.removeSingleWordFillers(tokens, english: english) }
        if options.removeRepetitions { tokens = Repetitions.remove(tokens) }
        if options.applySelfCorrections, english { tokens = SelfCorrections.apply(tokens) }
        if options.removeFillers, english { tokens = Fillers.removePhraseFillers(tokens) }
        if options.formatLists, english { tokens = ListFormatter.formatOrdinalLists(tokens) }
        tokens = PunctuationRepair.apply(tokens)

        var text = Renderer.render(tokens)
        if options.smartCapitalization { text = Capitalizer.apply(text, english: english) }
        if options.dropFinalPeriodForShortMessages { text = Self.dropFinalPeriodIfSingleSentence(text) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dropFinalPeriodIfSingleSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..."), !trimmed.contains("\n") else { return trimmed }
        let body = trimmed.dropLast()
        let enders = body.filter { TextToken.sentenceEnders.contains($0) }
        // "3.5" style inner dots are not sentence ends; only count dots followed by a space.
        let realEnders = zip(body, body.dropFirst()).filter { TextToken.sentenceEnders.contains($0.0) && $0.1 == " " }
        guard enders.isEmpty || realEnders.isEmpty else { return trimmed }
        return String(body)
    }
}

// MARK: - Helpers shared by the passes

extension TextToken {
    var lowerWord: String? { wordValue?.lowercased() }
}

enum TokenSearch {
    /// Returns the index just past `phrase` if the words starting at `index` match it
    /// (case-insensitive, consecutive word tokens only).
    static func match(_ tokens: [TextToken], at index: Int, phrase: [String]) -> Int? {
        var i = index
        for word in phrase {
            guard i < tokens.count, let w = tokens[i].lowerWord, w == word else { return nil }
            i += 1
        }
        return i
    }

    static func isClauseStart(_ tokens: [TextToken], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let prev = tokens[index - 1]
        return prev.isSentenceEnd || prev.isBreak || prev.isComma || { if case .punct(":") = prev { return true }; return false }()
    }

    static func isSentenceStart(_ tokens: [TextToken], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let prev = tokens[index - 1]
        return prev.isSentenceEnd || prev.isBreak
    }

    /// Index of the first token of the sentence containing `index`.
    static func sentenceStart(_ tokens: [TextToken], before index: Int) -> Int {
        var i = index - 1
        while i >= 0 {
            if tokens[i].isSentenceEnd || tokens[i].isBreak { return i + 1 }
            i -= 1
        }
        return 0
    }
}

// MARK: - Spoken commands

enum SpokenCommands {
    private enum Action {
        case newline(Int)
        case bullet
        case scratchThat
        case punct(Character)
        case symbol(String)
    }

    private static let english: [(phrase: [String], action: Action)] = [
        (["new", "paragraph"], .newline(2)),
        (["next", "paragraph"], .newline(2)),
        (["new", "line"], .newline(1)),
        (["next", "line"], .newline(1)),
        (["bullet", "point"], .bullet),
        (["new", "bullet"], .bullet),
        (["next", "bullet"], .bullet),
        (["scratch", "that"], .scratchThat),
    ]

    private static let punctuationWords: [(phrase: [String], action: Action)] = [
        (["question", "mark"], .punct("?")),
        (["exclamation", "point"], .punct("!")),
        (["exclamation", "mark"], .punct("!")),
        (["full", "stop"], .punct(".")),
        (["period"], .punct(".")),
        (["comma"], .punct(",")),
        (["colon"], .punct(":")),
        (["semicolon"], .punct(";")),
        (["open", "paren"], .symbol("(")),
        (["close", "paren"], .symbol(")")),
        (["open", "quote"], .symbol("“")),
        (["close", "quote"], .symbol("”")),
    ]

    static func apply(_ tokens: [TextToken], english isEnglish: Bool, punctuationWords usePunctuation: Bool) -> [TextToken] {
        guard isEnglish else { return tokens }
        let table = english + (usePunctuation ? punctuationWords : [])
        var out: [TextToken] = []
        var i = 0
        while i < tokens.count {
            var matched = false
            for entry in table {
                guard let end = TokenSearch.match(tokens, at: i, phrase: entry.phrase) else { continue }
                matched = true
                var next = end
                switch entry.action {
                case let .newline(n):
                    trimTrailingCommas(&out)
                    out.append(.newline(n))
                    next = skipPunctuation(tokens, from: end)
                case .bullet:
                    trimTrailingCommas(&out)
                    out.append(.bullet)
                    next = skipPunctuation(tokens, from: end)
                case .scratchThat:
                    removeLastClause(&out)
                    next = skipPunctuation(tokens, from: end)
                case let .punct(p):
                    trimTrailingCommas(&out)
                    out.append(.punct(p))
                case let .symbol(s):
                    out.append(.symbol(s))
                }
                i = next
                break
            }
            if !matched {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }

    private static func skipPunctuation(_ tokens: [TextToken], from index: Int) -> Int {
        var i = index
        while i < tokens.count, case .punct = tokens[i] { i += 1 }
        return i
    }

    private static func trimTrailingCommas(_ out: inout [TextToken]) {
        while let last = out.last, last.isComma { out.removeLast() }
    }

    /// "Send it tomorrow. Scratch that. Send it today." removes "Send it tomorrow."
    /// "Send it tomorrow, scratch that, today" removes the clause before the command.
    private static func removeLastClause(_ out: inout [TextToken]) {
        // Drop trailing punctuation that precedes the command.
        var droppedSentenceEnd = false
        while let last = out.last, case .punct = last {
            if last.isSentenceEnd { droppedSentenceEnd = true }
            out.removeLast()
        }
        _ = droppedSentenceEnd
        // Remove back to the previous sentence or line boundary.
        while let last = out.last {
            if last.isSentenceEnd || last.isBreak { break }
            out.removeLast()
        }
    }
}

// MARK: - Fillers

enum Fillers {
    static let englishSingle: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhm", "erm", "er", "err", "ah", "ahh", "hmm", "hm", "mm", "mmm", "mhm",
    ]
    /// Fillers that are not words in most languages.
    static let universalSingle: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "ehm", "hmm", "hm", "mm", "mmm", "mhm"]

    /// Sentence-opening words that keep their comma when a filler follows ("Well, um, I think").
    static let interjections: Set<String> = [
        "so", "well", "yeah", "yes", "no", "okay", "ok", "oh", "hey", "hi", "hello", "anyway", "also", "now",
        "right", "sure", "look", "listen", "honestly", "basically",
    ]

    static func removeSingleWordFillers(_ tokens: [TextToken], english: Bool) -> [TextToken] {
        let fillers = english ? englishSingle : universalSingle
        var out: [TextToken] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if let w = token.lowerWord, fillers.contains(w) {
                let next = i + 1 < tokens.count ? tokens[i + 1] : nil
                if let next, next.isComma {
                    // "I think, uh, we should" -> "I think we should": the commas were only the pause.
                    // "Well, um, I think" keeps "Well," because an opening interjection takes a comma.
                    if let last = out.last, last.isComma {
                        let beforeComma = out.count >= 2 ? out[out.count - 2] : nil
                        let interjectionStart = beforeComma?.lowerWord.map { interjections.contains($0) } ?? false
                            && TokenSearch.isSentenceStart(out, out.count - 2)
                        if !interjectionStart { out.removeLast() }
                    }
                    // "Um, I think" -> "I think".
                    i += 2
                    continue
                }
                if let next, next.isSentenceEnd || next.isBreak, let last = out.last, last.isComma {
                    // "I think, um." -> "I think."
                    out.removeLast()
                }
                i += 1
                continue
            }
            out.append(token)
            i += 1
        }
        return out
    }

    /// ", you know," / ", like," / ", I mean," / ", sort of," used as verbal padding.
    static func removePhraseFillers(_ tokens: [TextToken]) -> [TextToken] {
        let phrases: [[String]] = [["you", "know"], ["i", "mean"], ["like"], ["you", "see"], ["basically"]]
        var out: [TextToken] = []
        var i = 0
        while i < tokens.count {
            var removed = false
            for phrase in phrases {
                guard let end = TokenSearch.match(tokens, at: i, phrase: phrase) else { continue }
                let before = out.last
                let after = end < tokens.count ? tokens[end] : nil
                let openedByComma = before?.isComma ?? false
                let atSentenceStart = before == nil || before!.isSentenceEnd || before!.isBreak
                let closedByComma = after?.isComma ?? false
                let closedBySentenceEnd = after == nil || after!.isSentenceEnd || after!.isBreak
                if (openedByComma && (closedByComma || closedBySentenceEnd)) || (atSentenceStart && closedByComma && phrase != ["like"]) {
                    if closedByComma {
                        // "It was, you know, a long day" -> "It was a long day"; keep "Well," style openers.
                        if openedByComma {
                            let beforeComma = out.count >= 2 ? out[out.count - 2] : nil
                            let interjectionStart = beforeComma?.lowerWord.map { interjections.contains($0) } ?? false
                                && TokenSearch.isSentenceStart(out, out.count - 2)
                            if !interjectionStart { out.removeLast() }
                        }
                        i = end + 1 // also drop the closing comma
                    } else {
                        if openedByComma { out.removeLast() }
                        i = end
                    }
                    removed = true
                    break
                }
            }
            if !removed {
                out.append(tokens[i])
                i += 1
            }
        }
        return out
    }
}

// MARK: - Repetitions

enum Repetitions {
    /// Words people legitimately double.
    static let allowedDoubles: Set<String> = [
        "had", "that", "is", "very", "so", "no", "yes", "bye", "ha", "haha", "hey", "really", "well", "now",
        "there", "do", "many", "much", "more", "far", "too", "again", "ok", "okay", "go", "come", "knock",
        "tick", "chop", "blah", "la", "pretty", "long", "round", "over", "by", "hip", "night", "hush", "boo",
    ]

    static func remove(_ input: [TextToken]) -> [TextToken] {
        var tokens = input
        var changed = true
        var guardCount = 0
        while changed, guardCount < 8 {
            changed = false
            guardCount += 1
            for n in [3, 2, 1] {
                var i = 0
                var out: [TextToken] = []
                while i < tokens.count {
                    if let skip = repeatLength(tokens, at: i, n: n) {
                        // Keep the first copy, drop the repeat (and a comma between them).
                        out.append(contentsOf: tokens[i..<(i + n)])
                        i += skip
                        changed = true
                        continue
                    }
                    out.append(tokens[i])
                    i += 1
                }
                tokens = out
            }
        }
        return tokens
    }

    /// If tokens[i..<i+n] is a run of n words immediately repeated (optionally with a comma
    /// between), returns how many tokens to consume to skip both copies minus the kept one.
    private static func repeatLength(_ tokens: [TextToken], at i: Int, n: Int) -> Int? {
        guard i + 2 * n <= tokens.count else { return nil }
        let first = tokens[i..<(i + n)]
        guard first.allSatisfy(\.isWord) else { return nil }
        var j = i + n
        var gap = 0
        if j < tokens.count, tokens[j].isComma { j += 1; gap = 1 }
        guard j + n <= tokens.count else { return nil }
        let second = tokens[j..<(j + n)]
        guard second.allSatisfy(\.isWord) else { return nil }
        let a = first.compactMap(\.lowerWord)
        let b = second.compactMap(\.lowerWord)
        guard a == b else { return nil }
        if n == 1, allowedDoubles.contains(a[0]) { return nil }
        if n == 1, a[0].first?.isNumber == true { return nil } // "10 10" might be a score
        return n + gap + n
    }
}

// MARK: - Self-corrections

enum SelfCorrections {
    private struct Marker {
        let words: [String]
        /// Weak markers ("sorry", "I mean") are ordinary words too, so they only count when a
        /// comma or dash sets them off.
        let requiresComma: Bool
    }

    private static let markers: [Marker] = [
        Marker(words: ["no", "wait"], requiresComma: false),
        Marker(words: ["wait", "no"], requiresComma: false),
        Marker(words: ["no", "sorry"], requiresComma: false),
        Marker(words: ["sorry", "no"], requiresComma: false),
        Marker(words: ["actually", "no"], requiresComma: false),
        Marker(words: ["no", "actually"], requiresComma: false),
        Marker(words: ["or", "rather"], requiresComma: false),
        Marker(words: ["make", "that"], requiresComma: false),
        Marker(words: ["correction"], requiresComma: true),
        Marker(words: ["sorry"], requiresComma: true),
        Marker(words: ["i", "mean"], requiresComma: true),
        Marker(words: ["no", "no"], requiresComma: true),
    ]

    private static let anchorWords: Set<String> = [
        "on", "at", "in", "to", "for", "with", "by", "from", "until", "till", "before", "after", "about", "around",
        "the", "a", "an", "this", "that", "next", "last", "my", "your", "our", "his", "her", "their",
    ]

    static func apply(_ input: [TextToken]) -> [TextToken] {
        var tokens = input
        var i = 0
        var iterations = 0
        while i < tokens.count, iterations < 64 {
            iterations += 1
            guard let (marker, markerEnd) = markerAt(tokens, i) else { i += 1; continue }
            let precededByComma = i > 0 && (tokens[i - 1].isComma || tokens[i - 1] == .symbol("—") || tokens[i - 1] == .symbol("-"))
            if marker.requiresComma && !precededByComma { i += 1; continue }

            // Replacement: words after the marker up to the next punctuation.
            var rStart = markerEnd
            if rStart < tokens.count, tokens[rStart].isComma { rStart += 1 }
            var rEnd = rStart
            while rEnd < tokens.count, tokens[rEnd].isWord { rEnd += 1 }
            let replacement = Array(tokens[rStart..<rEnd])
            guard (1...6).contains(replacement.count) else { i += 1; continue }

            // The clause being corrected: from sentence start to the marker.
            var clauseEnd = i
            if clauseEnd > 0, precededByComma { clauseEnd -= 1 }
            var clauseStart = TokenSearch.sentenceStart(tokens, before: clauseEnd)
            var removeBoundary: Int?
            if clauseStart == clauseEnd, clauseStart > 0, tokens[clauseStart - 1].isSentenceEnd {
                // "Meet on Tuesday. No wait, Thursday." corrects the previous sentence.
                removeBoundary = clauseStart - 1
                clauseEnd = clauseStart - 1
                clauseStart = TokenSearch.sentenceStart(tokens, before: clauseEnd)
            }
            guard clauseEnd > clauseStart else { i += 1; continue }

            guard let replaceFrom = replaceStart(in: tokens, clause: clauseStart..<clauseEnd, replacement: replacement) else {
                i += 1
                continue
            }
            var rebuilt = Array(tokens[..<replaceFrom])
            rebuilt.append(contentsOf: replacement)
            rebuilt.append(contentsOf: tokens[rEnd...])
            _ = removeBoundary // the boundary sits inside the replaced span and is dropped with it
            tokens = rebuilt
            i = replaceFrom + replacement.count
        }
        return tokens
    }

    private static func markerAt(_ tokens: [TextToken], _ i: Int) -> (Marker, Int)? {
        for marker in markers {
            if let end = TokenSearch.match(tokens, at: i, phrase: marker.words) { return (marker, end) }
        }
        return nil
    }

    /// Where the corrected part of the clause starts, or nil when the correction is not clearly
    /// parallel to anything (then the text is left alone rather than guessed at).
    private static func replaceStart(in tokens: [TextToken], clause: Range<Int>, replacement: [TextToken]) -> Int? {
        guard let first = replacement.first?.wordValue else { return nil }
        let firstLower = first.lowercased()

        // 1. Anchor: "on Tuesday, no wait, on Thursday" -> replace from the last "on".
        if anchorWords.contains(firstLower) {
            for j in clause.reversed() where tokens[j].lowerWord == firstLower {
                return j
            }
        }
        // 2. Same kind of thing: number, time, weekday, month, relative day, proper noun.
        let kind = WordKind.of(first, atSentenceStart: false)
        if kind != .other {
            for j in clause.reversed() {
                guard let w = tokens[j].wordValue else { continue }
                let atStart = TokenSearch.isSentenceStart(tokens, j)
                if WordKind.of(w, atSentenceStart: atStart) == kind { return j }
            }
        }
        return nil
    }
}

enum WordKind: Equatable {
    case number, weekday, month, relativeDay, properNoun, other

    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "noon", "midnight",
        "half", "quarter",
    ]
    static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]
    static let relativeDays: Set<String> = ["today", "tomorrow", "tonight", "yesterday", "weekend"]

    static func of(_ word: String, atSentenceStart: Bool) -> WordKind {
        let lower = word.lowercased()
        if lower.first?.isNumber == true || numberWords.contains(lower) { return .number }
        if lower.hasPrefix("$") { return .number }
        if weekdays.contains(lower) { return .weekday }
        if months.contains(lower) && lower != "may" { return .month }
        if relativeDays.contains(lower) { return .relativeDay }
        if !atSentenceStart, word != "I", let f = word.first, f.isUppercase { return .properNoun }
        return .other
    }
}

// MARK: - Lists

enum ListFormatter {
    private static let ordinals: [(words: [String], index: Int)] = [
        (["first", "of", "all"], 1), (["number", "one"], 1), (["firstly"], 1), (["first"], 1),
        (["number", "two"], 2), (["secondly"], 2), (["second"], 2),
        (["number", "three"], 3), (["thirdly"], 3), (["third"], 3),
        (["number", "four"], 4), (["fourthly"], 4), (["fourth"], 4),
        (["number", "five"], 5), (["fifth"], 5),
        (["lastly"], 99), (["finally"], 99),
    ]

    /// "I need three things: first, milk, second, eggs, and third, bread." ->
    /// "I need three things:\n1. Milk\n2. Eggs\n3. Bread"
    static func formatOrdinalLists(_ tokens: [TextToken]) -> [TextToken] {
        // Find ordinal markers at clause starts, in increasing order starting at 1.
        var markers: [(start: Int, end: Int)] = []
        var expected = 1
        var i = 0
        while i < tokens.count {
            if TokenSearch.isClauseStart(tokens, i) {
                var j = i
                if tokens[j].lowerWord == "and", j + 1 < tokens.count { j += 1 }
                if let (end, index) = ordinalAt(tokens, j), index == expected || (index == 99 && expected >= 3) {
                    // An ordinal is a list marker only when followed by a comma or more words.
                    let followedByContent = end < tokens.count && (tokens[end].isComma || tokens[end].isWord)
                    if followedByContent {
                        markers.append((start: i, end: end))
                        expected = index == 99 ? 100 : expected + 1
                        i = end
                        continue
                    }
                }
            }
            i += 1
        }
        guard markers.count >= 3 else { return tokens }

        var out: [TextToken] = Array(tokens[..<markers[0].start])
        while let last = out.last, last.isComma { out.removeLast() }
        if let last = out.last {
            if !last.isSentenceEnd, last != .punct(":") { out.append(.punct(":")) }
        }
        for (n, marker) in markers.enumerated() {
            var itemStart = marker.end
            if itemStart < tokens.count, tokens[itemStart].isComma { itemStart += 1 }
            let nextStart = n + 1 < markers.count ? markers[n + 1].start : nil
            var itemEnd: Int
            if let nextStart {
                itemEnd = nextStart
            } else {
                // The last item runs to the end of its sentence.
                itemEnd = itemStart
                while itemEnd < tokens.count, !tokens[itemEnd].isSentenceEnd, !tokens[itemEnd].isBreak { itemEnd += 1 }
            }
            var item = Array(tokens[itemStart..<itemEnd])
            while let last = item.last, last.isComma || last.lowerWord == "and" || last.isSentenceEnd { item.removeLast() }
            out.append(.number(n + 1))
            out.append(contentsOf: item)
            if nextStart == nil {
                var rest = itemEnd
                if rest < tokens.count, tokens[rest].isSentenceEnd { rest += 1 }
                if rest < tokens.count {
                    out.append(.newline(2))
                    out.append(contentsOf: tokens[rest...].drop(while: { $0.isBreak }))
                }
            }
        }
        return out
    }

    private static func ordinalAt(_ tokens: [TextToken], _ i: Int) -> (Int, Int)? {
        for entry in ordinals {
            if let end = TokenSearch.match(tokens, at: i, phrase: entry.words) { return (end, entry.index) }
        }
        return nil
    }
}

// MARK: - Punctuation repair

enum PunctuationRepair {
    static func apply(_ tokens: [TextToken]) -> [TextToken] {
        var out: [TextToken] = []
        for token in tokens {
            if case let .punct(p) = token {
                // No punctuation at the very start or right after a line break.
                guard let last = out.last, !last.isBreak else { continue }
                if case let .punct(q) = last {
                    let lastIsEnder = TextToken.sentenceEnders.contains(q)
                    let thisIsEnder = TextToken.sentenceEnders.contains(p)
                    if !lastIsEnder && thisIsEnder {
                        out[out.count - 1] = token // ", ." -> "."
                    }
                    // ". ," and ". ." and "?." keep the first.
                    continue
                }
            }
            if case .newline = token, let last = out.last, last.isComma {
                out.removeLast()
            }
            out.append(token)
        }
        while let last = out.last, last.isComma || last.isBreak { out.removeLast() }
        return out
    }
}

// MARK: - Capitalization

enum Capitalizer {
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "approx", "cf", "a.m", "p.m"]

    static func apply(_ text: String, english: Bool) -> String {
        var chars = Array(text)
        var capitalizeNext = true
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if capitalizeNext {
                if c.isLetter {
                    let upper = String(c).uppercased()
                    if upper.count == 1, let u = upper.first { chars[i] = u }
                    capitalizeNext = false
                } else if c.isNumber {
                    capitalizeNext = false
                }
            }
            if c == "\n" {
                capitalizeNext = true
            } else if TextToken.sentenceEnders.contains(c) {
                let nextIsSpace = i + 1 < chars.count && (chars[i + 1] == " " || chars[i + 1] == "\n")
                if nextIsSpace && !isAbbreviation(chars, endingAt: i) { capitalizeNext = true }
            }
            i += 1
        }
        var result = String(chars)
        if english { result = capitalizePronounI(result) }
        return result
    }

    private static func isAbbreviation(_ chars: [Character], endingAt dotIndex: Int) -> Bool {
        guard chars[dotIndex] == "." else { return false }
        var j = dotIndex - 1
        var word = ""
        while j >= 0, chars[j].isLetter || chars[j] == "." {
            word.insert(chars[j], at: word.startIndex)
            j -= 1
        }
        return abbreviations.contains(word.lowercased())
    }

    /// "i" as a standalone word, or before 'm 've 'll 'd, becomes "I".
    private static func capitalizePronounI(_ text: String) -> String {
        var chars = Array(text)
        let suffixes: [[Character]] = [["m"], ["v", "e"], ["l", "l"], ["d"]]
        for i in chars.indices where chars[i] == "i" {
            let prevIsWord = i > 0 && (chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "'" || chars[i - 1] == "’" || chars[i - 1] == "-")
            if prevIsWord { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if let next, next.isLetter || next.isNumber || next == "-" || next == "." && i + 2 < chars.count && chars[i + 2].isLetter {
                continue
            }
            if let next, next == "'" || next == "’" {
                let rest = Array(chars[(i + 2)...].prefix(2))
                let matches = suffixes.contains { suffix in
                    rest.count >= suffix.count && Array(rest.prefix(suffix.count)) == suffix
                        && (i + 2 + suffix.count >= chars.count || !chars[i + 2 + suffix.count].isLetter)
                }
                guard matches else { continue }
            }
            chars[i] = "I"
        }
        return String(chars)
    }
}
