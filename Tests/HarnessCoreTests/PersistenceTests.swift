import XCTest
@testable import HarnessCore

final class PersistenceTests: XCTestCase {
    func testReopenPersistsSessionLearningAndUnicodeFilesTogether() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("harness.sqlite")
        let store = try SQLiteHarnessStore(url: url)
        let session = AgentSession(title: "Plan", messages: [AgentMessage(role: .user, content: "Privacy first — 私の記憶")])
        let proposal = LearningProposal(target: .user, title: "Preference", evidence: "User request", before: "", after: "Prefer local models.")
        try await store.update {
            $0.sessions = [session]; $0.proposals = [proposal]
            $0.files[AgentFile.user.rawValue] = "# User\nPrivacy first."
            $0.learningMode = .ask
        }
        let reopened = try SQLiteHarnessStore(url: url)
        let state = try await reopened.load()
        XCTAssertEqual(state.sessions, [session]); XCTAssertEqual(state.proposals, [proposal])
        XCTAssertEqual(state.files["USER.md"], "# User\nPrivacy first.")
        XCTAssertEqual(state.learningMode, .ask)
    }
    func testConcurrentUpdatesDoNotLoseAuditEvents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SQLiteHarnessStore(url: folder.appendingPathComponent("harness.sqlite"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 { group.addTask { try await store.update { $0.activity.append(ActivityEntry(title: "Event \(index)")) } } }
            try await group.waitForAll()
        }
        let state = try await store.load()
        XCTAssertEqual(state.activity.count, 20)
        XCTAssertEqual(Set(state.activity.map(\.title)).count, 20)
    }
    func testRepeatedUpdatesReplaceCollectionsWithoutDuplication() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("harness.sqlite")
        let store = try SQLiteHarnessStore(url: url)
        let session = AgentSession(title: "First")
        try await store.update { $0.sessions = [session] }
        try await store.update { $0.sessions[0].title = "Renamed"; $0.activity = [ActivityEntry(title: "Renamed")] }
        let reopened = try SQLiteHarnessStore(url: url)
        let state = try await reopened.load()
        XCTAssertEqual(state.sessions.count, 1); XCTAssertEqual(state.sessions[0].title, "Renamed")
        XCTAssertEqual(state.activity.count, 1)
    }
    func testConstraintFailureRollsBackWholeUpdate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("harness.sqlite")
        let store = try SQLiteHarnessStore(url: url)
        let session = AgentSession(title: "Preserved")
        try await store.update { $0.sessions = [session]; $0.files["USER.md"] = "Original" }
        do {
            try await store.update { $0.sessions = [session, session]; $0.files["USER.md"] = "Must roll back" }
            XCTFail("Duplicate primary key should reject the transaction")
        } catch { }
        let reopened = try SQLiteHarnessStore(url: url)
        let state = try await reopened.load()
        XCTAssertEqual(state.sessions, [session]); XCTAssertEqual(state.files["USER.md"], "Original")
        let cached = try await store.load()
        XCTAssertEqual(cached.files["USER.md"], "Original")
    }
}
