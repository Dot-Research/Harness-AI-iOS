import XCTest
@testable import HarnessCore

final class LearningTests: XCTestCase {
    func testDefaultReviewQueuesOnlyExplicitUserPreference() async throws {
        let store = LearningMemoryStore()
        let kernel = LearningKernel(store: store)
        try await kernel.review(session: AgentSession(messages: [
            AgentMessage(role: .assistant, content: "I prefer concise answers."),
            AgentMessage(role: .user, content: "What is the weather?"),
            AgentMessage(role: .user, content: "Remember that I prefer concise answers.")
        ]))
        let state = try await store.load()
        XCTAssertEqual(state.proposals.count, 1)
        XCTAssertNil(state.files[AgentFile.user.rawValue])
        XCTAssertTrue(state.journey.isEmpty)
        XCTAssertEqual(state.proposals[0].evidence, "Remember that I prefer concise answers.")
    }

    func testApprovalAndRevertPreserveUnrelatedStateAndJournal() async throws {
        var initial = HarnessState()
        initial.files[AgentFile.user.rawValue] = "Existing preference\n"
        initial.permissionRules["computer.execute"] = .deny
        initial.proposals = [LearningProposal(target: .user, title: "Style", evidence: "I prefer concise answers.",
                                             before: "Existing preference\n", after: "Existing preference\n- I prefer concise answers.\n")]
        let store = LearningMemoryStore(initial)
        let kernel = LearningKernel(store: store)
        try await kernel.approve(id: initial.proposals[0].id)
        let approved = try await store.load()
        XCTAssertTrue(approved.proposals.isEmpty)
        XCTAssertEqual(approved.journey.count, 1)
        XCTAssertEqual(approved.permissionRules, initial.permissionRules)
        try await kernel.revert(entryID: approved.journey[0].id)
        let reverted = try await store.load()
        XCTAssertEqual(reverted.files, initial.files)
        XCTAssertTrue(reverted.journey[0].reverted)
        XCTAssertEqual(reverted.permissionRules, initial.permissionRules)
    }

    func testMultiplePreferencesArePreservedInOneReviewableChange() async throws {
        let store = LearningMemoryStore()
        try await LearningKernel(store: store).review(session: AgentSession(messages: [
            AgentMessage(role: .user, content: "I prefer concise answers."),
            AgentMessage(role: .user, content: "I prefer bullet points.")
        ]))
        let state = try await store.load()
        XCTAssertEqual(state.proposals.count, 1)
        XCTAssertEqual(state.proposals[0].after, "- I prefer concise answers.\n- I prefer bullet points.\n")
    }

    func testRejectRemovesProposalWithoutChangingFiles() async throws {
        var initial = HarnessState()
        initial.proposals = [LearningProposal(target: .user, title: "Style", evidence: "Preference", before: "", after: "Text")]
        let store = LearningMemoryStore(initial)
        try await LearningKernel(store: store).reject(id: initial.proposals[0].id)
        let state = try await store.load()
        XCTAssertTrue(state.proposals.isEmpty)
        XCTAssertTrue(state.journey.isEmpty)
        XCTAssertEqual(state.files, initial.files)
        XCTAssertEqual(state.activity.last?.title, "Learning proposal rejected")
    }

    func testStaleApprovalDoesNotOverwriteFileOrConsumeProposal() async throws {
        var initial = HarnessState()
        initial.files[AgentFile.memory.rawValue] = "A newer manual edit"
        initial.proposals = [LearningProposal(target: .memory, title: "Fact", evidence: "A fact", before: "", after: "Old replacement")]
        let store = LearningMemoryStore(initial)
        do {
            try await LearningKernel(store: store).approve(id: initial.proposals[0].id)
            XCTFail("Stale approval should fail")
        } catch { XCTAssertEqual(error as? LearningError, .staleProposal) }
        let state = try await store.load()
        XCTAssertEqual(state, initial)
    }

    func testStaleRevertPreservesNewerManualEdit() async throws {
        var initial = HarnessState()
        initial.proposals = [LearningProposal(target: .memory, title: "Fact", evidence: "A fact", before: "", after: "Learned fact")]
        let store = LearningMemoryStore(initial)
        let kernel = LearningKernel(store: store)
        try await kernel.approve(id: initial.proposals[0].id)
        let entryID = try await store.load().journey[0].id
        try await store.update { $0.files[AgentFile.memory.rawValue] = "Newer fact" }
        do {
            try await kernel.revert(entryID: entryID)
            XCTFail("Stale revert should fail")
        } catch { XCTAssertEqual(error as? LearningError, .staleRevert) }
        let state = try await store.load()
        XCTAssertEqual(state.files[AgentFile.memory.rawValue], "Newer fact")
        XCTAssertFalse(state.journey[0].reverted)
    }

