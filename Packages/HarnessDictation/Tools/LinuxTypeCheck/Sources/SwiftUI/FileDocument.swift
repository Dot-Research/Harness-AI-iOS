import Foundation
import UniformTypeIdentifiers

#if os(Linux)
// Foundation's FileWrapper is unavailable on Linux. Apple platforms use Foundation's real class.
public final class FileWrapper {
    public init(regularFileWithContents contents: Data) {}
    public var regularFileContents: Data? { fatalError() }
}
#endif

// Configurations deliberately expose the same concrete fields as SwiftUI's document API.
public struct FileDocumentReadConfiguration {
    public let contentType: UTType
    public let file: FileWrapper
}

public struct FileDocumentWriteConfiguration {
    public let contentType: UTType
    public let existingFile: FileWrapper?
}

@preconcurrency
public protocol FileDocument: Sendable {
    static var readableContentTypes: [UTType] { get }
    static var writableContentTypes: [UTType] { get }
    typealias ReadConfiguration = FileDocumentReadConfiguration
    init(configuration: ReadConfiguration) throws
    typealias WriteConfiguration = FileDocumentWriteConfiguration
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper
}

extension FileDocument {
    public static var writableContentTypes: [UTType] { readableContentTypes }
}

extension View {
    public func fileImporter(
        isPresented: Binding<Bool>,
        allowedContentTypes: [UTType],
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View { _Modified<Self>() }

    public func fileExporter<D: FileDocument>(
        isPresented: Binding<Bool>,
        document: D?,
        contentType: UTType,
        defaultFilename: String? = nil,
        onCompletion: @escaping (Result<URL, Error>) -> Void
    ) -> some View { _Modified<Self>() }
}
