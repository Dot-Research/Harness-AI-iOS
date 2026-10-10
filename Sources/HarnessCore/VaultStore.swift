import Foundation

public enum VaultError: Error, LocalizedError, Equatable, Sendable {
    case invalidName(String)
    case notFound(String)
    case alreadyExists(String)
    case tooLarge(String)
    /// The file changed on disk since it was read (another app, sync, or the Files app).
    case conflict(path: String, modified: Date)
    case privateNote(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): return "“\(name)” can't be used as a note or folder name."
        case .notFound(let path): return "\(path) is no longer in the vault."
        case .alreadyExists(let path): return "\(path) already exists."
        case .tooLarge(let path): return "\(path) is larger than 2 MB, so Harness won't open it."
        case .conflict(let path, _): return "\(path) changed outside Harness since you opened it."
        case .privateNote(let path): return "\(path) is in a private folder. Agents can only read folders you mark “Agents can read”."
        case .unsupported(let detail): return detail
        }
    }
}

public struct VaultDocument: Equatable, Sendable {
    public var path: VaultPath
    public var text: String
    public var modified: Date
}

/// What agents may do with the vault. Implemented by `VaultStore`; injected into `AgentRuntime`.
public protocol VaultReading: Sendable {
    func agentSearch(_ query: String, limit: Int) async throws -> [VaultSearchHit]
    func agentRead(_ reference: String) async throws -> VaultDocument
}

