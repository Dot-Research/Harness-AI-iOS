import XCTest
@testable import HarnessCore

/// Run through social_service.test_swift_client to exercise real HTTP and SQLite together.
final class SocialClientIntegrationTests: XCTestCase {
    func testClientRoundTripAgainstPersistedService() async throws {
        guard let address = ProcessInfo.processInfo.environment["HARNESS_SOCIAL_TEST_URL"] else {
            throw XCTSkip("Start the isolated Python fixture through python3 -m social_service.test_swift_client.")
        }
        let service = try SocialServiceURL(address, allowLoopbackHTTP: true)
        let anonymous = SocialClient(service: service)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        let aliceSession = try await anonymous.signIn(handle: "alice_" + suffix, password: "a long test password", displayName: "Alice")
        let bobSession = try await anonymous.signIn(handle: "bob_" + suffix, password: "a long test password", displayName: "Bob")
        let alice = SocialClient(service: service, token: aliceSession.token)
        let bob = SocialClient(service: service, token: bobSession.token)
        let me = try await alice.me()
        XCTAssertEqual(me.id, aliceSession.profile.id)
        let draft = SocialDraft(text: "A persisted thought: 你好 👋")
        let original = try await alice.publish(draft)
        let retried = try await alice.publish(draft)
        XCTAssertEqual(original.id, retried.id)
        XCTAssertEqual(original.text, draft.text)
        let reply = try await bob.publish(SocialDraft(text: "A real reply", parentID: original.id))
        let thread = try await alice.thread(original.id)
        XCTAssertEqual(thread.replies.map(\.id), [reply.id])
        XCTAssertEqual(thread.post.replyCount, 1)
        let liked = try await bob.setLike(original.id, enabled: true)
        XCTAssertEqual(liked.likeCount, 1)
        XCTAssertTrue(liked.liked)
        let reposted = try await bob.setRepost(original.id, enabled: true)
        XCTAssertEqual(reposted.repostCount, 1)
        let followed = try await bob.setFollow(me.handle, enabled: true)
        XCTAssertTrue(followed.following)
        let following = try await bob.feed(.following)
        XCTAssertEqual(following.items.first?.post.id, original.id)
        let muted = try await bob.setMute(me.handle, enabled: true)
        XCTAssertTrue(muted.muted)
        let feed = try await bob.feed(.all)
        XCTAssertFalse(feed.items.contains { $0.post.id == original.id })
        let profile = try await bob.profile("@" + me.handle)
        XCTAssertEqual(profile.posts.first?.id, original.id)
        do {
            _ = try await bob.delete(original.id)
            XCTFail("Another user must not delete the author's post.")
        } catch let error as SocialError { XCTAssertEqual(error.status, 403) }
        let removed = try await alice.delete(original.id)
        XCTAssertTrue(removed.deleted)
        let preserved = try await bob.thread(original.id)
        XCTAssertEqual(preserved.replies.first?.text, "A real reply")
        try await bob.signOut()
        do {
            _ = try await bob.me()
            XCTFail("Revoked sessions must stop working.")
        } catch let error as SocialError { XCTAssertEqual(error.status, 401) }
    }

    func testBearerSessionNeverFollowsHTTPRedirect() async throws {
        guard let address = ProcessInfo.processInfo.environment["HARNESS_SOCIAL_TEST_URL"] else {
            throw XCTSkip("Requires the Python integration fixture.")
        }
        let service = try SocialServiceURL(address, allowLoopbackHTTP: true)
        let client = SocialClient(service: service, token: "redirect-probe")
        do {
            _ = try await client.me()
            XCTFail("Redirects from a credentialed Social request must be rejected.")
        } catch let error as SocialError { XCTAssertEqual(error.status, 302) }
    }
}
