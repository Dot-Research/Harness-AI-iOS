import XCTest
@testable import HarnessCore

final class RemoteAgentTests: XCTestCase {
    private func device() -> PairedDevice {
        PairedDevice(id: "mac", name: "Mac", url: "https://mac.local", fingerprint: "abc", capabilities: [.computerExecute])
    }
    private func connection(runtime: RemoteAgentRuntime = .pi, alias: String? = nil, directory: String? = nil) -> RemoteAgentConnection {
        RemoteAgentConnection(id: "worker", name: "My worker", deviceID: "mac", runtime: runtime, sshAlias: alias, workingDirectory: directory)
    }

    func testLocalPromptsAreLiteralArgumentsAndDoNotBypassRuntimePermissions() throws {
        let task = "Review 'quotes'; $(touch /tmp/nope) and `echo unsafe`"
        let plan = try RemoteAgentExecutionPlan(connection: connection(), device: device(), task: task)
        XCTAssertEqual(plan.command, ["pi", "--print", "--mode", "text", "--", task])
        XCTAssertFalse(plan.command.contains("--yolo"))
        XCTAssertFalse(plan.command.contains("--dangerously-skip-permissions"))
    }

    func testSSHQuotesEveryArgumentAndRequiresKnownHostAuthentication() throws {
        let task = "Inspect 'a'; $(touch /tmp/nope)"
        let plan = try RemoteAgentExecutionPlan(connection: connection(alias: "lab", directory: "/work/my project"), device: device(), task: task)
        XCTAssertEqual(Array(plan.command.prefix(8)), ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "--", "lab"])
        XCTAssertEqual(plan.command.last, "cd '/work/my project' && exec 'pi' '--print' '--mode' 'text' '--' 'Inspect '\"'\"'a'\"'\"'; $(touch /tmp/nope)'")
        XCTAssertTrue(plan.permissionDetail.contains("lab"))
        XCTAssertTrue(plan.permissionDetail.contains(task))
    }

    func testInvalidAliasesAndUnapprovedExecutableNamesAreRejected() throws {
        for alias in ["-oProxyCommand=bad", "host;touch x", "host\nother", "", "user@host"] {
            XCTAssertThrowsError(try RemoteAgentExecutionPlan(connection: connection(alias: alias), device: device(), task: "Review"))
        }
        var custom = connection(); custom.executable = "sh"
        XCTAssertThrowsError(try RemoteAgentExecutionPlan(connection: custom, device: device(), task: "Review"))
        custom.executable = "/opt/homebrew/bin/pi"
        XCTAssertEqual(try RemoteAgentExecutionPlan(connection: custom, device: device(), task: "Review").command.first, custom.executable)
    }

    func testAllNamedRuntimesHaveFiniteNoninteractiveCommands() throws {
        XCTAssertEqual(try RemoteAgentExecutionPlan(connection: connection(runtime: .claudeCode), device: device(), task: "Review").command, ["claude", "--print", "--output-format", "text", "--", "Review"])
        XCTAssertEqual(try RemoteAgentExecutionPlan(connection: connection(runtime: .hermes), device: device(), task: "Review").command, ["hermes", "chat", "--oneshot", "--query", "Review"])
    }

    func testLegacyStateWithoutRemoteConnectionsStillDecodes() throws {
        let data = try JSONEncoder().encode(HarnessSeed.makeState())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "remoteAgents")
        let decoded = try JSONDecoder().decode(HarnessState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.remoteAgentConnections.isEmpty)
    }

    func testRemoteRoutePersistsAcrossStoreReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("harness.sqlite")
        let store = try SQLiteHarnessStore(url: url), route = connection(alias: "lab")
        try await store.update { $0.remoteAgents = [route] }
        let reopened = try SQLiteHarnessStore(url: url)
        let state = try await reopened.load()
        XCTAssertEqual(state.remoteAgentConnections, [route])
    }

    func testDirectorRunsSavedAgentAndRecordsActualResult() async throws {
        var initial = HarnessSeed.makeState(); initial.learningMode = .off
        initial.devices = [device()]; initial.remoteAgents = [connection()]
        let store = RuntimeTestStore(initial), executor = RemoteRecordingExecutor()
        let provider = SequenceModel(responses: [ModelResponse(content: "", toolCalls: [ToolCall(name: "remote_agent_run", arguments: ["connectionID": .string("worker"), "task": .string("Review code")])]), ModelResponse(content: "Reviewed")])
        let session = try await AgentRuntime(store: store, providers: [provider], externalExecutor: executor).run(input: "Delegate a review", sessionID: UUID(), permissionHandler: { _, _ in .allowOnce })
        let calls = await executor.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "remote_agent_execute")
        XCTAssertEqual(calls.first?.arguments["timeout"], .number(1800))
        XCTAssertNotNil(calls.first?.arguments["jobID"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(session.messages.contains { $0.role == .tool && $0.content.contains("Verified worker output") })
        let requests = await provider.captured()
        XCTAssertTrue(requests[0].messages.contains { $0.content.contains("My worker") && $0.content.contains("worker") })
    }

    func testApprovedPlanMapsToLongRunningJobWithoutChangingItsRouteSnapshot() throws {
        let plan = try RemoteAgentExecutionPlan(connection: connection(alias: "lab"), device: device(), task: "Review")
        let same = try RemoteAgentExecutionPlan(connection: connection(alias: "lab"), device: device(), task: "Review")
        XCTAssertEqual(plan, same)
        let call = plan.toolCall(id: "model-call")
        XCTAssertEqual(call.id, "model-call")
        XCTAssertEqual(call.name, "remote_agent_execute")
        XCTAssertEqual(call.arguments["command"], .array(plan.command.map(JSONValue.string)))
        XCTAssertEqual(call.arguments["deviceID"], .string("mac"))
        XCTAssertEqual(call.arguments["timeout"], .number(1800))
        XCTAssertNotNil(call.arguments["jobID"]?.string.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(plan.permissionDetail.contains("30 minutes"))
    }

    func testChangedRouteAfterPermissionCannotExecuteDifferentMachine() async throws {
        var initial = HarnessSeed.makeState(); initial.learningMode = .off
        initial.devices = [device()]; initial.remoteAgents = [connection()]
        let store = RuntimeTestStore(initial), executor = RemoteRecordingExecutor()
        let provider = SequenceModel(responses: [ModelResponse(content: "", toolCalls: [ToolCall(name: "remote_agent_run", arguments: ["connectionID": .string("worker"), "task": .string("Review")])]), ModelResponse(content: "Stopped")])
        let session = try await AgentRuntime(store: store, providers: [provider], externalExecutor: executor).run(input: "Delegate", sessionID: UUID(), permissionHandler: { request, _ in
            if request.tool.name == "remote_agent_run" { try? await store.update { $0.remoteAgents?[0].sshAlias = "other" } }
            return .allowOnce
        })
        let calls = await executor.recorded()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(session.messages.contains { $0.role == .tool && $0.content.contains("changed") })
    }
}

private actor RemoteRecordingExecutor: ExternalToolExecutor {
    private var calls: [ToolCall] = []
    func execute(_ call: ToolCall, device: PairedDevice) async throws -> String {
        calls.append(call); return "Verified worker output"
    }
    func recorded() -> [ToolCall] { calls }
}
