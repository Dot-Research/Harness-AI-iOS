import XCTest
@testable import HarnessCore

final class SocialTests: XCTestCase {
    func testServiceURLRequiresHTTPSOriginWithoutCredentials() throws {
        XCTAssertEqual(try SocialServiceURL("https://social.example/").url.absoluteString, "https://social.example")
        for url in ["http://social.example", "https://user:pass@social.example", "https://social.example/v1", "https://social.example?q=x", "https://social.example#x"] {
            XCTAssertThrowsError(try SocialServiceURL(url), url)
        }
        XCTAssertThrowsError(try SocialServiceURL("http://127.0.0.1:8790"))
        XCTAssertNoThrow(try SocialServiceURL("http://127.0.0.1:8790", allowLoopbackHTTP: true))
        XCTAssertThrowsError(try SocialServiceURL("http://192.168.1.1", allowLoopbackHTTP: true))
    }

    func testDraftKeepsRetryKeyAcrossPersistenceAndChangesKeyWhenEdited() throws {
        var draft = SocialDraft(text: "A thought", parentID: "parent")
        let original = draft.idempotencyKey
        let restored = try JSONDecoder().decode(SocialDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.idempotencyKey, original)
        XCTAssertEqual(restored.parentID, "parent")
        draft.updateText("A thought")
        XCTAssertEqual(draft.idempotencyKey, original)
        draft.updateText("A revised thought")
        XCTAssertNotEqual(draft.idempotencyKey, original)
        XCTAssertTrue(draft.canPublish)
        draft.updateText(" \n")
        XCTAssertFalse(draft.canPublish)
        draft.updateText(String(repeating: "x", count: 501))
        XCTAssertFalse(draft.canPublish)
    }

    func testPublishAcknowledgementNeverErasesNewerDraft() throws {
        var archive = SocialDraftArchive()
        archive.update("First", scope: "alice", parentID: nil)
        let submitted = archive.draft(scope: "alice", parentID: nil)
        archive.update("An edit while the request is in flight", scope: "alice", parentID: nil)
        archive.acknowledge(scope: "alice", idempotencyKey: submitted.idempotencyKey)
        XCTAssertEqual(archive.draft(scope: "alice", parentID: nil).text, "An edit while the request is in flight")
        let newer = archive.draft(scope: "alice", parentID: nil)
        let restored = try JSONDecoder().decode(SocialDraftArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(restored.draft(scope: "alice", parentID: nil), newer)
        XCTAssertEqual(restored.draft(scope: "bob", parentID: nil).text, "")
        archive.acknowledge(scope: "alice", idempotencyKey: newer.idempotencyKey)
        XCTAssertEqual(archive.draft(scope: "alice", parentID: nil).text, "")
    }

    func testDraftScopesSeparateServicesAccountsAndReplies() {
        let a = SocialDraft.scope(service: "https://one.example", account: "alice", parentID: nil)
        XCTAssertNotEqual(a, SocialDraft.scope(service: "https://two.example", account: "alice", parentID: nil))
        XCTAssertNotEqual(a, SocialDraft.scope(service: "https://one.example", account: "bob", parentID: nil))
        XCTAssertNotEqual(a, SocialDraft.scope(service: "https://one.example", account: "alice", parentID: "reply"))
    }
}