/// Plain Markdown files in a folder. Hidden entries (".obsidian", ".trash", ".harness") and symbolic
/// links are never listed, read or followed. Paths can't leave the vault.
public actor VaultStore: VaultReading {
    public static let maxNoteBytes = 2 * 1024 * 1024
    public static let maxNotes = 20_000
    static let policyFile = ".harness/vault.json"

    public private(set) var root: URL
    private var cache: [VaultPath: VaultNoteSummary] = [:]
    private let fileManager = FileManager.default

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Switches to another folder (for example one chosen in Files).
    public func open(root newRoot: URL) {
        root = newRoot.standardizedFileURL
        cache = [:]
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Listing and index

    /// Every non-hidden folder, sorted, including empty ones.
    public func folders() throws -> [VaultPath] {
        var result: [VaultPath] = []
        try walk { path, isDirectory in if isDirectory { result.append(path) } }
        return result.sorted()
    }

    /// Parses changed notes and returns the index. Unchanged files are reused from the last call.
    public func index() throws -> VaultIndex {
        var fresh: [VaultPath: VaultNoteSummary] = [:]
        try walk { path, isDirectory in
            guard !isDirectory, path.isNote, fresh.count < Self.maxNotes else { return }
            guard let fileURL = try? url(for: path), let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path) else { return }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if let cached = cache[path], cached.modified == modified, cached.size == size {
                fresh[path] = cached
                return
            }
            var text = ""
            if size <= Self.maxNoteBytes, let data = fileManager.contents(atPath: fileURL.path) {
                text = String(decoding: data, as: UTF8.self)
            }
            fresh[path] = VaultNoteSummary(path: path, modified: modified, size: size, note: MarkdownNote.parse(text, fallbackTitle: path.title))
        }
        cache = fresh
        return VaultIndex(notes: Array(fresh.values))
    }

    // MARK: Reading and writing

    public func read(_ path: VaultPath) throws -> VaultDocument {
        let target = try existingFile(path)
        let attributes = try fileManager.attributesOfItem(atPath: target.path)
        if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > Self.maxNoteBytes { throw VaultError.tooLarge(path.rawValue) }
        guard let data = fileManager.contents(atPath: target.path) else { throw VaultError.notFound(path.rawValue) }
        return VaultDocument(path: path, text: String(decoding: data, as: UTF8.self),
                             modified: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    /// Saves `text`. Pass the `modified` date you read; if the file changed since, nothing is written
    /// and `VaultError.conflict` carries the current date. Pass nil to overwrite unconditionally.
    @discardableResult
    public func write(_ path: VaultPath, text: String, expectedModified: Date?) throws -> Date {
        guard path.isNote else { throw VaultError.invalidName(path.name) }
        let data = Data(text.utf8)
        guard data.count <= Self.maxNoteBytes else { throw VaultError.tooLarge(path.rawValue) }
        let target = try url(for: path)
        if let expectedModified {
            let current = try existingFile(path)
            let modified = (try fileManager.attributesOfItem(atPath: current.path))[.modificationDate] as? Date ?? .distantPast
            if abs(modified.timeIntervalSince(expectedModified)) > 0.001 { throw VaultError.conflict(path: path.rawValue, modified: modified) }
        } else if isSymbolicLink(target) {
            throw VaultError.unsupported("Harness doesn't write through symbolic links.")
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return (try fileManager.attributesOfItem(atPath: target.path))[.modificationDate] as? Date ?? Date()
    }

    /// Creates a note with a unique name ("Untitled", "Untitled 1", ...) and returns its path.
    public func createNote(title: String, in folder: VaultPath? = nil, text: String = "") throws -> VaultPath {
        let base = try Self.sanitizedName(title.isEmpty ? "Untitled" : title)
        if let folder { try fileManager.createDirectory(at: try url(for: folder), withIntermediateDirectories: true) }
        let path = try uniquePath(base: base, in: folder)
        try write(path, text: text, expectedModified: nil)
        return path
    }

    public func createFolder(_ name: String, in parent: VaultPath? = nil) throws -> VaultPath {
        let clean = try Self.sanitizedName(name)
        guard let folderPath = Self.childPath(clean, in: parent) else { throw VaultError.invalidName(name) }
        let target = try url(for: folderPath)
        if fileManager.fileExists(atPath: target.path) { throw VaultError.alreadyExists(folderPath.rawValue) }
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        return folderPath
    }

    /// Renames a note and updates links to it in other notes. Returns the new path and how many
    /// notes were updated.
    public func rename(_ path: VaultPath, to newTitle: String) throws -> (path: VaultPath, updatedNotes: Int) {
        let clean = try Self.sanitizedName(newTitle)
        guard let destination = Self.childPath(clean + ".md", in: path.parent) else { throw VaultError.invalidName(newTitle) }
        return try relocate(path, to: destination)
    }

    /// Moves a note into `folder` (nil: the vault root), updating links that named its old location.
    public func move(_ path: VaultPath, to folder: VaultPath?) throws -> VaultPath {
        guard let target = Self.childPath(path.name, in: folder) else { throw VaultError.invalidName(path.name) }
        if let folder { try fileManager.createDirectory(at: try url(for: folder), withIntermediateDirectories: true) }
        return try relocate(path, to: target).path
    }

    /// Moves the note to the vault's `.trash` folder, where it can be recovered in Files.
    public func delete(_ path: VaultPath) throws {
        let source = try existingFile(path)
        let trash = root.appendingPathComponent(".trash", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        try fileManager.moveItem(at: source, to: trash.appendingPathComponent("\(stamp) \(path.name)"))
        cache[path] = nil
    }

    /// Today's note in `folder` ("Daily/2026-10-09.md"), created empty if it doesn't exist.
    public func dailyNote(for date: Date = Date(), folder: String = "Daily", calendar: Calendar = .current) throws -> VaultPath {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "%04d-%02d-%02d.md", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard let dailyFolder = VaultPath(folder), let path = dailyFolder.appending(name) else { throw VaultError.invalidName(folder) }
        if !fileManager.fileExists(atPath: try url(for: path).path) {
            try write(path, text: "", expectedModified: nil)
        }
        return path
    }

    // MARK: Agent access

    public func accessPolicy() -> VaultAccessPolicy {
        guard let data = fileManager.contents(atPath: root.appendingPathComponent(Self.policyFile).path),
              let policy = try? JSONDecoder().decode(VaultAccessPolicy.self, from: data) else { return VaultAccessPolicy() }
        return policy
    }

    /// Marks a top-level folder ("/" for notes at the root) readable by agents, or private.
    public func setAgentAccess(_ folder: String, readable: Bool) throws {
        var policy = accessPolicy()
        if readable { policy.agentReadable.insert(folder) } else { policy.agentReadable.remove(folder) }
        let target = root.appendingPathComponent(Self.policyFile)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: target, options: .atomic)
    }

    public func agentSearch(_ query: String, limit: Int) throws -> [VaultSearchHit] {
        let policy = accessPolicy()
        return try index().search(query, limit: limit, where: policy.allowsAgents)
    }

    /// `reference` is a vault path ("Projects/Roadmap.md") or a note name ("Roadmap").
    public func agentRead(_ reference: String) throws -> VaultDocument {
        let index = try index()
        guard let path = VaultPath(reference).flatMap({ index.notes[$0] != nil ? $0 : nil }) ?? index.resolve(reference) else {
            throw VaultError.notFound(reference)
        }
        guard accessPolicy().allowsAgents(path) else { throw VaultError.privateNote(path.rawValue) }
        return try read(path)
    }

    // MARK: Helpers

    /// Characters Obsidian and the common file systems reject in names, plus link syntax.
    public static func sanitizedName(_ name: String) throws -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.controlCharacters).union(.newlines)
        var clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { !banned.contains($0) }))
        clean = clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if clean.lowercased().hasSuffix(".md") { clean = String(clean.dropLast(3)).trimmingCharacters(in: .whitespaces) }
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = String(clean.prefix(120)).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, VaultPath(clean) != nil else { throw VaultError.invalidName(name) }
        return clean
    }

    static func childPath(_ name: String, in parent: VaultPath?) -> VaultPath? {
        guard let parent else { return VaultPath(name) }
        return parent.appending(name)
    }

    private func relocate(_ path: VaultPath, to destination: VaultPath) throws -> (path: VaultPath, updatedNotes: Int) {
        let source = try existingFile(path)
        if destination == path { return (path, 0) }
        let target = try url(for: destination)
        // Case-only renames are the same file on case-insensitive file systems.
        if destination.rawValue.lowercased() != path.rawValue.lowercased(), fileManager.fileExists(atPath: target.path) {
            throw VaultError.alreadyExists(destination.rawValue)
        }
        let before = try index()
        try fileManager.moveItem(at: source, to: target)
        var updated = 0
        for (otherPath, summary) in before.notes where otherPath != path && summary.note.links.contains(where: { before.resolve($0.target, from: otherPath) == path }) {
            let document = try read(otherPath)
            let rewritten = VaultLinkRewriter.rewrite(document.text, in: otherPath, from: path, to: destination, index: before)
            if rewritten != document.text {
                try write(otherPath, text: rewritten, expectedModified: document.modified)
                updated += 1
            }
        }
        cache[path] = nil
        return (destination, updated)
    }

    private func uniquePath(base: String, in folder: VaultPath?) throws -> VaultPath {
        for attempt in 0..<1000 {
            let name = attempt == 0 ? "\(base).md" : "\(base) \(attempt).md"
            guard let path = Self.childPath(name, in: folder) else { throw VaultError.invalidName(base) }
            if !fileManager.fileExists(atPath: try url(for: path).path) { return path }
        }
        throw VaultError.alreadyExists(base)
    }

    /// The file URL for `path`, guaranteed to be inside the vault.
    private func url(for path: VaultPath) throws -> URL {
        let target = path.components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard target.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { throw VaultError.invalidName(path.rawValue) }
        return target
    }

    /// The URL of an existing regular file (not a symbolic link) at `path`.
    private func existingFile(_ path: VaultPath) throws -> URL {
        let target = try url(for: path)
        guard let attributes = try? fileManager.attributesOfItem(atPath: target.path) else { throw VaultError.notFound(path.rawValue) }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw VaultError.unsupported("\(path.rawValue) isn't a regular file, so Harness won't open it.")
        }
        return target
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Visits every non-hidden file and folder, depth first, without following symbolic links.
    private func walk(_ visit: (VaultPath, Bool) throws -> Void) throws {
        var pending: [(URL, String)] = [(root, "")]
        var visited = 0
        while let next = pending.popLast() {
            let (directory, prefix) = next
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                visited += 1
                if visited > Self.maxNotes * 4 { return }
                let child = directory.appendingPathComponent(name)
                guard let path = VaultPath(prefix.isEmpty ? name : prefix + "/" + name),
                      let attributes = try? fileManager.attributesOfItem(atPath: child.path) else { continue }
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory?:
                    try visit(path, true)
                    pending.append((child, path.rawValue))
                case .typeRegular?:
                    try visit(path, false)
                default:
                    continue // symbolic links, sockets, devices
                }
            }
        }
    }
}
