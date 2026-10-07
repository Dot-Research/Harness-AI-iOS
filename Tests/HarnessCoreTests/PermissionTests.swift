import XCTest
@testable import HarnessCore

actor RuntimeTestStore: HarnessStore {
    var state: HarnessState
    init(_ state: HarnessState = HarnessSeed.makeState()) { self.state = state }
    func load() async throws -> HarnessState { state }
    func update(_ change: @Sendable (inout HarnessState) -> Void) async throws { change(&state) }
}
actor PermissionRecorder {
    var decisions: [PermissionDecision] = []
    var answer: PermissionAnswer
    init(_ answer: PermissionAnswer) { self.answer = answer }
    func respond(_ request: PermissionRequest, _ decision: PermissionDecision) -> PermissionAnswer { decisions.append(decision); return answer }
    func count() -> Int { decisions.count }
}

final class PermissionTests: XCTestCase {
    func testProfileDenyBeatsSavedAllowAndDoesNotAsk() async throws {
        var state = HarnessSeed.makeState()
        let researcher = state.agents.first { $0.id == "researcher" }!
        let key = PermissionKernel.ruleKey(agentID: researcher.id, capability: .computerWrite)
        state.permissionRules[key] = .allow
        let store = RuntimeTestStore(state), recorder = PermissionRecorder(.allowOnce)
        let allowed = try await PermissionKernel(store: store).authorize(tool: HarnessTools.computerWrite, agent: researcher, detail: "test", handler: { await recorder.respond($0, $1) })
        XCTAssertFalse(allowed)
        let count = await recorder.count(); XCTAssertEqual(count, 0)
    }
    func testSensitiveAlwaysAllowStillRequiresBiometricsNextTime() async throws {
        let store = RuntimeTestStore(), recorder = PermissionRecorder(.alwaysAllow)
        let agent = try await store.load().agents[0]
        let kernel = PermissionKernel(store: store)
        for _ in 0..<2 {
            let allowed = try await kernel.authorize(tool: HarnessTools.computerExecute, agent: agent, detail: "test", handler: { await recorder.respond($0, $1) })
            XCTAssertTrue(allowed)
        }
        let decisions = await recorder.decisions
        XCTAssertEqual(decisions, [.biometric, .biometric])
        let state = try await store.load()
        XCTAssertNil(state.permissionRules[PermissionKernel.ruleKey(agentID: agent.id, capability: .computerExecute)])
    }
    func testRulesAreScopedToAgentAndExternalLocalReadsAsk() async throws {
        var state = HarnessSeed.makeState()
        let external = AgentProfile(id: "download", name: "Download", purpose: "Untrusted", external: true)
        state.agents.append(external)
        state.permissionRules[PermissionKernel.ruleKey(agentID: "god", capability: .localRead)] = .allow
        let store = RuntimeTestStore(state), recorder = PermissionRecorder(.denyOnce)
        let allowed = try await PermissionKernel(store: store).authorize(tool: HarnessTools.memorySearch, agent: external, detail: "test", handler: { await recorder.respond($0, $1) })
        XCTAssertFalse(allowed)
        let decisions = await recorder.decisions; XCTAssertEqual(decisions, [.ask])
    }
    func testRevocationWhileApprovalUIIsOpenPreventsExecution() async throws {
        let store = RuntimeTestStore()
        let agent = try await store.load().agents[0]
        let allowed = try await PermissionKernel(store: store).authorize(tool: HarnessTools.computerWrite, agent: agent, detail: "test", handler: { _, _ in
            try? await store.update { $0.agents[0].capabilities.remove(.computerWrite) }
            return .alwaysAllow
        })
        XCTAssertFalse(allowed)
        let state = try await store.load()
        XCTAssertNil(state.permissionRules[PermissionKernel.ruleKey(agentID: agent.id, capability: .computerWrite)])
    }
    func testSavedDenialBeatsSensitiveAuthentication() {
        let agent = HarnessSeed.makeState().agents[0]
        let key = PermissionKernel.ruleKey(agentID: agent.id, capability: .computerExecute)
        XCTAssertEqual(PermissionKernel.decision(for: HarnessTools.computerExecute, agent: agent, rules: [key: .deny]), .deny)
    }
}
