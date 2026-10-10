import Foundation

// The Vault: plain Markdown files, Obsidian-compatible links, and an index for backlinks and search.
// This file is pure Swift (parsing, resolution, ranking); VaultStore.swift does the file I/O.

/// A note or folder location inside a vault: "/"-separated, relative, no hidden or traversal components.
public struct VaultPath: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1024, !trimmed.contains("\0"), !trimmed.contains("\\") else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts {
            guard !part.isEmpty, part.utf8.count <= 255, !part.hasPrefix("."),
                  part.trimmingCharacters(in: .whitespaces) == part else { return nil }
        }
        rawValue = parts.joined(separator: "/")
    }

    public var components: [String] { rawValue.split(separator: "/").map(String.init) }
    public var name: String { components.last ?? rawValue }
    public var isNote: Bool { rawValue.lowercased().hasSuffix(".md") }
    /// File name without ".md".
    public var title: String { isNote ? String(name.dropLast(3)) : name }
    public var parent: VaultPath? { components.count > 1 ? VaultPath(components.dropLast().joined(separator: "/")) : nil }
    /// First component for notes inside a folder; nil for notes at the vault root.
    public var topFolder: String? { components.count > 1 ? components[0] : nil }
    public func appending(_ component: String) -> VaultPath? { VaultPath(rawValue + "/" + component) }
    public var description: String { rawValue }
    public static func < (a: VaultPath, b: VaultPath) -> Bool { a.rawValue.localizedStandardCompare(b.rawValue) == .orderedAscending }
}

public enum FrontmatterValue: Equatable, Sendable {
    case text(String)
    case list([String])
    public var displayText: String {
        switch self {
        case .text(let value): return value
        case .list(let values): return values.joined(separator: ", ")
        }
    }
}

public struct WikiLink: Equatable, Sendable {
    /// What the link points at, as written: "Roadmap", "Projects/Roadmap", "Roadmap.md".
    public var target: String
    public var heading: String?
    public var alias: String?
    public var isEmbed: Bool
    public var displayText: String { alias ?? heading.map { "\(target) › \($0)" } ?? target }
}

public struct ParsedNote: Equatable, Sendable {
    public var title: String
    public var frontmatter: [(key: String, value: FrontmatterValue)]
    public var body: String
    public var links: [WikiLink]
    public var tags: [String]
    public var headings: [String]
    public var openTasks: Int
    public var doneTasks: Int

    public static func == (a: ParsedNote, b: ParsedNote) -> Bool {
        a.title == b.title && a.body == b.body && a.links == b.links && a.tags == b.tags && a.headings == b.headings
            && a.openTasks == b.openTasks && a.doneTasks == b.doneTasks
            && a.frontmatter.map(\.key) == b.frontmatter.map(\.key) && a.frontmatter.map(\.value) == b.frontmatter.map(\.value)
    }

