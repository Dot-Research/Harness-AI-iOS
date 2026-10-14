#if os(iOS)
import Foundation
import DictationCore

/// Speak's style file is durable user content, separate from transient bridge files.
public final class DictationInstructionsStore {
    private let file: DictationInstructionFile?
    public var fileURL: URL? { file?.fileURL }

    public init(group: AppGroupConfiguration) {
        file = group.containerURL.map { DictationInstructionFile(directory: $0.appendingPathComponent("Speak", isDirectory: true)) }
    }

    public func load() throws -> String {
        guard let file else { throw storageUnavailable }
        return try file.load()
    }

    public func save(_ text: String) throws {
        guard let file else { throw storageUnavailable }
        try file.save(text)
    }

    private var storageUnavailable: BridgeError {
        BridgeError(.internalFailure, "Speak couldn't access the shared instruction.md file. Open Harness and check keyboard setup.")
    }
}
#endif
