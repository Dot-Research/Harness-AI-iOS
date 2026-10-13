// Concrete subset of UniformTypeIdentifiers used by the instruction file editor.
public struct UTType: Hashable, Sendable {
    public let identifier: String

    public init(importedAs identifier: String, conformingTo parentType: UTType? = nil) {
        self.identifier = identifier
    }

    public static let plainText = UTType(importedAs: "public.plain-text")
}
