import XCTest
@testable import HarnessCore

final class RemoteAgentJobTests: XCTestCase {
    private func request(timeout: Double = 1) throws -> RemoteAgentJobRequest {
        try RemoteAgentJobRequest(call: ToolCall(name: "remote_agent_execute", arguments: [
            "jobID": .string(UUID().uuidString), "command": .array([.string("pi"), .string("--print"), .string("task")]), "timeout": .number(timeout)
        ]))
    }

    func testWireSnapshotsRejectMismatchedHandlesAndContradictoryResults() throws {
        let id = UUID()
        let result: [String: Any] = ["exitCode": 0, "stdout": "output", "stderr": "", "timedOut": false, "truncated": false]
        let valid: [String: Any] = ["jobID": id.uuidString.lowercased(), "state": "completed", "result": result]
        XCTAssertEqual(try RemoteAgentJobSnapshot.parse(JSONSerialization.data(withJSONObject: valid), expectedJobID: id).result?.stdout, "output")
        var invalids: [[String: Any]] = [
            ["jobID": UUID().uuidString, "state": "running"], ["jobID": "bad", "state": "running"],
            ["jobID": id.uuidString, "state": "unknown"], ["jobID": id.uuidString, "state": "completed"],
            ["jobID": id.uuidString, "state": "running", "result": result], ["jobID": id.uuidString, "state": "failed", "result": result]
        ]
        for (key, value) in [("exitCode", true as Any), ("stdout", 2 as Any), ("timedOut", "true" as Any), ("truncated", 1 as Any), ("stdout", String(repeating: "x", count: 196_609) as Any)] {
            var changed = result; changed[key] = value
            invalids.append(["jobID": id.uuidString, "state": "completed", "result": changed])
        }
        var timedOut = result; timedOut["timedOut"] = true
        invalids.append(["jobID": id.uuidString, "state": "completed", "result": timedOut])
        invalids.append(["jobID": id.uuidString, "state": "cancelled", "result": timedOut])
        for invalid in invalids {
            XCTAssertThrowsError(try RemoteAgentJobSnapshot.parse(JSONSerialization.data(withJSONObject: invalid), expectedJobID: id), "\(invalid["state"] ?? "missing")")
        }
    }

