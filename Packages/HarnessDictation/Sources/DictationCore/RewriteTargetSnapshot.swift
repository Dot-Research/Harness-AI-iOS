import Foundation

/// The host document and visible cursor context captured before an asynchronous rewrite.
public struct RewriteTargetSnapshot: Equatable, Sendable {
    public let documentIdentifier: UUID
    public let before: String?
    public let after: String?
    public let selectedText: String?

    public init(documentIdentifier: UUID, before: String?, after: String?, selectedText: String?) {
        self.documentIdentifier = documentIdentifier
        self.before = before
        self.after = after
        self.selectedText = selectedText
    }

    /// A matching suffix or selection alone is insufficient: it may belong to another field
    /// or cursor position. Keep unavailable context distinct from an empty context.
    public func matches(_ current: RewriteTargetSnapshot) -> Bool {
        self == current
    }
}
