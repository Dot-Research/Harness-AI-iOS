import SwiftUI
import UniformTypeIdentifiers
import HarnessCore

struct IntelligenceView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("An agent that\nknows its context.").font(.system(.largeTitle, design: .serif))
                Text("Keep personality, preferences, environment, and workspace instructions separate. Inspect every change.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                HarnessCard {
                    VStack(spacing: 15) {
                        NavigationLink { AgentFilesView() } label: {
                            SettingsRow(symbol: "doc.text", title: "Agent files", subtitle: "SOUL · USER · MEMORY · AGENTS")
                        }
                        Divider()
                        NavigationLink { LearningView() } label: {
                            SettingsRow(symbol: "leaf", title: "Learning", subtitle: "\(model.state.learningMode.rawValue) · \(model.state.proposals.count) pending", color: HarnessTheme.green)
                        }
                        Divider()
                        NavigationLink { SkillsView() } label: {
                            SettingsRow(symbol: "books.vertical", title: "Skills", subtitle: "Reusable methods, retrieved when relevant")
                        }
                    }.buttonStyle(.plain)
                }
                HarnessCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("A restricted reviewer", systemImage: "lock.shield").font(.subheadline.weight(.medium)).foregroundStyle(HarnessTheme.green)
                        Text("Learning can propose memory or skill changes. It cannot send messages, control devices, or inherit external action permissions.")
                            .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Intelligence").navigationBarTitleDisplayMode(.inline).harnessScreen()
    }
}

struct AgentFilesView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Four files.\nFour different jobs.").font(.system(.largeTitle, design: .serif))
                ForEach(AgentFile.allCases, id: \.self) { file in
                    NavigationLink { AgentFileEditor(file: file) } label: {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Image(systemName: "doc.text").foregroundStyle(HarnessTheme.amber)
                                    Text(file.rawValue).font(.system(.body, design: .monospaced).weight(.medium))
                                    Spacer()
                                    Image(systemName: "arrow.up.right").foregroundStyle(HarnessTheme.secondary)
                                }
                                Text(description(for: file)).font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                                Text("\((model.state.files[file.rawValue] ?? "").count) characters · stored locally")
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                Text("File content may be included in model context when you send a request. Your routing choice determines its destination.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Agent files").navigationBarTitleDisplayMode(.inline).harnessScreen()
    }

    private func description(for file: AgentFile) -> String {
        switch file {
        case .soul: "Personality, principles, and communication style."
        case .user: "Durable preferences and how you like to work."
        case .memory: "Facts about your environment, projects, and devices."
        case .agents: "Instructions for this agent and its workspace."
        }
    }
}

private struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .text] }
    static var writableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct AgentFileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let file: AgentFile
    @State private var text = ""
    @State private var loaded = false
    @State private var importing = false
    @State private var exporting = false
    @State private var fileError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                StatusPill(title: "LOCAL CONTEXT", symbol: "doc.text", color: HarnessTheme.amber)
                Spacer()
                Text("\(text.count) chars").font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
            }
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden).padding(10)
                .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("\(file.rawValue) content")
            Text("Imported text stays in this editor until you save it. Keep credentials out of agent context.")
                .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
        }.padding(22)
        .navigationTitle(file.rawValue).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Import Markdown", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Export Markdown", systemImage: "square.and.arrow.up") { exporting = true }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("File import and export")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { Task { await model.saveFile(file, text: text); if model.error == nil { dismiss() } } }
            }
        }
        .onAppear {
            if !loaded { text = model.state.files[file.rawValue] ?? ""; loaded = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText, .text]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 128 * 1024, let imported = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                text = imported
            } catch { fileError = "Could not import this file. Choose UTF-8 Markdown under 128 KB. \(error.localizedDescription)" }
        }
        .fileExporter(isPresented: $exporting, document: MarkdownDocument(text: text), contentType: UTType(filenameExtension: "md") ?? .plainText, defaultFilename: file.rawValue) { result in
            if case .failure(let error) = result { fileError = error.localizedDescription }
        }
        .alert("File operation failed", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK") { fileError = nil }
        } message: { Text(fileError ?? "") }
        .harnessScreen()
    }
}