    func testStartRetryUsesOneHandleAndRecoversResult() async throws {
        let request = try request(), wire = JobTestTransport(mode: .startReplyLost)
        let output = await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(1), transport: wire.transport)
        let calls = await wire.calls
        XCTAssertEqual(calls.filter { $0.operation == .start }.count, 2)
        XCTAssertEqual(Set(calls.compactMap { $0.body["jobID"]?.string }), [request.jobID.uuidString.lowercased()])
        let executions = await wire.executions
        XCTAssertEqual(executions, 1)
        XCTAssertTrue(output.contains(request.jobID.uuidString.lowercased()))
        XCTAssertTrue(output.contains("verified output"))
        XCTAssertTrue(output.contains("\"state\":\"completed\""))
    }

    func testPollingFailurePreservesHandleAndNeverRestarts() async throws {
        let request = try request(), wire = JobTestTransport(mode: .pollUnavailable)
        let output = await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(1), transport: wire.transport)
        let calls = await wire.calls
        XCTAssertEqual(calls.filter { $0.operation == .start }.count, 1)
        XCTAssertEqual(calls.filter { $0.operation == .status }.count, 3)
        XCTAssertTrue(output.contains(request.jobID.uuidString.lowercased()))
        XCTAssertTrue(output.contains("may still be running"))
        XCTAssertFalse(output.contains("\"timedOut\":true"))
    }

    func testPollingWaitLimitPreservesRunningStatusAndDoesNotInventServerTimeout() async throws {
        let request = try request(timeout: 0.1), wire = JobTestTransport(mode: .keepRunning)
        let output = await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(5), transport: wire.transport)
        let calls = await wire.calls
        XCTAssertEqual(calls.filter { $0.operation == .start }.count, 1)
        XCTAssertTrue(output.contains("wait limit"))
        XCTAssertTrue(output.contains("\"state\":\"running\""))
        XCTAssertFalse(output.contains("\"timedOut\":true"))
    }

    func testCancelWhileStartIsPendingUsesFreshTaskAndSameHandle() async throws {
        let request = try request(), wire = JobTestTransport(mode: .startPending)
        let work = Task { await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(1), transport: wire.transport) }
        try await waitForStart(wire)
        work.cancel()
        let output = await work.value
        let calls = await wire.calls
        XCTAssertEqual(calls.filter { $0.operation == .start }.count, 1)
        XCTAssertEqual(calls.filter { $0.operation == .cancel }.count, 1)
        XCTAssertTrue(calls.filter { $0.operation == .cancel }.allSatisfy { !$0.taskWasCancelled })
        XCTAssertEqual(Set(calls.compactMap { $0.body["jobID"]?.string }), [request.jobID.uuidString.lowercased()])
        XCTAssertTrue(output.contains("\"state\":\"cancelled\""))
    }

    func testCancelRefreshCollectsOnlySameJobsFinalResult() async throws {
        let request = try request(), wire = JobTestTransport(mode: .cancelResultPending)
        let work = Task { await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(1), transport: wire.transport) }
        try await waitForStart(wire)
        work.cancel()
        let output = await work.value
        let calls = await wire.calls
        XCTAssertEqual(Set(calls.compactMap { $0.body["jobID"]?.string }), [request.jobID.uuidString.lowercased()])
        XCTAssertEqual(calls.filter { $0.operation == .cancel }.count, 1)
        XCTAssertTrue(calls.contains { $0.operation == .status && !$0.taskWasCancelled })
        XCTAssertTrue(output.contains("output before cancellation"))
        XCTAssertTrue(output.contains("\"state\":\"cancelled\""))
    }

    func testUnconfirmedCancellationIsReportedHonestly() async throws {
        let request = try request(), wire = JobTestTransport(mode: .cancelUnavailable)
        let work = Task { await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(1), transport: wire.transport) }
        try await waitForStart(wire)
        work.cancel()
        let output = await work.value
        XCTAssertTrue(output.contains(request.jobID.uuidString.lowercased()))
        XCTAssertTrue(output.contains("could not confirm cancellation"))
        XCTAssertFalse(output.contains("\"state\":\"cancelled\""))
    }

    func testRunningCancelReplyCannotClaimTheJobFinished() async throws {
        let request = try request(), wire = JobTestTransport(mode: .cancelStillRunning)
        let work = Task { await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(1), transport: wire.transport) }
        try await waitForStart(wire)
        work.cancel()
        let output = await work.value
        XCTAssertTrue(output.contains("could not confirm cancellation"))
        XCTAssertFalse(output.contains("result before cancellation took effect"))
    }

    func testJobRequestsRejectBadHandlesAndOutOfRangeTimeoutsBeforeTransport() throws {
        let base: [String: JSONValue] = ["jobID": .string(UUID().uuidString), "command": .array([.string("pi")]), "timeout": .number(1800)]
        var invalids: [[String: JSONValue]] = []
        for timeout in [0, 0.09, 1801, Double.infinity, Double.nan] {
            var value = base; value["timeout"] = .number(timeout); invalids.append(value)
        }
        let invalidCommands: [[JSONValue]] = [[], [.string("")], [.string("pi\0")], [.string(String(repeating: "界", count: 8192))], [.number(1)]]
        for command in invalidCommands {
            var value = base; value["command"] = .array(command); invalids.append(value)
        }
        var value = base; value["jobID"] = .string("bad"); invalids.append(value)
        for invalid in invalids { XCTAssertThrowsError(try RemoteAgentJobRequest(call: ToolCall(name: "remote_agent_execute", arguments: invalid))) }
        XCTAssertThrowsError(try RemoteAgentJobRequest(call: ToolCall(name: "computer_execute", arguments: base)))
    }

    func testServerTimeoutRemainsFailedAndIncludesActualBoundedOutput() async throws {
        let request = try request(), wire = JobTestTransport(mode: .timedOut)
        let output = await RemoteAgentJobRunner.run(request: request, pollInterval: .milliseconds(1), transport: wire.transport)
        XCTAssertTrue(output.contains("\"state\":\"failed\""))
        XCTAssertTrue(output.contains("\"timedOut\":true"))
        XCTAssertTrue(output.contains("before timeout"))
    }

    private func waitForStart(_ wire: JobTestTransport) async throws {
        for _ in 0..<1000 {
            if await wire.calls.contains(where: { $0.operation == .start }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Job never sent its start request")
    }
}

private actor JobTestTransport {
    enum Mode { case startReplyLost, pollUnavailable, keepRunning, startPending, cancelResultPending, cancelUnavailable, cancelStillRunning, timedOut }
    struct Call { let operation: RemoteAgentJobOperation; let body: [String: JSONValue]; let taskWasCancelled: Bool }
    let mode: Mode
    var calls: [Call] = []
    var executions = 0
    private var started = Set<String>()
    private var cancelled = false
    init(mode: Mode) { self.mode = mode }
    nonisolated var transport: RemoteAgentJobRunner.Transport { { operation, body in try await self.send(operation, body) } }

    func send(_ operation: RemoteAgentJobOperation, _ body: [String: JSONValue]) async throws -> Data {
        calls.append(Call(operation: operation, body: body, taskWasCancelled: Task.isCancelled))
        let id = body["jobID"]!.string!
        if operation == .start {
            if started.insert(id).inserted { executions += 1 }
            if mode == .startReplyLost && calls.count == 1 { throw PairingFailure.network }
            if [.startPending, .cancelResultPending, .cancelUnavailable, .cancelStillRunning].contains(mode) { try await Task.sleep(for: .seconds(60)) }
            return try snapshot(id: id, state: "running")
        }
        if operation == .cancel {
            if mode == .cancelUnavailable { throw PairingFailure.network }
            if mode == .cancelStillRunning { return try snapshot(id: id, state: "running") }
            cancelled = true
            return try snapshot(id: id, state: "cancelled", stdout: mode == .cancelResultPending ? nil : "")
        }
        if cancelled { return try snapshot(id: id, state: "cancelled", stdout: "output before cancellation", exitCode: -9) }
        switch mode {
        case .pollUnavailable: throw PairingFailure.network
        case .keepRunning: return try snapshot(id: id, state: "running")
        case .timedOut: return try snapshot(id: id, state: "failed", stdout: "before timeout", exitCode: -9, timedOut: true)
        default: return try snapshot(id: id, state: "completed", stdout: "verified output")
        }
    }

    private func snapshot(id: String, state: String, stdout: String? = nil, exitCode: Int = 0, timedOut: Bool = false) throws -> Data {
        var value: [String: Any] = ["jobID": id, "state": state]
        if let stdout { value["result"] = ["exitCode": exitCode, "stdout": stdout, "stderr": "", "truncated": false, "timedOut": timedOut] }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
