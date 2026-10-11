import XCTest
@testable import HarnessCore

final class VaultParsingTests: XCTestCase {
    func testPathsRejectTraversalHiddenAndEmptyComponents() {
        XCTAssertEqual(VaultPath("Projects/Harness/Roadmap.md")?.title, "Roadmap")
        XCTAssertEqual(VaultPath("/Daily/2026-10-09.md/")?.rawValue, "Daily/2026-10-09.md")
        for bad in ["", "../etc/passwd", "a/../b.md", ".obsidian/app.json", "a//b.md", "a/.trash/x.md", "a\\b.md", " padded.md"] {
            XCTAssertNil(VaultPath(bad), bad)
        }
        XCTAssertEqual(VaultPath("Projects/Roadmap.md")?.topFolder, "Projects")
        XCTAssertNil(VaultPath("Inbox.md")?.topFolder)
    }

    func testFrontmatterLinksTagsTasksAndCodeAreParsed() {
        let text = """
        ---
        status: active
        tags: [harness, mvp]
        agents:
          - GOD
          - Coder
        ---
        # Roadmap
        Prove the core loop. See [[Pricing]] and [[Projects/Harness/Permission Kernel#Rules|the kernel]].
        Embedded: ![[Diagram]] and a [markdown link](Launch%20Plan.md). #roadmap #2026 ignored-#notatag
        - [ ] Ship keyboard
        - [x] Pair computer
        `[[NotALink]] #notatag` stays code.
        ```
        [[AlsoNotALink]] #nope
        ```
        """
        let note = MarkdownNote.parse(text, fallbackTitle: "Roadmap")
        XCTAssertEqual(note.title, "Roadmap")
        XCTAssertEqual(note.property("status"), .text("active"))
        XCTAssertEqual(note.property("agents"), .list(["GOD", "Coder"]))
        XCTAssertEqual(note.links.map(\.target), ["Pricing", "Projects/Harness/Permission Kernel", "Diagram", "Launch Plan.md"])
        XCTAssertEqual(note.links[1].heading, "Rules")
        XCTAssertEqual(note.links[1].alias, "the kernel")
        XCTAssertTrue(note.links[2].isEmbed)
        XCTAssertEqual(Set(note.tags), ["roadmap", "harness", "mvp"])
        XCTAssertEqual(note.openTasks, 1)
        XCTAssertEqual(note.doneTasks, 1)
        XCTAssertEqual(note.headings, ["Roadmap"])
        XCTAssertFalse(note.body.contains("status: active"))
    }

    func testTextWithoutClosingFrontmatterIsAllBody() {
        let note = MarkdownNote.parse("---\njust a rule\n\nmore", fallbackTitle: "N")
        XCTAssertTrue(note.frontmatter.isEmpty)
        XCTAssertTrue(note.body.hasPrefix("---"))
    }
}

final class VaultIndexTests: XCTestCase {
    private func summary(_ path: String, _ text: String, modified: Date = Date()) -> VaultNoteSummary {
        let vaultPath = VaultPath(path)!
        return VaultNoteSummary(path: vaultPath, modified: modified, size: text.utf8.count, note: MarkdownNote.parse(text, fallbackTitle: vaultPath.title))
    }

    func testResolutionPrefersSameFolderThenShortestPath() {
        let index = VaultIndex(notes: [
            summary("Projects/Harness/Pricing.md", ""), summary("Clients/Pricing.md", ""),
            summary("Pricing.md", ""), summary("Projects/Harness/Roadmap.md", "[[Pricing]]"),
        ])
        XCTAssertEqual(index.resolve("Pricing", from: VaultPath("Projects/Harness/Roadmap.md")), VaultPath("Projects/Harness/Pricing.md"))
        XCTAssertEqual(index.resolve("pricing", from: VaultPath("Daily/x.md")), VaultPath("Pricing.md"))
        XCTAssertEqual(index.resolve("Clients/Pricing"), VaultPath("Clients/Pricing.md"))
        XCTAssertEqual(index.resolve("Harness/Pricing.md"), VaultPath("Projects/Harness/Pricing.md"))
        XCTAssertNil(index.resolve("Missing"))
    }

