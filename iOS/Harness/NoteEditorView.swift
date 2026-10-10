import SwiftUI
import HarnessCore

struct NoteEditorView: View {
    @ObservedObject var vault: VaultModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Set in the two-pane layout to switch notes in place; when nil, links push a new editor.
    var openNote: ((VaultPath) -> Void)?
    var onDeleted: (() -> Void)?

    @State private var path: VaultPath
    @State private var text = ""
    @State private var modified: Date?
    @State private var loaded = false
    @State private var editing = false
    @State private var dirty = false
    @State private var conflict = false
    @State private var selection: TextSelection?
    @State private var saveTask: Task<Void, Never>?
    @State private var pushed: VaultPath?
    @State private var renaming = false
    @State private var newName = ""
    @State private var moving = false
    @State private var confirmDelete = false
    @State private var tag: TagSelection?
    @FocusState private var editorFocused: Bool

    init(vault: VaultModel, path: VaultPath, openNote: ((VaultPath) -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        self.vault = vault
        self.openNote = openNote
        self.onDeleted = onDeleted
        _path = State(initialValue: path)
    }

    private var parsed: ParsedNote { MarkdownNote.parse(text, fallbackTitle: path.title) }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().tint(HarnessTheme.coral).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if editing {
                editor
            } else {
                preview
            }
        }
        .navigationTitle(path.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task(id: path) { await load() }
        .onDisappear { saveNow() }
        .navigationDestination(item: $pushed) { NoteEditorView(vault: vault, path: $0) }
        .environment(\.openURL, OpenURLAction { handle($0) })
        .alert("Rename note", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await rename() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Links to this note in other notes are updated.") }
        .confirmationDialog("Move “\(path.title)” to the trash?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { Task { await delete() } }
        } message: { Text("It goes to the vault's .trash folder, which you can open in Files.") }
        .sheet(isPresented: $moving) { FolderPicker(vault: vault, current: path.parent) { folder in Task { await move(to: folder) } } }
        .sheet(item: $tag) { TagNotesView(vault: vault, tag: $0.name) { opened in tag = nil; open(opened) } }
        .harnessScreen()
    }

    // MARK: Preview

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    if let folder = path.parent {
                        Label(folder.rawValue.replacingOccurrences(of: "/", with: " / "), systemImage: "folder")
                    }
                    if let modified {
                        Text("Edited \(modified, format: .relative(presentation: .named))")
                    }
                }
                .font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                if conflict { conflictBanner }
                if !parsed.frontmatter.isEmpty { properties }
                if parsed.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { startEditing() } label: {
                        Text("Empty note. Tap to write.").foregroundStyle(HarnessTheme.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    }.buttonStyle(.plain)
                } else {
                    MarkdownPreview(text: text) { line in
                        text = MarkdownBlocks.toggleTask(in: text, line: line)
                        changed()
                    }
                }
                backlinks
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var properties: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsed.frontmatter.enumerated()), id: \.offset) { _, property in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(property.key).font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(property.value.displayText).font(.subheadline)
                }
            }
        }
        .padding(14)
        .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var backlinks: some View {
        let links = vault.index.backlinks(to: path)
        return VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Backlinks", trailing: links.isEmpty ? nil : "\(links.count)")
            if links.isEmpty {
                Text("No other notes link here yet. Link to this note with [[\(path.title)]].")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary)
            }
            ForEach(links) { link in
                Button { open(link.source) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(link.title).font(.subheadline.weight(.medium)).foregroundStyle(HarnessTheme.text)
                        Text(link.context).font(.caption).foregroundStyle(HarnessTheme.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
    }

    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This note changed in another app.", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.medium)).foregroundStyle(HarnessTheme.amber)
            HStack(spacing: 20) {
                Button("Use the other version") { Task { await load() } }
                Button("Keep mine") { Task { await save(overwrite: true) } }
            }.font(.subheadline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HarnessTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            if conflict { conflictBanner.padding(.horizontal, 16).padding(.top, 8) }
            TextEditor(text: Binding(get: { text }, set: { text = $0; changed() }), selection: $selection)
                .font(.body)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(.horizontal, 16)
                .accessibilityLabel("Note text")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button { insert("[[]]", cursorAfter: 2) } label: { Text("[[ ]]").font(.system(.body, design: .monospaced)) }
                    .accessibilityLabel("Insert link")
                Button { insert("#") } label: { Image(systemName: "number") }.accessibilityLabel("Insert tag")
                Button { insert("- [ ] ") } label: { Image(systemName: "checkmark.square") }.accessibilityLabel("Insert task")
                Button { insert("## ") } label: { Image(systemName: "textformat.size") }.accessibilityLabel("Insert heading")
                Button { insert("****", cursorAfter: 2) } label: { Image(systemName: "bold") }.accessibilityLabel("Bold")
                Spacer()
                Button("Done") { stopEditing() }.fontWeight(.semibold)
            }
        }
    }

    private func insert(_ snippet: String, cursorAfter: Int? = nil) {
        var updated = text
        var offset = updated.count
        if let selection, case let .selection(range) = selection.indices,
           range.lowerBound >= updated.startIndex, range.upperBound <= updated.endIndex {
            offset = updated.distance(from: updated.startIndex, to: range.lowerBound)
            updated.replaceSubrange(range, with: snippet)
        } else {
            updated += snippet
        }
        text = updated
        let cursor = updated.index(updated.startIndex, offsetBy: min(updated.count, offset + (cursorAfter ?? snippet.count)))
        selection = TextSelection(insertionPoint: cursor)
        changed()
    }

    private func startEditing() {
        editing = true
        editorFocused = true
    }

    private func stopEditing() {
        editorFocused = false
        editing = false
        saveNow()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(editing ? "Done" : "Edit") { editing ? stopEditing() : startEditing() }
                .fontWeight(editing ? .semibold : .regular)
                .disabled(!loaded)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { askGOD() } label: { Label("Ask GOD about this note", systemImage: "sparkle") }
                Button { newName = path.title; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                Button { moving = true } label: { Label("Move to…", systemImage: "folder") }
                ShareLink(item: text, subject: Text(path.title)) { Label("Share text", systemImage: "square.and.arrow.up") }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Move to Trash", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Note actions")
                .disabled(!loaded)
        }
    }

    // MARK: Actions

    private func load() async {
        saveTask?.cancel()
        do {
            let document = try await vault.read(path)
            text = document.text
            modified = document.modified
            dirty = false
            conflict = false
            if document.text.isEmpty && !loaded { editing = true; editorFocused = true }
        } catch {
            vault.error = error.localizedDescription
        }
        loaded = true
    }

    private func changed() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save(overwrite: Bool = false) async {
        guard dirty || overwrite else { return }
        do {
            modified = try await vault.save(path, text: text, expected: overwrite ? nil : modified)
            dirty = false
            conflict = false
        } catch VaultError.conflict {
            conflict = true
        } catch {
            vault.error = error.localizedDescription
        }
    }

    /// Saves right away (leaving the screen, Done). Captures values so it survives the view going away.
    private func saveNow() {
        saveTask?.cancel()
        guard dirty, !conflict else { return }
        let snapshot = text, target = path, expected = modified, vault = vault
        dirty = false
        Task {
            do { _ = try await vault.save(target, text: snapshot, expected: expected) }
            catch VaultError.conflict { vault.error = "\(target.title) changed in another app, so your last edits weren't saved over it." }
            catch { vault.error = error.localizedDescription }
        }
    }

    private func open(_ destination: VaultPath) {
        saveNow()
        if let openNote { openNote(destination) } else { pushed = destination }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "harness-vault" else { return .systemAction }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.host == "open", let target = items.first(where: { $0.name == "target" })?.value {
            Task { if let destination = await vault.open(link: target, from: path) { open(destination) } }
        } else if url.host == "tag", let name = items.first(where: { $0.name == "name" })?.value {
            tag = TagSelection(name: name)
        }
        return .handled
    }

    private func rename() async {
        // Finish saving before the file moves, so the save can't land on the old path.
        saveTask?.cancel()
        await save()
        if let renamed = await vault.rename(path, to: newName) { path = renamed }
    }

    private func move(to folder: VaultPath?) async {
        saveTask?.cancel()
        await save()
        if let moved = await vault.move(path, to: folder) { path = moved }
    }

    private func delete() async {
        saveTask?.cancel()
        dirty = false
        await vault.delete(path)
        if let onDeleted { onDeleted() } else { dismiss() }
    }

    private func askGOD() {
        let excerpt = text.count > 4_000 ? String(text.prefix(4_000)) + "\n[…]" : text
        model.prefillComposer("About my note “\(path.title)”:\n\n\(excerpt)")
    }
}

