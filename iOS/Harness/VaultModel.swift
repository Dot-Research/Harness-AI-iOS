import SwiftUI
import HarnessCore

/// The Vault's state for the UI. Notes are plain Markdown files: by default in
/// On My iPhone › Harness › Vault (visible in Files), or in a folder you pick, such as an Obsidian vault.
@MainActor
final class VaultModel: ObservableObject {
    @Published private(set) var index = VaultIndex(notes: []) {
        didSet { backlinkCounts = index.backlinkCounts() }
    }
    @Published private(set) var backlinkCounts: [VaultPath: Int] = [:]
    @Published private(set) var folders: [VaultPath] = []
    @Published private(set) var policy = VaultAccessPolicy()
    @Published private(set) var locationName = "On this iPhone"
    @Published private(set) var usesCustomFolder = false
    @Published private(set) var loaded = false
    @Published var error: String?

    let store: VaultStore
    private var scopedURL: URL?
    private static let bookmarkKey = "vault.folderBookmark"

    static var defaultRoot: URL {
        let documents = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Vault", isDirectory: true)
    }

    init() {
        var root = Self.defaultRoot
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataOptions: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               url.startAccessingSecurityScopedResource() {
                root = url
                scopedURL = url
                usesCustomFolder = true
                locationName = url.lastPathComponent
                if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey) }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            }
        }
        store = VaultStore(root: root)
    }

    var noteCount: Int { index.count }
    var summary: String { "\(noteCount) Markdown \(noteCount == 1 ? "file" : "files") · \(usesCustomFolder ? locationName : "on this iPhone")" }

    func refresh() async {
        do {
            let firstRun = !usesCustomFolder && !FileManager.default.fileExists(atPath: Self.defaultRoot.path)
            try await store.prepare()
            if firstRun { try await seedWelcomeNote() }
            index = try await store.index()
            folders = try await store.folders()
            policy = await store.accessPolicy()
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Notes

    func read(_ path: VaultPath) async throws -> VaultDocument { try await store.read(path) }

    func save(_ path: VaultPath, text: String, expected: Date?) async throws -> Date {
        let modified = try await store.write(path, text: text, expectedModified: expected)
        index = (try? await store.index()) ?? index
        return modified
    }

    func newNote(in folder: VaultPath? = nil, title: String = "Untitled") async -> VaultPath? {
        await perform { try await self.store.createNote(title: title, in: folder) }
    }

    func today() async -> VaultPath? {
        await perform { try await self.store.dailyNote() }
    }

    func newFolder(_ name: String, in parent: VaultPath? = nil) async {
        _ = await perform { try await self.store.createFolder(name, in: parent) }
    }

    func rename(_ path: VaultPath, to title: String) async -> VaultPath? {
        await perform { try await self.store.rename(path, to: title).path }
    }

    func move(_ path: VaultPath, to folder: VaultPath?) async -> VaultPath? {
        await perform { try await self.store.move(path, to: folder) }
    }

    func delete(_ path: VaultPath) async {
        _ = await perform { try await self.store.delete(path) }
    }

    /// Opens (or creates) the note a `[[link]]` points at.
    func open(link target: String, from source: VaultPath?) async -> VaultPath? {
        if let existing = index.resolve(target, from: source) { return existing }
        let name = target.split(separator: "/").last.map(String.init) ?? target
        return await perform { try await self.store.createNote(title: name, in: source?.parent) }
    }

    // MARK: Agent access

    func agentsCanRead(_ folder: String) -> Bool { policy.agentReadable.contains(folder) }

    func setAgentsCanRead(_ folder: String, _ readable: Bool) async {
        _ = await perform { try await self.store.setAgentAccess(folder, readable: readable) }
    }

    // MARK: Location

    /// Uses a folder chosen in Files (for example an existing Obsidian vault) as the vault.
    func useFolder(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else { error = "Harness couldn't open that folder."; return }
        do {
            let bookmark = try url.bookmarkData()
            scopedURL?.stopAccessingSecurityScopedResource()
            scopedURL = url
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            await store.open(root: url)
            usesCustomFolder = true
            locationName = url.lastPathComponent
            await refresh()
        } catch {
            url.stopAccessingSecurityScopedResource()
            self.error = error.localizedDescription
        }
    }

    func useDefaultFolder() async {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        await store.open(root: Self.defaultRoot)
        usesCustomFolder = false
        locationName = "On this iPhone"
        await refresh()
    }

    // MARK: Helpers

    private func perform<T>(_ work: @escaping () async throws -> T) async -> T? {
        do {
            let result = try await work()
            index = try await store.index()
            folders = try await store.folders()
            policy = await store.accessPolicy()
            return result
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func seedWelcomeNote() async throws {
        _ = try await store.createNote(title: "Welcome", text: """
        Your vault is plain Markdown files on this iPhone. Open them in Files under On My iPhone › Harness › Vault, or pick another folder (an Obsidian vault works) from the ••• menu.

        - Link notes with double brackets: [[Ideas]]. Tapping a link to a note that doesn't exist creates it.
        - Tag with #hashtags and search everything from the search field.
        - Notes that link here show up under Backlinks.
        - Tick tasks in the preview:
        - [ ] Write the first note

        Agents can't read anything here until you allow it, folder by folder: long-press a folder and choose “Let agents read”. GOD can then search and quote those notes; everything else stays private.
        """)
    }
}