    func testBacklinksUnresolvedLinksTagsAndSearch() {
        let old = Date(timeIntervalSinceNow: -86_400 * 60)
        let index = VaultIndex(notes: [
            summary("Projects/Roadmap.md", "Tiers live in [[Pricing]]. Next: [[Launch Plan]] #mvp"),
            summary("Pricing.md", "Free and Pro tiers. #mvp #pricing", modified: old),
            summary("Daily/2026-10-08.md", "Talked about [[Pricing|price points]] with Dana"),
        ])
        let backlinks = index.backlinks(to: VaultPath("Pricing.md")!)
        XCTAssertEqual(backlinks.map(\.source.rawValue), ["Daily/2026-10-08.md", "Projects/Roadmap.md"])
        XCTAssertTrue(backlinks[0].context.contains("price points"))
        XCTAssertEqual(index.unresolvedLinks(in: VaultPath("Projects/Roadmap.md")!).map(\.target), ["Launch Plan"])
        XCTAssertEqual(index.backlinkCounts()[VaultPath("Pricing.md")!], 2)
        XCTAssertNil(index.backlinkCounts()[VaultPath("Projects/Roadmap.md")!])
        XCTAssertEqual(index.tags.first?.tag, "mvp")
        XCTAssertEqual(index.tags.first?.count, 2)

        let hits = index.search("pricing tiers")
        XCTAssertEqual(hits.first?.path.rawValue, "Pricing.md") // title match outranks body mentions
        XCTAssertEqual(Set(hits.map(\.path.rawValue)), ["Pricing.md", "Projects/Roadmap.md"])
        XCTAssertTrue(index.search("dana").first?.snippet.contains("Dana") ?? false)
        XCTAssertTrue(index.search("pricing", where: { $0.topFolder == "Daily" }).allSatisfy { $0.path.topFolder == "Daily" })
        XCTAssertTrue(index.search("   ").isEmpty)
    }

    private func rewrite(_ text: String, in source: String, from old: String, to new: String, notes: [VaultNoteSummary]) -> String {
        let before = VaultIndex(notes: notes)
        let after = before.moving(VaultPath(old)!, to: VaultPath(new)!)
        return VaultLinkRewriter.rewrite(text, in: VaultPath(source)!, from: VaultPath(old)!, to: VaultPath(new)!, before: before, after: after)
    }

    func testRenameRewritesOnlyLinksToTheRenamedNote() {
        let notes = [summary("Pricing.md", ""), summary("Other.md", ""), summary("Plan.md", "")]
        let text = "See [[Pricing]], [[Pricing#Tiers|tiers]], [[Other]], [p](Pricing.md#Pro) and `[[Pricing]]`.\r\n```\n[[Pricing]]\n```\n"
        let rewritten = rewrite(text, in: "Plan.md", from: "Pricing.md", to: "Plans and Pricing.md", notes: notes)
        XCTAssertEqual(rewritten, "See [[Plans and Pricing]], [[Plans and Pricing#Tiers|tiers]], [[Other]], [p](Plans%20and%20Pricing.md#Pro) and `[[Pricing]]`.\r\n```\n[[Pricing]]\n```\n")
    }

    func testMovedLinksStillPointAtTheMovedNote() {
        // Moving Projects/Pricing to the root while Clients/Pricing exists: a bare [[Pricing]] from
        // Clients/Deal would open Clients/Pricing, so the rewrite uses a vault-absolute link.
        let notes = [summary("Projects/Pricing.md", ""), summary("Clients/Pricing.md", ""), summary("Clients/Deal.md", "[[Projects/Pricing]]")]
        let rewritten = rewrite("[[Projects/Pricing]]", in: "Clients/Deal.md", from: "Projects/Pricing.md", to: "Pricing.md", notes: notes)
        XCTAssertEqual(rewritten, "[[/Pricing]]")
        let after = VaultIndex(notes: notes).moving(VaultPath("Projects/Pricing.md")!, to: VaultPath("Pricing.md")!)
        XCTAssertEqual(after.resolve("/Pricing", from: VaultPath("Clients/Deal.md")), VaultPath("Pricing.md"))
        XCTAssertEqual(after.resolve("Pricing", from: VaultPath("Clients/Deal.md")), VaultPath("Clients/Pricing.md"))
    }
}

final class VaultStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateReadWriteAndConflictDetection() async throws {
        let store = VaultStore(root: root)
        try await store.prepare()
        let first = try await store.createNote(title: "Roadmap", text: "# Roadmap\n")
        let second = try await store.createNote(title: "Roadmap")
        XCTAssertEqual(first.rawValue, "Roadmap.md")
        XCTAssertEqual(second.rawValue, "Roadmap 1.md")