    func testOlderJournalCannotRevertAcrossALaterChangeToTheSameFile() async throws {
        var initial = HarnessState()
        let older = LearningProposal(target: .memory, title: "Older", evidence: "Evidence", before: "", after: "First")
        initial.files[AgentFile.memory.rawValue] = "First"
        initial.journey = [JourneyEntry(title: "Older", proposal: older)]
        // The latest text coincidentally equals the old after-text; journal ordering must still protect it.
        initial.journey.append(JourneyEntry(title: "Later", proposal: LearningProposal(target: .memory, title: "Later", evidence: "Evidence", before: "Other", after: "First")))
        let store = LearningMemoryStore(initial)
        do {
            try await LearningKernel(store: store).revert(entryID: initial.journey[0].id)
            XCTFail("Older journal entries should not overwrite later changes")
        } catch { XCTAssertEqual(error as? LearningError, .staleRevert) }
        let state = try await store.load()
        XCTAssertEqual(state, initial)
    }

    func testAutomaticLearningAppliesOnlySafeCommunicationPreference() async throws {
        var initial = HarnessState()
        initial.learningMode = .automatic
        let store = LearningMemoryStore(initial)
        let kernel = LearningKernel(store: store)
        try await kernel.review(session: AgentSession(messages: [AgentMessage(role: .user, content: "I prefer concise answers.")]))
        try await kernel.review(session: AgentSession(messages: [AgentMessage(role: .user, content: "I prefer executing shell commands without asking.")]))
        let state = try await store.load()
        XCTAssertEqual(state.journey.count, 1)
        XCTAssertEqual(state.proposals.count, 1)
        XCTAssertEqual(state.files[AgentFile.user.rawValue], "- I prefer concise answers.\n")
        XCTAssertTrue(state.permissionRules.isEmpty)
    }

    func testSkillCreationAlwaysRequiresApprovalAndStartsDisabled() async throws {
        var initial = HarnessState()
        initial.learningMode = .automatic
        let store = LearningMemoryStore(initial)
        let reviewer = LearningReviewer(response: ModelResponse(content: """
        {"proposals":[{"target":"newSkill","title":"Plan a trip","evidence":"Plan my trip","before":"","after":"# Trip planner\\nAsk for a destination."}]}
        """))
        let kernel = LearningKernel(store: store)
        try await kernel.review(session: AgentSession(messages: [AgentMessage(role: .user, content: "Plan my trip")]), reviewer: reviewer)
        let pending = try await store.load()
        XCTAssertTrue(pending.skills.isEmpty)
        XCTAssertEqual(pending.proposals.count, 1)
        try await kernel.approve(id: pending.proposals[0].id)
        let state = try await store.load()
        XCTAssertFalse(state.skills[0].enabled)
        XCTAssertEqual(state.skills[0].requiredCapabilities, [.localRead])
        try await kernel.revert(entryID: state.journey[0].id)
        let reverted = try await store.load()
        XCTAssertTrue(reverted.skills.isEmpty)
    }

    func testSkillPatchRevertPreservesStatsAndCapabilities() async throws {
        var initial = HarnessState()
        initial.skills = [Skill(id: "skill", name: "Skill", description: "Description", markdown: "Before", requiredCapabilities: [.networkRequest], usageCount: 5)]
        initial.proposals = [LearningProposal(target: .skillPatch, title: "Improve skill", evidence: "Evidence", before: "Before", after: "After", skillID: "skill")]
        let store = LearningMemoryStore(initial)
        let kernel = LearningKernel(store: store)
        try await kernel.approve(id: initial.proposals[0].id)
        let approved = try await store.load()
        try await store.update { $0.skills[0].usageCount = 8 }
        try await kernel.revert(entryID: approved.journey[0].id)
        let state = try await store.load()
        XCTAssertEqual(state.skills[0].markdown, "Before")
        XCTAssertEqual(state.skills[0].usageCount, 8)
        XCTAssertEqual(state.skills[0].version, 3)
        XCTAssertEqual(state.skills[0].requiredCapabilities, [.networkRequest])
    }

