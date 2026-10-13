import Foundation
import XCTest
@testable import DictationCore

final class RewriteTargetSnapshotTests: XCTestCase {
    private let documentID = UUID(uuidString: "118840CD-8660-4FC2-8BEF-8D343C14603A")!
    private let otherDocumentID = UUID(uuidString: "81F403C3-8DF6-409C-B8F3-CE9CDA3EE9B1")!

    func testAcceptsUnchangedSelectionAndSurroundingText() {
        let captured = snapshot(before: "Hello ", after: ", see you soon.", selectedText: "Mimi")
        let current = snapshot(before: "Hello ", after: ", see you soon.", selectedText: "Mimi")

        XCTAssertTrue(captured.matches(current))
    }

    func testAcceptsUnchangedParagraphAtCursor() {
        let captured = snapshot(before: "Earlier paragraph.\nRewrite this.", after: " Next sentence.")
        let current = snapshot(before: "Earlier paragraph.\nRewrite this.", after: " Next sentence.")

        XCTAssertTrue(captured.matches(current))
    }

    func testRejectsIdenticalSelectionInDifferentDocument() {
        let captured = snapshot(before: "Hello ", after: ".", selectedText: "Mimi")
        let current = snapshot(documentIdentifier: otherDocumentID, before: "Hello ", after: ".", selectedText: "Mimi")

        XCTAssertFalse(captured.matches(current))
    }

    func testRejectsChangedContextEvenWhenParagraphSuffixStillMatches() {
        let captured = snapshot(before: "First paragraph.\nRewrite this.", after: "")
        let current = snapshot(before: "Another paragraph.\nRewrite this.", after: "")

        XCTAssertFalse(captured.matches(current))
    }

    func testRejectsChangedTextAfterCursor() {
        let captured = snapshot(before: "Rewrite this.", after: " Old text.")
        let current = snapshot(before: "Rewrite this.", after: " New text.")

        XCTAssertFalse(captured.matches(current))
    }

    func testRejectsChangedSelectionWithUnchangedSurroundingText() {
        let captured = snapshot(before: "Hello ", after: ".", selectedText: "Mimi")
        let current = snapshot(before: "Hello ", after: ".", selectedText: "Theodore")

        XCTAssertFalse(captured.matches(current))
    }

    func testRejectsSelectionRemovedWhileRewriteIsPending() {
        let captured = snapshot(before: "Hello ", after: ".", selectedText: "Mimi")
        let current = snapshot(before: "Hello ", after: ".")

        XCTAssertFalse(captured.matches(current))
    }

    func testRejectsSelectionAddedToParagraphTarget() {
        let captured = snapshot(before: "Rewrite this.", after: "")
        let current = snapshot(before: "Rewrite this.", after: "", selectedText: "Another target")

        XCTAssertFalse(captured.matches(current))
    }

    func testRejectsPreviouslyUnavailableContextBecomingAvailable() {
        let captured = snapshot(before: "Hello ", after: nil, selectedText: "Mimi")
        let current = snapshot(before: "Hello ", after: "", selectedText: "Mimi")

        XCTAssertFalse(captured.matches(current))
    }

    private func snapshot(
        documentIdentifier: UUID? = nil,
        before: String?,
        after: String?,
        selectedText: String? = nil
    ) -> RewriteTargetSnapshot {
        RewriteTargetSnapshot(
            documentIdentifier: documentIdentifier ?? documentID,
            before: before,
            after: after,
            selectedText: selectedText
        )
    }
}