        let document = try await store.read(first)
        let saved = try await store.write(first, text: "# Roadmap\nShip it.", expectedModified: document.modified)
        // Someone else edits the file after we read it.
        try await Task.sleep(nanoseconds: 20_000_000)
        try "Edited in Files".write(to: root.appendingPathComponent("Roadmap.md"), atomically: true, encoding: .utf8)
        do {
            try await store.write(first, text: "Mine", expectedModified: saved)
            XCTFail("Expected a conflict")
        } catch VaultError.conflict { }
        let reread = try await store.read(first)
        XCTAssertEqual(reread.text, "Edited in Files")
    }

    func testNamesAreSanitizedAndFoldersCreated() async throws {
        let store = VaultStore(root: root)
        let path = try await store.createNote(title: "  ../Q3: plan [draft]?.md ", in: VaultPath("Projects/Harness"))
        XCTAssertEqual(path.rawValue, "Projects/Harness/Q3 plan draft.md")
        let folder = try await store.createFolder("Clients", in: nil)
        XCTAssertEqual(folder.rawValue, "Clients")
        let folders = try await store.folders().map(\.rawValue)
        XCTAssertEqual(folders, ["Clients", "Projects", "Projects/Harness"])
        do { _ = try await store.createNote(title: "///"); XCTFail("Expected invalid name") } catch VaultError.invalidName { }
    }

    func testRenameUpdatesLinksInOtherNotes() async throws {
        let store = VaultStore(root: root)
        let pricing = try await store.createNote(title: "Pricing", text: "Tiers")
        let roadmap = try await store.createNote(title: "Roadmap", in: VaultPath("Projects"), text: "See [[Pricing]] and [[Pricing#Pro|Pro]].")
        let result = try await store.rename(pricing, to: "Plans")
        XCTAssertEqual(result.path.rawValue, "Plans.md")
        XCTAssertEqual(result.updatedNotes, 1)
        let updatedText = try await store.read(roadmap).text
        XCTAssertEqual(updatedText, "See [[Plans]] and [[Plans#Pro|Pro]].")
        do { _ = try await store.read(pricing); XCTFail("Old path should be gone") } catch VaultError.notFound { }
        let index = try await store.index()
        XCTAssertEqual(index.backlinks(to: result.path).count, 1)
    }

    func testDeleteMovesToTrashAndHiddenOrLinkedFilesAreIgnored() async throws {
        let store = VaultStore(root: root)
        let note = try await store.createNote(title: "Scratch", text: "x")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent(".obsidian/app.md"), atomically: true, encoding: .utf8)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).md")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.md"), withDestinationURL: outside)

        let titles = try await store.index().notes.keys.map(\.rawValue)
        XCTAssertEqual(titles, ["Scratch.md"])
        do { _ = try await store.read(VaultPath("Link.md")!); XCTFail("Symbolic links must not be read") } catch VaultError.unsupported { }

        try await store.delete(note)
        let afterDelete = try await store.index()
        XCTAssertEqual(afterDelete.count, 0)
        let trash = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".trash").path)
        XCTAssertEqual(trash.count, 1)
        XCTAssertTrue(trash[0].hasSuffix("Scratch.md"))
    }

    func testDailyNoteIsCreatedOnce() async throws {
        let store = VaultStore(root: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = ISO8601DateFormatter().date(from: "2026-10-10T05:00:00Z")! // Oct 9 in Los Angeles
        let path = try await store.dailyNote(for: date, calendar: calendar)
        XCTAssertEqual(path.rawValue, "Daily/2026-10-09.md")
        try await store.write(path, text: "Notes", expectedModified: nil)
        _ = try await store.dailyNote(for: date, calendar: calendar)
        let text = try await store.read(path).text
        XCTAssertEqual(text, "Notes")
    }

    func testAgentsSeeOnlyFoldersMarkedReadable() async throws {
        let store = VaultStore(root: root)
        _ = try await store.createNote(title: "Roadmap", in: VaultPath("Projects"), text: "Launch pricing tiers")
        _ = try await store.createNote(title: "Acme", in: VaultPath("Clients"), text: "Acme pricing is confidential")
        _ = try await store.createNote(title: "Inbox", text: "pricing idea")

        let none = try await store.agentSearch("pricing", limit: 10)
        XCTAssertTrue(none.isEmpty, "Private by default")

        try await store.setAgentAccess("Projects", readable: true)
        let hits = try await store.agentSearch("pricing", limit: 10).map(\.path.rawValue)
        XCTAssertEqual(hits, ["Projects/Roadmap.md"])
        let roadmap = try await store.agentRead("Roadmap")
        XCTAssertEqual(roadmap.text, "Launch pricing tiers")
        do { _ = try await store.agentRead("Clients/Acme.md"); XCTFail("Private folder") } catch VaultError.notReadable { }
        do { _ = try await store.agentRead("Inbox"); XCTFail("Root is private until allowed") } catch VaultError.notReadable { }
        // A private note and a missing one get the same answer, so names can't be probed.
        do { _ = try await store.agentRead("Does Not Exist"); XCTFail("Missing") } catch VaultError.notReadable { }

        try await store.setAgentAccess(VaultAccessPolicy.rootKey, readable: true)
        let inbox = try await store.agentRead("Inbox.md")
        XCTAssertEqual(inbox.text, "pricing idea")
        try await store.setAgentAccess("Projects", readable: false)
        do { _ = try await store.agentRead("Roadmap"); XCTFail("Revoked") } catch VaultError.notReadable { }
    }

    func testPrivateNotesCantShadowReadableOnes() async throws {
        let store = VaultStore(root: root)
        _ = try await store.createNote(title: "Roadmap", in: VaultPath("Clients"), text: "private plan")
        _ = try await store.createNote(title: "Roadmap", in: VaultPath("Projects"), text: "shared plan")
        try await store.setAgentAccess("Projects", readable: true)
        let note = try await store.agentRead("Roadmap")
        XCTAssertEqual(note.text, "shared plan")
    }

    func testNonUTF8NotesAreRefusedRatherThanDamaged() async throws {
        let store = VaultStore(root: root)
        try await store.prepare()
        let latin1 = "- [ ] café".data(using: .isoLatin1)!
        try latin1.write(to: root.appendingPathComponent("Old.md"))
        do { _ = try await store.read(VaultPath("Old.md")!); XCTFail("Expected refusal") } catch VaultError.unsupported { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Old.md")), latin1)
    }

    func testSymlinkedFoldersAreNotFollowedForWrites() async throws {
        let store = VaultStore(root: root)
        try await store.prepare()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Daily"), withDestinationURL: outside)
        do { _ = try await store.dailyNote(); XCTFail("Expected refusal") } catch VaultError.unsupported { }
        do { _ = try await store.createNote(title: "X", in: VaultPath("Daily")); XCTFail("Expected refusal") } catch VaultError.unsupported { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
}

final class VaultRuntimeTests: XCTestCase {
    func testAgentToolsReadOnlyReadableFoldersAndReportPrivateNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = VaultStore(root: root)
        _ = try await vault.createNote(title: "Roadmap", in: VaultPath("Projects"), text: "Ship the keyboard first.")
        _ = try await vault.createNote(title: "Acme", in: VaultPath("Clients"), text: "Confidential terms")
        try await vault.setAgentAccess("Projects", readable: true)

        var state = HarnessSeed.makeState(); state.learningMode = .off
        let store = RuntimeTestStore(state)
        let provider = SequenceModel(responses: [
            ModelResponse(content: "", toolCalls: [
                ToolCall(id: "search", name: "vault_search", arguments: ["query": .string("keyboard")]),
                ToolCall(id: "read", name: "vault_read", arguments: ["path": .string("Projects/Roadmap.md")]),
                ToolCall(id: "private", name: "vault_read", arguments: ["path": .string("Clients/Acme.md")]),
            ]),
            ModelResponse(content: "The roadmap ships the keyboard first."),
        ])
        let runtime = AgentRuntime(store: store, providers: [provider], vault: vault)
        let session = try await runtime.run(input: "What's first on my roadmap?", sessionID: UUID(), permissionHandler: { _, _ in .allowOnce })
        let results = Dictionary(uniqueKeysWithValues: session.messages.filter { $0.role == .tool }.map { ($0.toolCallID ?? "", $0.content) })
        XCTAssertTrue(results["search"]?.contains("Projects/Roadmap.md") ?? false)
        XCTAssertTrue(results["read"]?.contains("Ship the keyboard first.") ?? false)
        XCTAssertTrue(results["private"]?.contains("folders agents can read") ?? false)
        XCTAssertFalse(results.values.contains { $0.contains("Confidential terms") })
        XCTAssertEqual(session.messages.last?.content, "The roadmap ships the keyboard first.")

        let requests = await provider.captured()
        XCTAssertTrue(requests[0].tools.contains { $0.name == "vault_read" })
        let withoutVault = AgentRuntime(store: store, providers: [SequenceModel(responses: [ModelResponse(content: "ok")])])
        _ = withoutVault // tools are only offered when a vault is attached; covered below
        let other = SequenceModel(responses: [ModelResponse(content: "ok")])
        _ = try await AgentRuntime(store: store, providers: [other]).run(input: "hi", sessionID: UUID(), permissionHandler: { _, _ in .allowOnce })
        let otherRequests = await other.captured()
        XCTAssertFalse(otherRequests[0].tools.contains { $0.name.hasPrefix("vault_") })
    }
}