struct TagSelection: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

/// Notes carrying one tag.
struct TagNotesView: View {
    @ObservedObject var vault: VaultModel
    let tag: String
    let open: (VaultPath) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(vault.index.notes(taggedWith: tag)) { summary in
                        Button { open(summary.path) } label: {
                            VaultNoteRow(summary: summary, backlinks: vault.backlinkCounts[summary.path] ?? 0)
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }
            .navigationTitle("#\(tag)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .harnessScreen()
        }
        .presentationDetents([.medium, .large])
    }
}

/// Choose a destination folder.
struct FolderPicker: View {
    @ObservedObject var vault: VaultModel
    let current: VaultPath?
    let choose: (VaultPath?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row(nil, title: "Top of the vault", depth: 0)
                ForEach(vault.folders, id: \.self) { folder in
                    row(folder, title: folder.name, depth: folder.components.count - 1)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Move to").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .harnessScreen()
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ folder: VaultPath?, title: String, depth: Int) -> some View {
        Button {
            dismiss()
            choose(folder)
        } label: {
            HStack {
                Image(systemName: folder == nil ? "tray" : "folder").foregroundStyle(HarnessTheme.amber)
                Text(title).foregroundStyle(HarnessTheme.text)
                Spacer()
                if folder == current { Image(systemName: "checkmark").foregroundStyle(HarnessTheme.coral) }
            }
            .padding(.leading, CGFloat(depth) * 16)
        }
        .listRowBackground(HarnessTheme.surface)
        .disabled(folder == current)
    }
}