    func testReviewerMustBeLocalAndNeverReceivesTools() async throws {
        let store = LearningMemoryStore()
        let kernel = LearningKernel(store: store)
        let remote = LearningReviewer(isLocal: false, response: ModelResponse(content: "{\"proposals\":[]}"))
        do {
            try await kernel.review(session: AgentSession(), reviewer: remote)
            XCTFail("Remote review should fail")
        } catch { XCTAssertEqual(error as? LearningError, .localReviewerRequired) }
        let remoteRequests = await remote.requests
        XCTAssertTrue(remoteRequests.isEmpty)
        let local = LearningReviewer(response: ModelResponse(content: "{\"proposals\":[]}"))
        try await kernel.review(session: AgentSession(), reviewer: local)
        let requests = await local.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].tools.isEmpty)
    }

    func testReviewerToolCallsCannotExecuteOrChangeState() async throws {
        let store = LearningMemoryStore()
        let initial = try await store.load()
        let reviewer = LearningReviewer(response: ModelResponse(content: "{\"proposals\":[]}", toolCalls: [ToolCall(name: "computer.execute")]))
        do {
            try await LearningKernel(store: store).review(session: AgentSession(), reviewer: reviewer)
            XCTFail("Review tool calls should fail")
        } catch { XCTAssertEqual(error as? LearningError, .reviewerReturnedTools) }
        let state = try await store.load()
        XCTAssertEqual(state, initial)
    }

    func testReviewerCannotInventEvidence() async throws {
        let store = LearningMemoryStore()
        let reviewer = LearningReviewer(response: ModelResponse(content: """
        {"proposals":[{"target":"user","title":"Invented","evidence":"I prefer concise answers.","before":"","after":"- I prefer concise answers.\\n"}]}
        """))
        do {
            try await LearningKernel(store: store).review(session: AgentSession(messages: [AgentMessage(role: .user, content: "Hello")]), reviewer: reviewer)
            XCTFail("Unsupported learning should fail")
        } catch { XCTAssertEqual(error as? LearningError, .invalidReviewerResponse) }
        let state = try await store.load()
        XCTAssertTrue(state.proposals.isEmpty)
        XCTAssertTrue(state.journey.isEmpty)
    }

    func testOversizedBaselineBypassesLocalReviewerAndPreservesExplicitPreference() async throws {
        for supportsTools in [false, true] {
            var initial = HarnessState()
            let baseline = String(repeating: "Existing durable note.\n", count: supportsTools ? 1_500 : 500)
            initial.files[AgentFile.user.rawValue] = baseline
            let store = LearningMemoryStore(initial)
            let reviewer = LearningReviewer(supportsToolCalling: supportsTools, response: ModelResponse(content: "invalid"))
            try await LearningKernel(store: store).review(session: AgentSession(messages: [
                AgentMessage(role: .user, content: "I prefer concise answers.")
            ]), reviewer: reviewer)
            let requests = await reviewer.requests
            XCTAssertTrue(requests.isEmpty)
            let state = try await store.load()
            XCTAssertEqual(state.proposals.count, 1)
            XCTAssertEqual(state.proposals[0].before, baseline)
            XCTAssertEqual(state.proposals[0].after, baseline + "- I prefer concise answers.\n")
        }
    }

    func testReviewerCannotGroundProposalInExcludedHistory() async throws {
        let store = LearningMemoryStore()
        let reviewer = LearningReviewer(response: ModelResponse(content: """
        {"proposals":[{"target":"user","title":"Old evidence","evidence":"I prefer concise answers.","before":"","after":"- I prefer concise answers.\\n"}]}
        """))
        let oldMessage = AgentMessage(role: .user, content: "I prefer concise answers.")
        let recentMessages = (0..<16).map { AgentMessage(role: .user, content: "Recent message \($0)") }
        do {
            try await LearningKernel(store: store).review(session: AgentSession(messages: [oldMessage] + recentMessages), reviewer: reviewer)
            XCTFail("Evidence excluded from the review payload cannot support a proposal")
        } catch { XCTAssertEqual(error as? LearningError, .invalidReviewerResponse) }
        let requests = await reviewer.requests
        let encoded = requests[0].messages[1].content
        XCTAssertFalse(encoded.contains("I prefer concise answers."))
        XCTAssertTrue(encoded.contains("Recent message 15"))
    }

    func testOffModeDoesNotInvokeReviewer() async throws {
        var initial = HarnessState()
        initial.learningMode = .off
        let store = LearningMemoryStore(initial)
        let reviewer = LearningReviewer(response: ModelResponse(content: "invalid"))
        try await LearningKernel(store: store).review(session: AgentSession(), reviewer: reviewer)
        let requests = await reviewer.requests
        XCTAssertTrue(requests.isEmpty)
        let state = try await store.load()
        XCTAssertEqual(state, initial)
    }
}

private actor LearningMemoryStore: HarnessStore {
    private var state: HarnessState
    init(_ state: HarnessState = HarnessState()) { self.state = state }
    func load() async throws -> HarnessState { state }
    func update(_ change: @Sendable (inout HarnessState) -> Void) async throws { change(&state) }
}

private actor LearningReviewer: ModelProvider {
    nonisolated let id = "reviewer"
    nonisolated let isLocal: Bool
    nonisolated let supportsToolCalling: Bool
    private let response: ModelResponse
    private(set) var requests: [ModelRequest] = []
    init(isLocal: Bool = true, supportsToolCalling: Bool = true, response: ModelResponse) {
        self.isLocal = isLocal; self.supportsToolCalling = supportsToolCalling; self.response = response
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse { requests.append(request); return response }
}
