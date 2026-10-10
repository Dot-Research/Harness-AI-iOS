import SwiftUI
import UniformTypeIdentifiers
import HarnessCore

enum VaultFilter: String, CaseIterable, Identifiable {
    case all = "All", recent = "Recent", daily = "Daily", tags = "Tags", agentFiles = "Agent files"
    var id: String { rawValue }
}

/// The Vault tab: a Markdown notes manager over plain files, with links, backlinks, tags, daily notes
/// and per-folder agent access. Two panes at wide widths (iPhone Duo unfolded), a stack otherwise.
struct VaultView: View {
    @ObservedObject var vault: VaultModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var query = ""
    @State private var filter: VaultFilter = .all
    @State private var isWide = false
    @State private var selected: VaultPath?
    @State private var pushed: VaultPath?
    @State private var newFolderParent: VaultPath?
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var renaming: VaultPath?
    @State private var renameText = ""
    @State private var deleting: VaultPath?
    @State private var tag: TagSelection?
    @State private var choosingFolder = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize
            HStack(spacing: 0) {
                browser.frame(width: wide ? min(360, geometry.size.width * 0.4) : nil)
                if wide {
                    Rectangle().fill(HarnessTheme.border).frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: wide, initial: true) { _, value in isWide = value }
        }
        .navigationTitle("Vault")
        .navigationDestination(item: $pushed) { NoteEditorView(vault: vault, path: $0) }
        .searchable(text: $query, prompt: "Search the vault")
        .toolbar { toolbar }
        .task { await vault.refresh() }
        .refreshable { await vault.refresh() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await vault.useFolder(url) } }
        }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { Task { await vault.newFolder(folderName, in: newFolderParent) } }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Rename note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard let path = renaming else { return }
                Task {
                    if let renamed = await vault.rename(path, to: renameText), selected == path { selected = renamed }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Links to this note in other notes are updated.") }
        .confirmationDialog("Move “\(deleting?.title ?? "")” to the trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let path = deleting else { return }
                Task {
                    await vault.delete(path)
                    if selected == path { selected = nil }
                }
            }
        } message: { Text("It goes to the vault's .trash folder, which you can open in Files.") }
        .sheet(item: $tag) { TagNotesView(vault: vault, tag: $0.name) { opened in tag = nil; open(opened) } }
        .alert("Vault", isPresented: Binding(get: { vault.error != nil }, set: { if !$0 { vault.error = nil } })) {
            Button("OK") { vault.error = nil }
        } message: { Text(vault.error ?? "") }
        .harnessScreen()
    }

    // MARK: Layout

    private var browser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(vault.summary)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchResults
                } else {
                    filters
                    switch filter {
                    case .all:
                        if vault.loaded && vault.noteCount == 0 { emptyState }
                        agentFiles(compact: true)
                        foldersSection
                        recentSection(limit: 6)
                    case .recent: recentSection(limit: nil)
                    case .daily: dailySection
                    case .tags: tagsSection
                    case .agentFiles: agentFiles(compact: false)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            NoteEditorView(vault: vault, path: selected, openNote: { self.selected = $0 }, onDeleted: { self.selected = nil })
                .id(selected)
        } else {
            HarnessEmptyState(symbol: "doc.text", title: "Pick a note.", detail: "Or start one with the pencil. Notes are plain Markdown files you can also open in Files.")
                .padding(40).frame(maxWidth: 520)
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VaultFilter.allCases) { item in
                    Button { filter = item } label: {
                        Text(item.rawValue).font(.subheadline.weight(filter == item ? .semibold : .regular))
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .foregroundStyle(filter == item ? HarnessTheme.background : HarnessTheme.text)
                            .background(filter == item ? HarnessTheme.text : HarnessTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        HarnessEmptyState(symbol: "books.vertical", title: "Your notes, as plain files.",
                          detail: "Write with [[links]] and #tags. Everything stays in Markdown files on this iPhone, and agents read only the folders you allow.")
    }

    private func agentFiles(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Agent files")
            HarnessCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AgentFile.allCases, id: \.self) { file in
                        NavigationLink { AgentFileEditor(file: file) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.plaintext").foregroundStyle(HarnessTheme.coral)
                                Text(file.rawValue).font(.system(.subheadline, design: .monospaced))
                                Spacer(minLength: 4)
                                Text(agentFileDetail(file)).font(.caption).foregroundStyle(HarnessTheme.secondary).lineLimit(1)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(HarnessTheme.secondary)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if !compact {
                        Text("GOD reads these every turn. Changes it proposes wait for you in Learning.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).padding(.top, 8)
                    }
                }
            }
        }
    }

    private func agentFileDetail(_ file: AgentFile) -> String {
        switch file {
        case .soul: return "Personality and tone"
        case .user: return "What it knows about you"
        case .memory: return "Projects, devices, tools"
        case .agents: return "Rules for each agent"
        }
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Folders", trailing: "long-press for options")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(vault.folders.filter { $0.parent == nil }, id: \.self) { folder in
                    FolderNode(vault: vault, folder: folder, actions: actions)
                }
                let rootNotes = vault.index.notes.values.filter { $0.path.parent == nil }.sorted { $0.path < $1.path }
                if !rootNotes.isEmpty {
                    HStack(spacing: 8) {
                        Text("Top level").font(.caption.weight(.medium)).foregroundStyle(HarnessTheme.secondary)
                        AccessBadge(readable: vault.agentsCanRead(VaultAccessPolicy.rootKey))
                    }
                    .padding(.top, 10)
                    .contextMenu { accessMenu(VaultAccessPolicy.rootKey) }
                    ForEach(rootNotes) { summary in noteButton(summary) }
                }
            }
        }
    }

    private func recentSection(limit: Int?) -> some View {
        let notes = vault.index.recent
        return VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Recent")
            ForEach(limit.map { Array(notes.prefix($0)) } ?? notes) { summary in noteButton(summary, showFolder: true) }
        }
    }

    private var dailySection: some View {
        let daily = vault.index.notes.values.filter { $0.path.topFolder == "Daily" }.sorted { $0.path.rawValue > $1.path.rawValue }
        return VStack(alignment: .leading, spacing: 10) {
            Button { Task { if let today = await vault.today() { open(today) } } } label: {
                Label("Today's note", systemImage: "calendar.badge.plus")
            }.buttonStyle(PrimaryButtonStyle())
            SectionEyebrow(title: "Daily notes", trailing: "\(daily.count)")
            ForEach(daily) { summary in noteButton(summary) }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Tags")
            if vault.index.tags.isEmpty {
                Text("Add #tags anywhere in a note, or `tags: [a, b]` at the top.").font(.caption).foregroundStyle(HarnessTheme.secondary)
            }
            ForEach(vault.index.tags, id: \.tag) { entry in
                Button { tag = TagSelection(name: entry.tag) } label: {
                    HStack {
                        Text("#" + entry.tag).foregroundStyle(HarnessTheme.amber)
                        Spacer()
                        Text("\(entry.count)").font(.caption.monospacedDigit()).foregroundStyle(HarnessTheme.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var searchResults: some View {
        let hits = vault.index.search(query)
        return VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Results", trailing: "\(hits.count)")
            if hits.isEmpty {
                Text("No notes match “\(query)”.").font(.subheadline).foregroundStyle(HarnessTheme.secondary)
            }
            ForEach(hits) { hit in
                Button { open(hit.path) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hit.title).font(.subheadline.weight(.medium)).foregroundStyle(HarnessTheme.text)
                        Text(hit.path.rawValue).font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet).font(.caption).foregroundStyle(HarnessTheme.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: Rows and actions

    private var actions: VaultActions {
        VaultActions(
            open: { open($0) },
            newNote: { folder in Task { if let path = await vault.newNote(in: folder) { open(path) } } },
            newFolder: { parent in newFolderParent = parent; folderName = ""; creatingFolder = true },
            rename: { path in renameText = path.title; renaming = path },
            delete: { deleting = $0 },
            askGOD: { path in Task { await askGOD(about: path) } },
            selected: isWide ? selected : nil
        )
    }

    private func noteButton(_ summary: VaultNoteSummary, showFolder: Bool = false) -> some View {
        Button { open(summary.path) } label: {
            VaultNoteRow(summary: summary, backlinks: vault.backlinkCounts[summary.path] ?? 0, showFolder: showFolder,
                         isSelected: isWide && selected == summary.path)
        }
        .buttonStyle(.plain)
        .contextMenu { noteMenu(summary.path, actions: actions) }
    }

    @ViewBuilder private func accessMenu(_ folder: String) -> some View {
        if vault.agentsCanRead(folder) {
            Button { Task { await vault.setAgentsCanRead(folder, false) } } label: { Label("Make private", systemImage: "lock") }
        } else {
            Button { Task { await vault.setAgentsCanRead(folder, true) } } label: { Label("Let agents read", systemImage: "eye") }
        }
    }

    private func open(_ path: VaultPath) {
        if isWide { selected = path } else { pushed = path }
    }

    private func askGOD(about path: VaultPath) async {
        guard let document = try? await vault.read(path) else { return }
        let excerpt = document.text.count > 4_000 ? String(document.text.prefix(4_000)) + "\n[…]" : document.text
        model.prefillComposer("About my note “\(path.title)”:\n\n\(excerpt)")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { actions.newNote(nil) } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("New note")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { Task { if let today = await vault.today() { open(today) } } } label: { Label("Today's note", systemImage: "calendar") }
                Button { actions.newFolder(nil) } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Divider()
                Section("Agents") { accessMenu(VaultAccessPolicy.rootKey) }
                Section("Vault location: \(vault.locationName)") {
                    Button { choosingFolder = true } label: { Label("Use a folder from Files…", systemImage: "folder.badge.gearshape") }
                    if vault.usesCustomFolder {
                        Button { Task { await vault.useDefaultFolder() } } label: { Label("Use On My iPhone › Harness", systemImage: "iphone") }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Vault options")
        }
    }
}

struct VaultActions {
    var open: (VaultPath) -> Void
    var newNote: (VaultPath?) -> Void
    var newFolder: (VaultPath?) -> Void
    var rename: (VaultPath) -> Void
    var delete: (VaultPath) -> Void
    var askGOD: (VaultPath) -> Void
    var selected: VaultPath?
}

@ViewBuilder func noteMenu(_ path: VaultPath, actions: VaultActions) -> some View {
    Button { actions.askGOD(path) } label: { Label("Ask GOD about this note", systemImage: "sparkle") }
    Button { actions.rename(path) } label: { Label("Rename", systemImage: "pencil") }
    Divider()
    Button(role: .destructive) { actions.delete(path) } label: { Label("Move to Trash", systemImage: "trash") }
}

/// A folder with its notes and subfolders, expandable in place.
struct FolderNode: View {
    @ObservedObject var vault: VaultModel
    let folder: VaultPath
    let actions: VaultActions
    @State private var expanded = false

    private var subfolders: [VaultPath] { vault.folders.filter { $0.parent == folder } }
    private var notes: [VaultNoteSummary] { vault.index.notes.values.filter { $0.path.parent == folder }.sorted { $0.path < $1.path } }
    private var noteCount: Int { vault.index.notes.keys.filter { $0.rawValue.hasPrefix(folder.rawValue + "/") }.count }
    private var isTopLevel: Bool { folder.parent == nil }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(subfolders, id: \.self) { child in FolderNode(vault: vault, folder: child, actions: actions) }
                ForEach(notes) { summary in
                    Button { actions.open(summary.path) } label: {
                        VaultNoteRow(summary: summary, backlinks: vault.backlinkCounts[summary.path] ?? 0,
                                     isSelected: actions.selected == summary.path)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { noteMenu(summary.path, actions: actions) }
                }
                if subfolders.isEmpty && notes.isEmpty {
                    Text("Empty").font(.caption).foregroundStyle(HarnessTheme.secondary).frame(minHeight: 36)
                }
            }
            .padding(.leading, 12)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: expanded ? "folder.fill" : "folder").foregroundStyle(HarnessTheme.amber)
                Text(folder.name).font(.subheadline.weight(.medium)).foregroundStyle(HarnessTheme.text)
                if isTopLevel { AccessBadge(readable: vault.agentsCanRead(folder.name)) }
                Spacer(minLength: 4)
                Text("\(noteCount)").font(.caption.monospacedDigit()).foregroundStyle(HarnessTheme.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(HarnessTheme.secondary)
        .contextMenu {
            Button { actions.newNote(folder) } label: { Label("New note here", systemImage: "square.and.pencil") }
            Button { actions.newFolder(folder) } label: { Label("New folder here", systemImage: "folder.badge.plus") }
            if isTopLevel {
                Divider()
                if vault.agentsCanRead(folder.name) {
                    Button { Task { await vault.setAgentsCanRead(folder.name, false) } } label: { Label("Make private", systemImage: "lock") }
                } else {
                    Button { Task { await vault.setAgentsCanRead(folder.name, true) } } label: { Label("Let agents read", systemImage: "eye") }
                }
            }
        }
    }
}

struct AccessBadge: View {
    let readable: Bool
    var body: some View {
        Label(readable ? "Agents can read" : "Private", systemImage: readable ? "eye" : "lock")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(readable ? HarnessTheme.green : HarnessTheme.secondary)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(readable ? "Agents can read this folder" : "Private folder")
    }
}

struct VaultNoteRow: View {
    let summary: VaultNoteSummary
    let backlinks: Int
    var showFolder = false
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.note.title).font(.subheadline.weight(.medium)).foregroundStyle(isSelected ? HarnessTheme.coral : HarnessTheme.text)
                .lineLimit(1)
            HStack(spacing: 6) {
                if showFolder, let folder = summary.path.parent { Text(folder.rawValue) }
                Text(summary.modified, format: .relative(presentation: .named))
                if backlinks > 0 { Text("· \(backlinks) \(backlinks == 1 ? "backlink" : "backlinks")") }
                if summary.note.openTasks > 0 { Text("· \(summary.note.openTasks) open") }
            }
            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 4).padding(.horizontal, isSelected ? 10 : 0)
        .background(isSelected ? HarnessTheme.coral.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}
