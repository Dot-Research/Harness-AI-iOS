import SwiftUI
import HarnessCore

struct AgentsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Good work.\nShared intelligence.")
                    .font(.system(.largeTitle, design: .serif)).tracking(-0.6)
                Text("Specialists with a purpose, their own context, and permissions you can inspect.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                HarnessCard {
                    HStack(alignment: .top, spacing: 16) {
                        HarnessMark(size: 48)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.state.directorName).font(.title3.weight(.medium))
                            Text("GENERAL ORCHESTRATION DIRECTOR")
                                .font(.system(.caption2, design: .monospaced)).tracking(1.2).foregroundStyle(HarnessTheme.amber)
                            Text("One conversation. A coordinated team.")
                                .font(.caption).foregroundStyle(HarnessTheme.secondary)
                        }
                    }
                }
                SectionEyebrow(title: "Your specialists", trailing: "\(model.state.agents.filter { $0.id != "god" }.count)")
                ForEach(model.state.agents.filter { $0.id != "god" }) { agent in
                    NavigationLink { AgentDetailView(agent: agent) } label: {
                        HarnessCard {
                            HStack(alignment: .top, spacing: 15) {
                                Image(systemName: symbol(for: agent.id))
                                    .font(.system(size: 24, weight: .light)).foregroundStyle(HarnessTheme.amber)
                                    .frame(width: 44, height: 44).background(HarnessTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(agent.name).font(.title3.weight(.medium))
                                    Text(agent.purpose).font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(3)
                                    Text(agent.external ? "RESTRICTED EXTERNAL AGENT" : "SEPARATE PERMISSION PROFILE")
                                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(HarnessTheme.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                if model.state.agents.filter({ $0.id != "god" }).isEmpty {
                    HarnessEmptyState(symbol: "person.2", title: "Room for a team.", detail: "GOD can work with installed specialists. Every specialist receives an independent, restricted permission profile.")
                }
                SectionEyebrow(title: "Reusable know-how")
                NavigationLink { SkillsView() } label: {
                    HarnessCard { SettingsRow(symbol: "books.vertical", title: "Skills library", subtitle: "\(model.state.skills.filter(\.enabled).count) enabled · inspect, edit, and create") }
                }.buttonStyle(.plain)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Agents").navigationBarTitleDisplayMode(.inline).harnessScreen()
    }

    private func symbol(for id: String) -> String {
        switch id {
        case "researcher": "magnifyingglass"
        case "coder": "curlybraces"
        default: "sparkles.rectangle.stack"
        }
    }
}

private struct AgentDetailView: View {
    @EnvironmentObject private var model: AppModel
    let agent: AgentProfile
    @State private var showConversation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(agent.purpose).font(.system(.title2, design: .serif)).lineSpacing(5)
                Button {
                    Task {
                        await model.newSession(agentID: agent.id)
                        showConversation = true
                    }
                } label: { Label("Talk to \(agent.name)", systemImage: "bubble.left") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(model.isWorking)
                SectionEyebrow(title: "Permission profile")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 15) {
                        CapabilityTags(capabilities: agent.capabilities)
                        Text("Every action still passes through the Permission Kernel. This agent cannot inherit the director’s permissions.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                SectionEyebrow(title: "AGENTS.md")
                HarnessCard {
                    Text(agent.instructions.isEmpty ? "No additional instructions." : agent.instructions)
                        .font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                }
                SectionEyebrow(title: "Allowed skills")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 10) {
                        if agent.allowedSkills.isEmpty { Text("No skills granted").foregroundStyle(HarnessTheme.secondary) }
                        ForEach(agent.allowedSkills, id: \.self) { id in
                            Text(model.state.skills.first { $0.id == id }?.name ?? id).font(.subheadline)
                        }
                    }
                }
                Text("Model: current routing preference. Memory: local agent context. Computer access requires a paired capability and your permission.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle(agent.name).navigationBarTitleDisplayMode(.inline).harnessScreen()
            .sheet(isPresented: $showConversation) {
                NavigationStack {
                    ConversationView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showConversation = false } } }
                }
            }
    }
}

struct SkillsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: Skill?
    @State private var query = ""
    private var skills: [Skill] {
        model.state.skills.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Teach a method.\nReuse the insight.")
                    .font(.system(.largeTitle, design: .serif))
                Text("Only names and descriptions enter context initially. Full instructions load when a skill is relevant.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                if skills.isEmpty {
                    HarnessEmptyState(symbol: "books.vertical", title: query.isEmpty ? "Your library starts here." : "No matching skills.", detail: "Create a reusable workflow, or explore the local collection in Red.")
                }
                ForEach(skills) { skill in
                    Button { editor = skill } label: {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Text(skill.name).font(.title3.weight(.medium)).foregroundStyle(HarnessTheme.text)
                                    Spacer()
                                    StatusPill(title: skill.enabled ? "Enabled" : "Disabled", symbol: skill.enabled ? "checkmark" : "pause", color: skill.enabled ? HarnessTheme.green : HarnessTheme.secondary)
                                }
                                Text(skill.description).font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                                Text("v\(skill.version) · \(skill.usageCount) uses · \(skill.successCount) completed turns")
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .searchable(text: $query, prompt: "Find a skill")
        .navigationTitle("Skills").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor = Skill(name: "", description: "", markdown: "# New skill\n\n## When to use\n\n## Steps\n") } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Create skill")
            }
        }
        .sheet(item: $editor) { skill in NavigationStack { SkillEditorView(skill: skill) } }
        .harnessScreen()
    }
}

