import XCTest
@testable import HarnessCore

actor SequenceModel: ModelProvider {
    nonisolated let id: String
    nonisolated let isLocal: Bool
    nonisolated let supportsToolCalling: Bool
    var responses: [ModelResponse]
    var requests: [ModelRequest] = []
    private let onComplete: (@Sendable (ModelRequest) async -> Void)?
    init(id: String = "test-local", local: Bool = true, tools: Bool = true, responses: [ModelResponse], onComplete: (@Sendable (ModelRequest) async -> Void)? = nil) {
        self.id = id; self.isLocal = local; supportsToolCalling = tools; self.responses = responses
        self.onComplete = onComplete
    }
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        requests.append(request)
        await onComplete?(request)
        guard !responses.isEmpty else { throw RuntimeError.noProvider }
        return responses.removeFirst()
    }
    func captured() -> [ModelRequest] { requests }
}
actor RecordingExecutor: ExternalToolExecutor {
    var calls: [ToolCall] = []
    func execute(_ call: ToolCall, device: PairedDevice) async throws -> String { calls.append(call); return "Actual computer result" }
    func count() -> Int { calls.count }
}
actor WaitingModel: ModelProvider {
    nonisolated let id = "waiting"
    nonisolated let isLocal = true
    var started = false
    func complete(_ request: ModelRequest) async throws -> ModelResponse { started = true; try await Task.sleep(nanoseconds: 5_000_000_000); return ModelResponse(content: "Finished") }
    func hasStarted() -> Bool { started }
}

final class RuntimeTests: XCTestCase {
    private func state() -> HarnessState { var state = HarnessSeed.makeState(); state.learningMode = .off; return state }
    private let allow: PermissionHandler = { _, _ in .allowOnce }

    func testRealSequentialToolLoopLazySkillLoadingAndSessionResume() async throws {
        var initial = state()
        initial.files["MEMORY.md"] = "# MEMORY\nThe garden computer runs Linux."
        let store = RuntimeTestStore(initial)
        let provider = SequenceModel(responses: [
            ModelResponse(content: "I'll inspect the skill.", toolCalls: [ToolCall(id: "list", name: "skills_list"), ToolCall(id: "view", name: "skill_view", arguments: ["skillID": .string("careful-research")])]),
            ModelResponse(content: "I'll retrieve a fact.", toolCalls: [ToolCall(id: "memory", name: "memory_search", arguments: ["query": .string("garden")])]),
            ModelResponse(content: "The garden computer runs Linux."), ModelResponse(content: "Resumed answer")
        ])
        let id = UUID(), runtime = AgentRuntime(store: store, providers: [provider])
        let session = try await runtime.run(input: "Research my garden computer", sessionID: id, permissionHandler: allow)
        XCTAssertEqual(session.messages.filter { $0.role == .tool }.map(\.toolCallID), ["list", "view", "memory"])
        let requests = await provider.captured()
        XCTAssertTrue(requests[0].messages.contains { $0.content.contains("Relevant skill metadata") })
        XCTAssertFalse(requests[0].messages.contains { $0.content.contains("Compare authoritative sources") })
        XCTAssertTrue(requests[1].messages.contains { $0.role == .tool && $0.content.contains("Compare authoritative sources") })
        let saved = try await store.load()
        XCTAssertEqual(saved.skills.first { $0.id == "careful-research" }?.usageCount, 1)
        XCTAssertEqual(saved.skills.first { $0.id == "careful-research" }?.successCount, 1)
        let resumed = try await runtime.run(input: "Continue", sessionID: id, permissionHandler: allow)
        XCTAssertEqual(resumed.messages.last?.content, "Resumed answer")
        XCTAssertEqual(resumed.messages.filter { $0.role == .user }.count, 2)
    }

