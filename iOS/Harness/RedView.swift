import SwiftUI
import HarnessCore

struct RedView: View {
    @State private var selected: Skill?
    private let collection = RedCollection.skills
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Red").font(.system(size: 52, weight: .regular, design: .serif)).tracking(-1.5)
                    Spacer()
                    StatusPill(title: "LOCAL COLLECTION", symbol: "shippingbox", color: HarnessTheme.coral)
                }
                Text("Ideas you can run.")
                    .font(.system(.title, design: .serif))
                Text("A curated prototype collection of reusable skills. Browse and install on this device, with no account or network request.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(5)
                SectionEyebrow(title: "Made for your personal node", trailing: "01 — 03")
                ForEach(Array(collection.enumerated()), id: \.element.id) { index, skill in
                    Button { selected = skill } label: {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 19) {
                                HStack {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.coral)
                                    Spacer()
                                    Image(systemName: RedCollection.symbols[index])
                                        .font(.system(size: 30, weight: .light)).foregroundStyle(HarnessTheme.amber)
                                }
                                Text(skill.name).font(.system(.title2, design: .serif)).foregroundStyle(HarnessTheme.text)
                                Text(skill.description).font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                                Divider().overlay(HarnessTheme.border)
                                HStack {
                                    Label("Local context", systemImage: "iphone").font(.caption).foregroundStyle(HarnessTheme.green)
                                    Spacer()
                                    Text("INSPECT & INSTALL ↗").font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.coral)
                                }
                            }
                        }
                    }.buttonStyle(.plain)
                }
                Text("Public publishing, comments, likes, and remote discovery are planned. This collection contains no social activity or downloaded code.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .navigationTitle("Discover").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { skill in NavigationStack { RedSkillView(skill: skill) } }
        .harnessScreen()
    }
}

private struct RedSkillView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let skill: Skill
    @State private var fork: Skill?
    private var installed: Bool { model.state.skills.contains { $0.id == skill.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(skill.name).font(.system(.largeTitle, design: .serif))
                Text(skill.description).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                HarnessCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionEyebrow(title: "Before installing")
                        CapabilityTags(capabilities: [.localRead])
                        Text("Network access: none\nNative execution: none\nSource: bundled Harness collection")
                            .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(5)
                        Text("A skill is a set of instructions. Each action it suggests still requires authorization by the Permission Kernel.")
                            .font(.caption).foregroundStyle(HarnessTheme.amber).lineSpacing(4)
                    }
                }
                Button {
                    var restricted = skill
                    restricted.requiredCapabilities = [.localRead]
                    Task { await model.saveSkill(restricted) }
                } label: { Label(installed ? "Installed on this iPhone" : "Install skill", systemImage: installed ? "checkmark" : "arrow.down") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(installed)
                Button {
                    fork = Skill(name: skill.name + " — my version", description: skill.description, markdown: skill.markdown, keywords: skill.keywords, requiredCapabilities: [.localRead])
                } label: { Label("Fork and make it yours", systemImage: "arrow.triangle.branch") }
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
                SectionEyebrow(title: "Full SKILL.md")
                HarnessCard { Text(skill.markdown).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled) }
            }.padding(22)
        }
        .navigationTitle("Inspect skill").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .sheet(item: $fork) { skill in NavigationStack { SkillEditorView(skill: skill) } }
        .harnessScreen()
    }
}

private enum RedCollection {
    static let symbols = ["arrow.triangle.branch", "rectangle.3.group", "book.pages"]
    static let skills: [Skill] = [
        Skill(id: "red-decision-canvas", name: "Decision canvas", description: "Turn a difficult choice into clear tradeoffs, open questions, and a small next step.", markdown: "# Decision canvas\n\n## When to use\nUse when the user is weighing a meaningful decision.\n\n## Steps\n1. Restate the decision and ask for missing constraints.\n2. Identify the user's priorities using only supplied context.\n3. Compare options, including uncertainty and reversibility.\n4. Separate known facts from assumptions.\n5. Suggest one small, reversible next step.\n\n## Boundaries\nDo not take external actions. Do not invent user preferences.", keywords: ["decision", "tradeoffs", "choice"]),
        Skill(id: "red-project-map", name: "Project map", description: "Find the shape of a project. Define the outcome, map dependencies, and choose the first useful milestone.", markdown: "# Project map\n\n## When to use\nUse when the user wants to plan a new project.\n\n## Steps\n1. Define the outcome and a visible acceptance criterion.\n2. Identify constraints, unknowns, and dependencies.\n3. Break the work into a few independently useful milestones.\n4. Choose the smallest milestone that resolves an important unknown.\n5. Summarize next actions and unresolved questions.\n\n## Boundaries\nUse local context only. Planning does not authorize external actions.", keywords: ["project", "planning", "milestones"]),
        Skill(id: "red-context-librarian", name: "Context librarian", description: "Review your agent files and find stale facts, contradictions, and useful gaps before proposing an update.", markdown: "# Context librarian\n\n## When to use\nUse when the user asks to inspect personal agent context.\n\n## Steps\n1. Read SOUL.md, USER.md, MEMORY.md, and AGENTS.md through authorized local tools.\n2. Identify contradictions and stale claims.\n3. Cite the file and text behind each observation.\n4. Propose small targeted edits rather than replacing everything.\n5. Ask the user to review changes through the learning approval flow.\n\n## Boundaries\nNever write files silently. Never infer sensitive facts from incomplete evidence.", keywords: ["memory", "context", "review"])
    ]
}