struct SkillEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let skill: Skill
    @State private var name: String
    @State private var description: String
    @State private var markdown: String
    @State private var keywords: String
    @State private var enabled: Bool
    @State private var confirmDelete = false

    init(skill: Skill) {
        self.skill = skill
        _name = State(initialValue: skill.name)
        _description = State(initialValue: skill.description)
        _markdown = State(initialValue: skill.markdown)
        _keywords = State(initialValue: skill.keywords.joined(separator: ", "))
        _enabled = State(initialValue: skill.enabled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HarnessErrorBanner()
                HarnessCard {
                    VStack(alignment: .leading, spacing: 15) {
                        TextField("Skill name", text: $name).font(.title3)
                        Divider()
                        TextField("What does it help you do?", text: $description, axis: .vertical).lineLimit(2...4)
                        Divider()
                        TextField("Keywords, separated by commas", text: $keywords).font(.subheadline)
                        Toggle("Enabled", isOn: $enabled)
                    }
                }
                SectionEyebrow(title: "Requested capabilities")
                CapabilityTags(capabilities: skill.requiredCapabilities)
                Text("Editing a skill does not grant native execution or network permission.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary)
                SectionEyebrow(title: "SKILL.md", trailing: "v\(skill.version)")
                TextEditor(text: $markdown).font(.system(.subheadline, design: .monospaced))
                    .scrollContentBackground(.hidden).frame(minHeight: 340)
                    .padding(12).background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                if model.state.skills.contains(where: { $0.id == skill.id }) {
                    Button("Delete skill", role: .destructive) { confirmDelete = true }
                }
            }.padding(22)
        }
        .navigationTitle(skill.name.isEmpty ? "New skill" : "Inspect skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var updated = skill
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.description = description
                    updated.markdown = markdown
                    updated.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    updated.enabled = enabled
                    Task { await model.saveSkill(updated); if model.error == nil { dismiss() } }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || markdown.isEmpty)
            }
        }
        .confirmationDialog("Delete this skill?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete skill", role: .destructive) { Task { await model.removeSkill(skill.id); if model.error == nil { dismiss() } } }
        } message: { Text("It will no longer be available for future tasks. Existing session history stays visible.") }
        .harnessScreen()
    }
}
