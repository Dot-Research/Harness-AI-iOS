import XCTest
@testable import HarnessCore

final class SkillsTests: XCTestCase {
    func testRecallRequiresRelevanceAndSkipsDisabledSkills() {
        let irrelevant = Skill(name: "Garden", description: "Water flowers", markdown: "SECRET MARKDOWN", usageCount: 100, successCount: 100)
        let disabled = Skill(name: "Research", description: "Investigate sources", markdown: "x", enabled: false)
        let relevant = Skill(name: "Research", description: "Investigate sources", markdown: "x")
        XCTAssertEqual(SkillRecall.rank(query: "Research reliable sources", skills: [irrelevant, disabled, relevant]).map(\.id), [relevant.id])
        XCTAssertTrue(SkillRecall.rank(query: "", skills: [relevant]).isEmpty)
    }
    func testSuccessfulUseImprovesRankForEquallyRelevantSkills() {
        let successful = Skill(id: "good", name: "Research", description: "sources", markdown: "x", usageCount: 10, successCount: 10)
        let unsuccessful = Skill(id: "bad", name: "Research", description: "sources", markdown: "x", usageCount: 10, successCount: 0)
        XCTAssertEqual(SkillRecall.rank(query: "research sources", skills: [unsuccessful, successful]).first?.id, "good")
    }
    func testSeedHasSeparateFilesRestrictedSpecialistsAndPrivacyDefaults() {
        let state = HarnessSeed.makeState()
        XCTAssertEqual(Set(state.files.keys), Set(AgentFile.allCases.map(\.rawValue)))
        XCTAssertEqual(state.learningMode, .ask); XCTAssertEqual(state.routingPreference, .localOnly)
        XCTAssertFalse(state.agents.first { $0.id == "researcher" }!.capabilities.contains(.computerWrite))
        XCTAssertFalse(state.agents.first { $0.id == "coder" }!.capabilities.contains(.computerExecute))
        XCTAssertTrue(state.providers.contains { $0.kind == .openRouter && !$0.enabled })
    }
}