struct LearningView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: LearningProposal?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Learn together.\nKeep the last word.").font(.system(.largeTitle, design: .serif))
                HarnessCard {
                    VStack(alignment: .leading, spacing: 17) {
                        Text("Learning mode").font(.subheadline.weight(.medium))
                        Picker("Learning mode", selection: Binding(get: { model.state.learningMode }, set: { mode in Task { await model.setLearningMode(mode) } })) {
                            ForEach(LearningMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                        }.pickerStyle(.segmented)
                        Text(modeDescription).font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                SectionEyebrow(title: "Waiting for your review", trailing: "\(model.state.proposals.count)")
                if model.state.proposals.isEmpty {
                    HarnessEmptyState(symbol: "leaf", title: "Nothing to learn just yet.", detail: "After meaningful turns, a restricted reviewer looks for durable preferences, useful facts, and reusable methods. Proposed changes will appear here.")
                }
                ForEach(model.state.proposals) { proposal in
                    HarnessCard {
                        VStack(alignment: .leading, spacing: 17) {
                            StatusPill(title: targetLabel(proposal.target), symbol: "leaf", color: HarnessTheme.green)
                            Text(proposal.title).font(.system(.title3, design: .serif))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("EVIDENCE").font(.system(.caption2, design: .monospaced)).tracking(1.4).foregroundStyle(HarnessTheme.amber)
                                Text(proposal.evidence).font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                            }
                            DisclosureGroup("Review proposed diff") { LearningDiff(before: proposal.before, after: proposal.after).padding(.top, 12) }
                                .font(.subheadline)
                            HStack(spacing: 17) {
                                Button("Save") { Task { await model.approveLearning(proposal.id) } }
                                    .buttonStyle(.borderedProminent).tint(HarnessTheme.coral)
                                Button("Edit") { editing = proposal }
                                Spacer(minLength: 0)
                                Button("Reject", role: .destructive) { Task { await model.rejectLearning(proposal.id) } }
                            }.font(.subheadline)
                        }
                    }
                }
                NavigationLink { JourneyView() } label: {
                    HarnessCard { SettingsRow(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "See your Journey", subtitle: "Every applied change stays visible") }
                }.buttonStyle(.plain)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Learning").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { proposal in NavigationStack { LearningEditView(proposal: proposal) } }
        .harnessScreen()
    }
    private var modeDescription: String {
        switch model.state.learningMode {
        case .off: "The learning reviewer is paused. Existing memories and skills remain available."
        case .ask: "You approve every proposed learning change. This is the default for new users."
        case .automatic: "Low-risk learning may be applied automatically. Changes remain visible and reversible in Journey."
        }
    }
}

private func targetLabel(_ target: LearningProposal.Target) -> String {
    switch target {
    case .user: "USER.md UPDATE"
    case .memory: "MEMORY.md UPDATE"
    case .newSkill: "NEW SKILL"
    case .skillPatch: "SKILL IMPROVEMENT"
    }
}

struct LearningDiff: View {
    let before: String
    let after: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !before.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("− BEFORE").font(.system(.caption2, design: .monospaced).weight(.semibold))
                    Text(before).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }.foregroundStyle(HarnessTheme.coral).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(HarnessTheme.coral.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("+ AFTER").font(.system(.caption2, design: .monospaced).weight(.semibold))
                Text(after.isEmpty ? "(empty)" : after).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.foregroundStyle(HarnessTheme.green).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(HarnessTheme.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct LearningEditView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let proposal: LearningProposal
    @State private var text: String
    init(proposal: LearningProposal) { self.proposal = proposal; _text = State(initialValue: proposal.after) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HarnessErrorBanner()
            Text(proposal.title).font(.system(.title2, design: .serif))
            Text("Review and edit the complete proposed content before saving.").font(.caption).foregroundStyle(HarnessTheme.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(10).background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }.padding(22)
        .navigationTitle("Edit learning").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await model.approveLearning(proposal.id, edited: text); if model.error == nil { dismiss() } } }
            }
        }.harnessScreen()
    }
}

struct JourneyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var reverting: JourneyEntry?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Becoming more yours.").font(.system(.largeTitle, design: .serif))
                Text("A visible history of learning and instruction changes. Reverting restores the earlier content when it is still safe to do so.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                if model.state.journey.isEmpty {
                    HarnessEmptyState(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "The beginning of your Journey.", detail: "Approve a learning proposal or edit your agent context to start a visible history. No activity is invented here.")
                }
                ForEach(model.state.journey.sorted(by: { $0.date > $1.date })) { entry in
                    HarnessCard {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                                Spacer()
                                if entry.reverted { StatusPill(title: "Reverted", symbol: "arrow.uturn.backward", color: HarnessTheme.secondary) }
                            }
                            Text(entry.title).font(.system(.title3, design: .serif))
                            DisclosureGroup("View diff") { LearningDiff(before: entry.proposal.before, after: entry.proposal.after).padding(.top, 10) }
                                .font(.subheadline)
                            if !entry.reverted {
                                currentContentEditor(for: entry)
                                Button { reverting = entry } label: { Label("Revert change", systemImage: "arrow.uturn.backward") }.font(.subheadline)
                            }
                        }
                    }
                }
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Journey").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Revert this change?", isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } }), titleVisibility: .visible) {
            if let entry = reverting {
                Button("Restore earlier content", role: .destructive) { Task { await model.revertLearning(entry.id); reverting = nil } }
            }
            Button("Cancel", role: .cancel) { reverting = nil }
        } message: { Text("Later edits are checked before reverting. Your history keeps a record of the reversal.") }
        .harnessScreen()
    }

    @ViewBuilder private func currentContentEditor(for entry: JourneyEntry) -> some View {
        switch entry.proposal.target {
        case .user:
            NavigationLink { AgentFileEditor(file: .user) } label: { Label("Edit current content", systemImage: "square.and.pencil") }.font(.subheadline)
        case .memory:
            NavigationLink { AgentFileEditor(file: .memory) } label: { Label("Edit current content", systemImage: "square.and.pencil") }.font(.subheadline)
        case .newSkill, .skillPatch:
            if let skill = model.state.skills.first(where: { $0.id == entry.proposal.skillID }) {
                NavigationLink { SkillEditorView(skill: skill) } label: { Label("Edit or remove skill", systemImage: "square.and.pencil") }.font(.subheadline)
            }
        }
    }
}