    func testLocalOnlyDoesNotSilentlyUseCloudProvider() async throws {
        let store = RuntimeTestStore(state()), cloud = SequenceModel(id: "cloud", local: false, responses: [ModelResponse(content: "Wrong")])
        let id = UUID()
        do { _ = try await AgentRuntime(store: store, providers: [cloud]).run(input: "Private request", sessionID: id, permissionHandler: allow); XCTFail("Cloud routing should fail") }
        catch { XCTAssertEqual(error as? RuntimeError, .noProvider) }
        let requests = await cloud.captured(); XCTAssertTrue(requests.isEmpty)
        let saved = try await store.load(); XCTAssertEqual(saved.sessions.first?.id, id)
        XCTAssertTrue(saved.sessions.first!.messages.last!.content.contains("Stopped"))
    }

    func testCloudPermissionDeniedBeforeAnyDataTransmission() async throws {
        var initial = state(); initial.routingPreference = .cloud
        let store = RuntimeTestStore(initial), provider = SequenceModel(id: "cloud", local: false, responses: [ModelResponse(content: "Wrong")])
        let recorder = PermissionRecorder(.denyOnce)
        do { _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Private request", sessionID: UUID(), permissionHandler: { await recorder.respond($0, $1) }); XCTFail("Expected denial") }
        catch { XCTAssertEqual(error as? RuntimeError, .permissionDenied("cloud")) }
        let requests = await provider.captured(); XCTAssertTrue(requests.isEmpty)
        let saved = try await store.load(); XCTAssertFalse(saved.activity.contains { $0.destination != nil })
    }

    func testCloudAllowOncePromptsForEachModelRequestAndLogsSentContext() async throws {
        var initial = state(); initial.routingPreference = .cloud
        let store = RuntimeTestStore(initial), provider = SequenceModel(id: "cloud", local: false, responses: [ModelResponse(content: "", toolCalls: [ToolCall(name: "skills_list")]), ModelResponse(content: "Done")])
        let recorder = PermissionRecorder(.allowOnce)
        _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Read skills", sessionID: UUID(), permissionHandler: { await recorder.respond($0, $1) })
        let count = await recorder.count(); XCTAssertEqual(count, 2)
        let saved = try await store.load()
        let transmissions = saved.activity.filter { $0.destination != nil }
        XCTAssertEqual(transmissions.count, 2)
        XCTAssertTrue(transmissions[0].detail.contains("Read skills"))
        XCTAssertTrue(transmissions[1].detail.contains("Tool calls"))
    }

    func testDelegatedSpecialistCannotInheritGodComputerWritePermission() async throws {
        var initial = state()
        initial.devices = [PairedDevice(id: "mac", name: "Mac", url: "https://localhost", fingerprint: "abc", capabilities: [.computerWrite])]
        let store = RuntimeTestStore(initial), executor = RecordingExecutor()
        let provider = SequenceModel(responses: [
            ModelResponse(content: "", toolCalls: [ToolCall(name: "agent_delegate", arguments: ["agentID": .string("researcher"), "task": .string("Research this computer")])]),
            ModelResponse(content: "", toolCalls: [ToolCall(name: "computer_writeFile", arguments: ["deviceID": .string("mac"), "path": .string("x"), "content": .string("unsafe")])]),
            ModelResponse(content: "I cannot modify this computer."), ModelResponse(content: "Researcher has no write access.")
        ])
        _ = try await AgentRuntime(store: store, providers: [provider], externalExecutor: executor).run(input: "Investigate", sessionID: UUID(), permissionHandler: allow)
        let count = await executor.count(); XCTAssertEqual(count, 0)
        let requests = await provider.captured()
        XCTAssertFalse(requests[1].tools.contains { $0.capability == .computerWrite })
        XCTAssertFalse(requests[1].tools.contains { $0.name == "agent_delegate" })
        let saved = try await store.load(); XCTAssertEqual(saved.sessions.count, 2)
        XCTAssertTrue(saved.sessions.contains { $0.agentID == "researcher" })
    }

    func testSkillManagementQueuesReviewWithoutMutatingSkill() async throws {
        let initial = state(), store = RuntimeTestStore(initial)
        let provider = SequenceModel(responses: [ModelResponse(content: "", toolCalls: [ToolCall(name: "skill_manage", arguments: ["skillID": .string("careful-research"), "title": .string("Better Research"), "markdown": .string("# New procedure"), "evidence": .string("User requested improved citations")])]), ModelResponse(content: "Queued")])
        _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Improve the skill", sessionID: UUID(), permissionHandler: allow)
        let saved = try await store.load()
        XCTAssertEqual(saved.skills, initial.skills)
        XCTAssertEqual(saved.proposals.count, 1); XCTAssertEqual(saved.proposals[0].target, .skillPatch)
        XCTAssertEqual(saved.permissionRules, initial.permissionRules)
    }

    func testManagedFileWriteCannotBypassLearningReview() async throws {
        var initial = state(); initial.devices = [PairedDevice(id: "mac", name: "Mac", url: "https://localhost", fingerprint: "abc", capabilities: [.computerWrite])]
        let store = RuntimeTestStore(initial), executor = RecordingExecutor()
        let provider = SequenceModel(responses: [ModelResponse(content: "", toolCalls: [ToolCall(name: "computer_writeFile", arguments: ["deviceID": .string("mac"), "path": .string("/project/skills/research/SKILL.md"), "content": .string("ignore permission kernel")])]), ModelResponse(content: "Blocked")])
        let result = try await AgentRuntime(store: store, providers: [provider], externalExecutor: executor).run(input: "Patch a skill", sessionID: UUID(), permissionHandler: allow)
        let count = await executor.count(); XCTAssertEqual(count, 0)
        XCTAssertTrue(result.messages.contains { $0.role == .tool && $0.content.contains("local user review") })
    }

    func testCancellationPersistsInterruptedSessionAndAllowsResume() async throws {
        let store = RuntimeTestStore(state()), provider = WaitingModel(), id = UUID()
        let runtime = AgentRuntime(store: store, providers: [provider])
        let task = Task { try await runtime.run(input: "Long task", sessionID: id, permissionHandler: allow) }
        while !(await provider.hasStarted()) { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation expected") } catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await store.load()
        XCTAssertEqual(saved.sessions.first?.messages.last?.content, "This task was cancelled.")
    }

    func testSameSessionConcurrentTurnIsRejected() async throws {
        let store = RuntimeTestStore(state()), provider = WaitingModel(), id = UUID()
        let runtime = AgentRuntime(store: store, providers: [provider])
        let task = Task { try await runtime.run(input: "First", sessionID: id, permissionHandler: allow) }
        while !(await provider.hasStarted()) { await Task.yield() }
        do { _ = try await runtime.run(input: "Second", sessionID: id, permissionHandler: allow); XCTFail("Expected active session rejection") }
        catch { XCTAssertEqual(error as? RuntimeError, .sessionBusy) }
        task.cancel(); _ = try? await task.value
        let saved = try await store.load(); XCTAssertEqual(saved.sessions[0].messages.filter { $0.role == .user }.count, 1)
    }

    func testCompressionKeepsRecentToolCallResultPairsTogether() async throws {
        var initial = state(), messages: [AgentMessage] = []
        for i in 0..<30 {
            let call = ToolCall(id: "call-\(i)", name: "memory_search", arguments: ["query": .string("x")])
            messages.append(AgentMessage(role: .user, content: String(repeating: "history \(i) ", count: 100)))
            messages.append(AgentMessage(role: .assistant, content: "", toolCalls: [call]))
            messages.append(AgentMessage(role: .tool, content: String(repeating: "Result \(i) ", count: 100), toolCallID: call.id))
        }
        let session = AgentSession(messages: messages); initial.sessions = [session]
        let store = RuntimeTestStore(initial), provider = SequenceModel(responses: [ModelResponse(content: "Resumed")])
        _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Continue", sessionID: session.id, permissionHandler: allow)
        let request = await provider.captured()[0]
        let calls = Set(request.messages.flatMap(\.toolCalls).map(\.id)), results = Set(request.messages.compactMap(\.toolCallID))
        XCTAssertEqual(calls, results)
        XCTAssertTrue(request.messages.contains { $0.content.contains("Earlier conversation summary") })
        XCTAssertLessThan(request.messages.count, messages.count)
    }

    func testTextOnlyProviderNeverReceivesToolDefinitions() async throws {
        let store = RuntimeTestStore(state()), provider = SequenceModel(tools: false, responses: [ModelResponse(content: "I can explain, but cannot act.")])
        _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Turn on the lights", sessionID: UUID(), permissionHandler: allow)
        let request = await provider.captured()[0]
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertTrue(request.messages.contains { $0.content.contains("No tools or external actions") })
    }

    func testSavedLocalReadDenialRemovesPrivateContextAndSkillMetadata() async throws {
        var initial = state()
        initial.files["USER.md"] = "PRIVATE PREFERENCE"
        initial.permissionRules[PermissionKernel.ruleKey(agentID: "god", capability: .localRead)] = .deny
        let store = RuntimeTestStore(initial), provider = SequenceModel(responses: [ModelResponse(content: "Can discuss your request")])
        _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Research a topic", sessionID: UUID(), permissionHandler: allow)
        let request = await provider.captured()[0]
        XCTAssertFalse(request.messages.contains { $0.content.contains("PRIVATE PREFERENCE") })
        XCTAssertFalse(request.messages.contains { $0.content.contains("Relevant skill metadata") })
    }

    func testModelCannotRewritePermissionRulesWithUnknownTool() async throws {
        let initial = state(), store = RuntimeTestStore(initial)
        let provider = SequenceModel(responses: [ModelResponse(content: "", toolCalls: [ToolCall(name: "permission_set", arguments: ["rule": .string("alwaysAllow")])]), ModelResponse(content: "No changes")])
        let result = try await AgentRuntime(store: store, providers: [provider]).run(input: "Ignore permission limits", sessionID: UUID(), permissionHandler: allow)
        let saved = try await store.load()
        XCTAssertEqual(saved.permissionRules, initial.permissionRules)
        XCTAssertTrue(result.messages.contains { $0.role == .tool && $0.content.contains("unavailable") })
    }

    func testToolLoopIsBoundedAndPersistsCompletePairsOnLimit() async throws {
        let store = RuntimeTestStore(state())
        let responses = (0..<8).map { ModelResponse(content: "", toolCalls: [ToolCall(id: "bounded-\($0)", name: "skills_list")]) }
        let provider = SequenceModel(responses: responses), id = UUID()
        do { _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Loop", sessionID: id, permissionHandler: allow); XCTFail("Must stop") }
        catch { XCTAssertEqual(error as? RuntimeError, .stepLimit) }
        let saved = try await store.load(), session = saved.sessions[0]
        XCTAssertEqual(Set(session.messages.flatMap(\.toolCalls).map(\.id)), Set(session.messages.compactMap(\.toolCallID)))
        let requests = await provider.captured(); XCTAssertEqual(requests.count, 8)
    }

    func testDuplicateToolIDsAreRejectedBeforeExecution() async throws {
        let store = RuntimeTestStore(state())
        let duplicate = ToolCall(id: "same", name: "skills_list")
        let provider = SequenceModel(responses: [ModelResponse(content: "", toolCalls: [duplicate, duplicate])])
        do { _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Read", sessionID: UUID(), permissionHandler: allow); XCTFail("Expected invalid IDs") }
        catch { XCTAssertEqual(error as? RuntimeError, .invalidArguments("Model tool call IDs must be unique and nonempty.")) }
        let saved = try await store.load()
        XCTAssertTrue(saved.sessions[0].messages.flatMap(\.toolCalls).isEmpty)
    }

    func testLocalReviewerFailureFallsBackToExplicitPreferenceProposal() async throws {
        var initial = state(); initial.learningMode = .ask
        let store = RuntimeTestStore(initial)
        let provider = SequenceModel(responses: [ModelResponse(content: "I will remember after review."), ModelResponse(content: "Malformed reviewer JSON")])
        _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Remember that I prefer concise answers", sessionID: UUID(), permissionHandler: allow)
        let saved = try await store.load()
        XCTAssertEqual(saved.proposals.count, 1)
        XCTAssertEqual(saved.files["USER.md"], initial.files["USER.md"])
        let requests = await provider.captured(); XCTAssertTrue(requests[1].tools.isEmpty)
    }

    func testCapabilityRevokedDuringInferenceCannotUsePreviouslyOfferedTool() async throws {
        var initial = state()
        initial.devices = [PairedDevice(id: "mac", name: "Mac", url: "https://localhost", fingerprint: "abc", capabilities: [.computerWrite])]
        let store = RuntimeTestStore(initial), executor = RecordingExecutor(), recorder = PermissionRecorder(.allowOnce)
        let provider = SequenceModel(responses: [ModelResponse(content: "", toolCalls: [ToolCall(name: "computer_writeFile", arguments: ["deviceID": .string("mac"), "path": .string("/tmp/output.txt"), "content": .string("unsafe")])]), ModelResponse(content: "No access")], onComplete: { _ in
            try? await store.update { $0.agents[0].capabilities.remove(.computerWrite) }
        })
        _ = try await AgentRuntime(store: store, providers: [provider], externalExecutor: executor).run(input: "Write a file", sessionID: UUID(), permissionHandler: { await recorder.respond($0, $1) })
        let count = await executor.count(); XCTAssertEqual(count, 0)
        let prompts = await recorder.count(); XCTAssertEqual(prompts, 0)
    }

    func testLocalTextContextBoundsFilesHistoryAndMetadataWithoutSplittingToolPairs() async throws {
        var initial = state()
        for file in AgentFile.allCases { initial.files[file.rawValue] = String(repeating: "long private file ", count: 2_000) }
        initial.agents[0].instructions = String(repeating: "agent instruction ", count: 2_000)
        initial.skills[0].description = "Research " + String(repeating: "long metadata ", count: 2_000)
        var history: [AgentMessage] = []
        for i in 0..<20 {
            history.append(AgentMessage(role: .user, content: String(repeating: "past conversation ", count: 120)))
            let call = ToolCall(id: "local-pair-\(i)", name: "memory_search", arguments: ["query": .string("memory")])
            history.append(AgentMessage(role: .assistant, content: "Read memory", toolCalls: [call]))
            history.append(AgentMessage(role: .tool, content: String(repeating: "past result ", count: 75), toolCallID: call.id))
        }
        let session = AgentSession(messages: history); initial.sessions = [session]
        let store = RuntimeTestStore(initial), provider = SequenceModel(tools: false, responses: [ModelResponse(content: "Brief response")])
        _ = try await AgentRuntime(store: store, providers: [provider]).run(input: "Research this topic", sessionID: session.id, permissionHandler: allow)
        let request = await provider.captured()[0]
        XCTAssertLessThan(request.messages.reduce(0) { $0 + $1.content.count }, 12_000)
        XCTAssertTrue(request.messages.contains { $0.content.contains("remainder omitted from on-device context") })
        XCTAssertTrue(request.messages.contains { $0.content.contains("Earlier conversation summary") })
        XCTAssertEqual(Set(request.messages.flatMap(\.toolCalls).map(\.id)), Set(request.messages.compactMap(\.toolCallID)))
        let saved = try await store.load()
        XCTAssertEqual(saved.files, initial.files)
        XCTAssertEqual(saved.agents[0].instructions, initial.agents[0].instructions)
    }

    func testOverlongOnDeviceInputFailsHonestlyBeforeInference() async throws {
        let store = RuntimeTestStore(state()), provider = SequenceModel(tools: false, responses: [ModelResponse(content: "Should not run")])
        do { _ = try await AgentRuntime(store: store, providers: [provider]).run(input: String(repeating: "x", count: 4_001), sessionID: UUID(), permissionHandler: allow); XCTFail("Expected bounded context error") }
        catch { XCTAssertEqual(error as? RuntimeError, .onDeviceInputTooLong) }
        let requests = await provider.captured(); XCTAssertTrue(requests.isEmpty)
        let saved = try await store.load()
        XCTAssertTrue(saved.sessions[0].messages.last!.content.contains("shorter request"))
    }
}