    public func property(_ key: String) -> FrontmatterValue? {
        frontmatter.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

public enum MarkdownNote {
    /// Parses a note. `fallbackTitle` (usually the file name) is used when there is no "# " heading.
    public static func parse(_ text: String, fallbackTitle: String) -> ParsedNote {
        let (frontmatter, body) = splitFrontmatter(text)
        var links: [WikiLink] = []
        var tags: [String] = []
        var headings: [String] = []
        var open = 0, done = 0
        var inFence = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") || stripped.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            if let heading = headingText(stripped) { headings.append(heading) }
            if stripped.hasPrefix("- [ ] ") || stripped.hasPrefix("* [ ] ") { open += 1 }
            if stripped.lowercased().hasPrefix("- [x] ") || stripped.lowercased().hasPrefix("* [x] ") { done += 1 }
            let visible = removingInlineCode(line)
            links += wikiLinks(in: visible) + markdownNoteLinks(in: visible)
            tags += inlineTags(in: visible)
        }
        if let declared = frontmatter.first(where: { ["tags", "tag"].contains($0.key.lowercased()) })?.value {
            switch declared {
            case .text(let value): tags += value.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            case .list(let values): tags += values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            }
        }
        var seen = Set<String>()
        tags = tags.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        // Like Obsidian, the file name is the title, so renaming a note retitles it.
        return ParsedNote(title: fallbackTitle, frontmatter: frontmatter, body: body, links: links, tags: tags,
                          headings: headings, openTasks: open, doneTasks: done)
    }

    /// YAML front matter between "---" lines at the very start. Supports `key: value`, `key: [a, b]`
    /// and indented `- item` lists, which covers what Obsidian writes. Anything else stays text.
    public static func splitFrontmatter(_ text: String) -> ([(key: String, value: FrontmatterValue)], String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ([], normalized) }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return ([], normalized) }
        var result: [(key: String, value: FrontmatterValue)] = []
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- "), line.first == " " || line.first == "\t" || line.hasPrefix("- "), let last = result.indices.last {
                let item = unquote(String(trimmed.dropFirst(2)))
                switch result[last].value {
                case .list(let items): result[last].value = .list(items + [item])
                case .text(let existing): result[last].value = existing.isEmpty ? .list([item]) : .list([existing, item])
                }
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.hasPrefix("[") && value.hasSuffix("]") {
                let items = value.dropFirst().dropLast().split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
                result.append((key, .list(items)))
            } else {
                result.append((key, .text(unquote(value))))
            }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (result, body.hasPrefix("\n") ? String(body.dropFirst()) : body)
    }

    /// Text of an ATX heading ("## Title" -> "Title"), or nil.
    public static func headingText(_ line: String) -> String? {
        var level = 0
        for character in line { if character == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), line.count > level else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    public static func wikiLinks(in line: String) -> [WikiLink] {
        var links: [WikiLink] = []
        var rest = Substring(line)
        while let open = rest.range(of: "[[") {
            guard let close = rest[open.upperBound...].range(of: "]]") else { break }
            let inner = String(rest[open.upperBound..<close.lowerBound])
            let isEmbed = open.lowerBound > rest.startIndex && rest[rest.index(before: open.lowerBound)] == "!"
            if !inner.isEmpty, !inner.contains("\n"), !inner.contains("[") {
                var target = inner, alias: String?, heading: String?
                if let bar = target.firstIndex(of: "|") {
                    alias = String(target[target.index(after: bar)...]).trimmingCharacters(in: .whitespaces)
                    target = String(target[..<bar])
                }
                if let hash = target.firstIndex(of: "#") {
                    heading = String(target[target.index(after: hash)...]).trimmingCharacters(in: CharacterSet(charactersIn: "^ "))
                    target = String(target[..<hash])
                }
                target = target.trimmingCharacters(in: .whitespaces)
                if !target.isEmpty {
                    links.append(WikiLink(target: target, heading: heading?.isEmpty == true ? nil : heading,
                                          alias: alias?.isEmpty == true ? nil : alias, isEmbed: isEmbed))
                }
            }
            rest = rest[close.upperBound...]
        }
        return links
    }

    /// `[text](Some%20Note.md)` links to other notes (relative, ending in .md).
    static func markdownNoteLinks(in line: String) -> [WikiLink] {
        var links: [WikiLink] = []
        var rest = Substring(line)
        while let open = rest.range(of: "]("), let close = rest[open.upperBound...].firstIndex(of: ")") {
            let destination = String(rest[open.upperBound..<close])
            rest = rest[rest.index(after: close)...]
            let decoded = destination.removingPercentEncoding ?? destination
            guard !decoded.contains("://"), !decoded.hasPrefix("/"), !decoded.hasPrefix("#") else { continue }
            let (file, heading) = decoded.split(separator: "#", maxSplits: 1).map(String.init).splitFirst()
            guard file.lowercased().hasSuffix(".md") else { continue }
            links.append(WikiLink(target: file, heading: heading, alias: nil, isEmbed: false))
        }
        return links
    }

    /// `#tag`, `#nested/tag`, `#tag-name`: preceded by start or whitespace, not all digits.
    public static func inlineTags(in line: String) -> [String] {
        var tags: [String] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            if characters[index] == "#", index == 0 || characters[index - 1].isWhitespace {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || "_-/".contains(characters[end]) { end += 1 }
                let tag = String(characters[(index + 1)..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !tag.isEmpty, tag.contains(where: { !$0.isNumber }) { tags.append(tag) }
                index = end
            } else {
                index += 1
            }
        }
        return tags
    }

    static func removingInlineCode(_ line: String) -> String {
        guard line.contains("`") else { return line }
        var output = "", inCode = false
        for character in line {
            if character == "`" { inCode.toggle(); output.append(" "); continue }
            output.append(inCode ? " " : character)
        }
        return output
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, let first = value.first, let last = value.last, (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

private extension Array where Element == String {
    func splitFirst() -> (String, String?) { (first ?? "", count > 1 ? self[1] : nil) }
}

// MARK: - Index

public struct VaultNoteSummary: Equatable, Sendable, Identifiable {
    public var path: VaultPath
    public var modified: Date
    public var size: Int
    public var note: ParsedNote
    public var id: VaultPath { path }
    public init(path: VaultPath, modified: Date, size: Int, note: ParsedNote) {
        self.path = path; self.modified = modified; self.size = size; self.note = note
    }
}

public struct VaultBacklink: Equatable, Sendable, Identifiable {
    public var source: VaultPath
    public var title: String
    /// The line containing the link, trimmed.
    public var context: String
    public var id: String { source.rawValue + "\u{1F}" + context }
}

public struct VaultSearchHit: Equatable, Sendable, Identifiable, Codable {
    public var path: VaultPath
    public var title: String
    public var snippet: String
    public var score: Double
    public var id: VaultPath { path }
}

public struct VaultIndex: Sendable {
    public private(set) var notes: [VaultPath: VaultNoteSummary]
    /// Lowercased note title (file name without .md) -> paths with that name.
    private var byName: [String: [VaultPath]]

    public init(notes: [VaultNoteSummary]) {
        var map: [VaultPath: VaultNoteSummary] = [:]
        var names: [String: [VaultPath]] = [:]
        for summary in notes {
            map[summary.path] = summary
            names[summary.path.title.lowercased(), default: []].append(summary.path)
        }
        self.notes = map
        byName = names.mapValues { $0.sorted() }
    }

    public var count: Int { notes.count }
    public var recent: [VaultNoteSummary] { notes.values.sorted { $0.modified > $1.modified } }

    /// Resolves a link the way Obsidian does: a path ("Projects/Roadmap") matches by path suffix;
    /// a bare name matches by file name, preferring the source note's folder, then the shortest path.
    public func resolve(_ target: String, from source: VaultPath? = nil) -> VaultPath? {
        var cleaned = target.trimmingCharacters(in: .whitespaces)
        if cleaned.lowercased().hasSuffix(".md") { cleaned = String(cleaned.dropLast(3)) }
        if cleaned.hasPrefix("./") { cleaned = String(cleaned.dropFirst(2)) }
        guard !cleaned.isEmpty else { return nil }
        if cleaned.contains("/") {
            if let relativeBase = source?.parent, let joined = VaultPath(relativeBase.rawValue + "/" + cleaned + ".md"), notes[joined] != nil { return joined }
            let suffix = "/" + cleaned.lowercased() + ".md"
            let matches = notes.keys.filter { ("/" + $0.rawValue.lowercased()).hasSuffix(suffix) }
            return matches.min { ($0.components.count, $0) < ($1.components.count, $1) }
        }
        guard let candidates = byName[cleaned.lowercased()], !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        if let folder = source?.parent, let local = candidates.first(where: { $0.parent == folder }) { return local }
        if source?.parent == nil, let rootLevel = candidates.first(where: { $0.parent == nil }) { return rootLevel }
        return candidates.min { ($0.components.count, $0) < ($1.components.count, $1) }
    }

    public func backlinks(to path: VaultPath) -> [VaultBacklink] {
        var result: [VaultBacklink] = []
        for (source, summary) in notes where source != path {
            guard summary.note.links.contains(where: { resolve($0.target, from: source) == path }) else { continue }
            for line in summary.note.body.split(separator: "\n") {
                let lineLinks = MarkdownNote.wikiLinks(in: String(line)) + MarkdownNote.markdownNoteLinks(in: String(line))
                if lineLinks.contains(where: { resolve($0.target, from: source) == path }) {
                    result.append(VaultBacklink(source: source, title: summary.note.title,
                                                context: String(line.trimmingCharacters(in: .whitespaces).prefix(240))))
                }
            }
        }
        return result.sorted { ($0.title.lowercased(), $0.context) < ($1.title.lowercased(), $1.context) }
    }

    /// How many other notes link to each note, in one pass (for list rows).
    public func backlinkCounts() -> [VaultPath: Int] {
        var counts: [VaultPath: Int] = [:]
        for (source, summary) in notes {
            let targets = Set(summary.note.links.compactMap { resolve($0.target, from: source) }).subtracting([source])
            for target in targets { counts[target, default: 0] += 1 }
        }
        return counts
    }

    /// Links in `path` that point at no existing note (candidates for "create note").
    public func unresolvedLinks(in path: VaultPath) -> [WikiLink] {
        guard let summary = notes[path] else { return [] }
        var seen = Set<String>()
        return summary.note.links.filter { resolve($0.target, from: path) == nil && seen.insert($0.target.lowercased()).inserted }
    }

    public var tags: [(tag: String, count: Int)] {
        var counts: [String: (display: String, count: Int)] = [:]
        for summary in notes.values {
            for tag in summary.note.tags { counts[tag.lowercased(), default: (tag, 0)].count += 1 }
        }
        return counts.values.map { (tag: $0.display, count: $0.count) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    public func notes(taggedWith tag: String) -> [VaultNoteSummary] {
        notes.values.filter { $0.note.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.sorted { $0.modified > $1.modified }
    }

    /// Ranked local search over titles, paths, tags and text. Every query word must appear somewhere.
    public func search(_ query: String, limit: Int = 50, where include: (VaultPath) -> Bool = { _ in true }) -> [VaultSearchHit] {
        let words = Self.normalize(query).split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var hits: [VaultSearchHit] = []
        for (path, summary) in notes where include(path) {
            let title = Self.normalize(summary.note.title), pathText = Self.normalize(path.rawValue)
            let tags = summary.note.tags.map(Self.normalize), body = Self.normalize(summary.note.body)
            var score = 0.0
            var matchedAll = true
            for word in words {
                var wordScore = 0.0
                if title.contains(word) { wordScore += title.hasPrefix(word) ? 8 : 5 }
                if pathText.contains(word) { wordScore += 2 }
                if tags.contains(where: { $0.contains(word) }) { wordScore += 3 }
                let occurrences = body.components(separatedBy: word).count - 1
                wordScore += min(Double(occurrences), 5)
                if wordScore == 0 { matchedAll = false; break }
                score += wordScore
            }
            guard matchedAll else { continue }
            // Recently edited notes rank a little higher on ties.
            score += max(0, 1 - Date().timeIntervalSince(summary.modified) / (86_400 * 30)) * 0.5
            hits.append(VaultSearchHit(path: path, title: summary.note.title, snippet: Self.snippet(summary.note.body, words: words), score: score))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        return Array(hits.prefix(limit))
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func snippet(_ body: String, words: [String]) -> String {
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "---" }
        let line = lines.first { line in words.contains { normalize(line).contains($0) } } ?? lines.first ?? ""
        return String(line.prefix(160))
    }
}

/// Renames link targets that point at a renamed note, keeping heading and alias.
public enum VaultLinkRewriter {
    public static func rewrite(_ text: String, in source: VaultPath, from old: VaultPath, to new: VaultPath, index: VaultIndex) -> String {
        let newTarget: String = {
            let others = index.notes.keys.filter { $0 != old && $0.title.lowercased() == new.title.lowercased() }
            return others.isEmpty ? new.title : String(new.rawValue.dropLast(3))
        }()
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            output += rest[..<open.upperBound]
            let inner = String(rest[open.upperBound..<close.lowerBound])
            if let link = MarkdownNote.wikiLinks(in: "[[" + inner + "]]").first, index.resolve(link.target, from: source) == old {
                var replaced = newTarget
                if let heading = link.heading { replaced += "#" + heading }
                if let alias = link.alias { replaced += "|" + alias }
                output += replaced
            } else {
                output += inner
            }
            output += "]]"
            rest = rest[close.upperBound...]
        }
        return output + rest
    }
}

/// Which top-level folders agents may read. Private by default: nothing is readable until you say so.
public struct VaultAccessPolicy: Codable, Equatable, Sendable {
    /// Top-level folder names agents may read. "/" stands for notes at the vault root.
    public var agentReadable: Set<String>
    public init(agentReadable: Set<String> = []) { self.agentReadable = agentReadable }
    public static let rootKey = "/"
    public func allowsAgents(_ path: VaultPath) -> Bool { agentReadable.contains(path.topFolder ?? Self.rootKey) }
}
