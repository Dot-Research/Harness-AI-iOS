import Foundation

/// Portable, user-owned style guidance. A size or encoding failure is always reported;
/// the caller decides how to explain it while leaving the user's original text intact.
public enum DictationInstructions {
    public static let fileName = "instruction.md"
    public static let maxUTF8Bytes = 8 * 1024
    public static let defaultText = """
    Keep my natural voice. Write clearly and concisely, using familiar words.
    Preserve my language, meaning and tone. Avoid canned phrases, inflated adjectives and invented content.
    """

    public enum ValidationError: LocalizedError, Equatable, Sendable {
        case tooLarge
        case invalidUTF8

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "instruction.md must be at most 8 KB of UTF-8 text. Your saved instructions are unchanged."
            case .invalidUTF8: return "instruction.md must be a UTF-8 Markdown file. Your saved instructions are unchanged."
            }
        }
    }

    public static func validate(_ text: String) throws {
        guard text.utf8.count <= maxUTF8Bytes else { throw ValidationError.tooLarge }
    }

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maxUTF8Bytes else { throw ValidationError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ValidationError.invalidUTF8 }
        return text
    }
}

/// Pure Foundation file storage, also usable by tests and portable tools.
/// The application and keyboard read the same file anew for every request.
public struct DictationInstructionFile: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent(DictationInstructions.fileName, isDirectory: false)
    }

    public func load() throws -> String {
        do {
            return try Self.read(fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return DictationInstructions.defaultText
        }
    }

    /// Reads one extra byte to detect oversize files without allocating arbitrary file sizes.
    /// No prefix is ever returned as a successful import.
    public static func read(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: DictationInstructions.maxUTF8Bytes + 1) ?? Data()
        return try DictationInstructions.decode(data)
    }

    public func save(_ text: String) throws {
        try DictationInstructions.validate(text)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Foundation writes a sibling temporary file and atomically replaces the destination.
        // Validation happens before any filesystem mutation, preserving the last good file.
        #if os(iOS)
        try Data(text.utf8).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        #endif
    }
}
