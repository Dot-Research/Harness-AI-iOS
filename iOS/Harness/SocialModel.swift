import Foundation
import SwiftUI
import HarnessCore

@MainActor
final class SocialModel: ObservableObject {
    @Published private(set) var serviceAddress: String
    @Published private(set) var account: SocialProfile?
    @Published private(set) var items: [SocialFeedItem] = []
    @Published private(set) var nextCursor: Int?
    @Published private(set) var mode: SocialFeedMode = .all
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isPublishing = false
    @Published private(set) var busyPosts: Set<String> = []
    @Published private(set) var archive = SocialDraftArchive()
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var identity = UUID()
    private var client: SocialClient?
    private var feedRequest = UUID()
    private var draftsURL: URL?
    private var draftsPersisted = true
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serviceAddress = defaults.string(forKey: "social.serviceAddress") ?? ""
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Harness/Social", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("drafts.json")
            draftsURL = url
            if FileManager.default.fileExists(atPath: url.path) { archive = try JSONDecoder().decode(SocialDraftArchive.self, from: Data(contentsOf: url)) }
        } catch { draftsURL = nil; draftsPersisted = false; self.error = "Your Social drafts could not be loaded. \(error.localizedDescription)" }
        Task { await restoreSession() }
    }
    var isConnected: Bool { account != nil && client != nil }
    var serviceHost: String { URL(string: serviceAddress)?.host ?? "Your Social service" }
    private func credentialKey(_ service: String) -> String { "social.session:" + service }
    private func scope(_ parentID: String?) -> String {
        SocialDraft.scope(service: serviceAddress, account: account?.id ?? "disconnected", parentID: parentID)
    }
    func draft(_ parentID: String? = nil) -> SocialDraft { archive.draft(scope: scope(parentID), parentID: parentID) }
    func updateDraft(_ text: String, parentID: String? = nil) {
        guard isConnected else { return }
        archive.update(text, scope: scope(parentID), parentID: parentID)
        persistDrafts()
    }
    private func persistDrafts() {
        guard let draftsURL else { draftsPersisted = false; error = "Draft storage is unavailable. Copy your text before leaving Social."; return }
        do {
            try JSONEncoder().encode(archive).write(to: draftsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            draftsPersisted = true
        } catch { draftsPersisted = false; self.error = "This draft remains on screen, but could not be saved on this iPhone. \(error.localizedDescription)" }
    }
    private func restoreSession() async {
        guard !serviceAddress.isEmpty else { return }
        let generation = identity
        do {
            let service = try SocialServiceURL(serviceAddress)
            guard let value = try KeychainStore.shared.token(for: credentialKey(serviceAddress)),
                  let data = value.data(using: .utf8) else { return }
            let saved = try JSONDecoder().decode(SocialSession.self, from: data)
            guard saved.expiresAt > Date().timeIntervalSince1970 else {
                try KeychainStore.shared.remove(credentialKey(serviceAddress)); return
            }
            let remote = SocialClient(service: service, token: saved.token)
            let profile = try await remote.me()
            guard identity == generation else { return }
            client = remote; account = profile
            await refresh()
        } catch {
            guard identity == generation else { return }
            self.error = "Sign in to reconnect to Social. \(error.localizedDescription)"
        }
    }
    func signIn(serviceAddress: String, handle: String, password: String, displayName: String?) async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true; error = nil; notice = nil
        identity = UUID()
        let generation = identity
        defer { if identity == generation { isAuthenticating = false } }
        do {
            let service = try SocialServiceURL(serviceAddress)
            let remote = SocialClient(service: service)
            let session = try await remote.signIn(handle: handle, password: password, displayName: displayName)
            guard identity == generation else { return false }
            let encoded = try JSONEncoder().encode(session)
            guard let value = String(data: encoded, encoding: .utf8) else { throw SocialError(status: 0, message: "The session could not be stored.") }
            try KeychainStore.shared.set(value, for: credentialKey(service.url.absoluteString))
            self.serviceAddress = service.url.absoluteString
            defaults.set(self.serviceAddress, forKey: "social.serviceAddress")
            client = SocialClient(service: service, token: session.token)
            account = session.profile
            items = []; nextCursor = nil; busyPosts = []; isPublishing = false
            await refresh()
            return true
        } catch {
            if identity == generation { self.error = error.localizedDescription }
            return false
        }
    }
    func signOut() async {
        guard !isAuthenticating else { return }
        let remote = client
        let oldAddress = serviceAddress
        identity = UUID(); feedRequest = UUID()
        let generation = identity
        isAuthenticating = true
        do {
            try KeychainStore.shared.remove(credentialKey(oldAddress))
        } catch {
            self.error = error.localizedDescription; isAuthenticating = false; return
        }
        client = nil; account = nil; items = []; nextCursor = nil
        busyPosts = []; isLoading = false; isPublishing = false; error = nil
        do { try await remote?.signOut() }
        catch { if identity == generation { notice = "Signed out on this iPhone. The service could not revoke the session; it will expire automatically." } }
        if identity == generation { isAuthenticating = false }
    }
    func selectMode(_ mode: SocialFeedMode) async {
        guard self.mode != mode else { return }
        self.mode = mode; items = []; nextCursor = nil
        await refresh()
    }
    func refresh(loadMore: Bool = false) async {
        guard let client else { return }
        if loadMore && (isLoading || nextCursor == nil) { return }
        let generation = identity
        let requestID = UUID()
        feedRequest = requestID
        let cursor = loadMore ? nextCursor : nil
        let selectedMode = mode
        isLoading = true
        defer { if identity == generation && feedRequest == requestID { isLoading = false } }
        do {
            let page = try await client.feed(selectedMode, before: cursor)
            guard identity == generation && feedRequest == requestID && mode == selectedMode else { return }
            if loadMore {
                let old = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !old.contains($0.id) })
            } else { items = page.items }
            nextCursor = page.nextCursor
        } catch { report(error, generation: generation) }
    }
    @discardableResult
    func publish(parentID: String? = nil) async -> SocialPost? {
        guard let client, !isPublishing else { return nil }
        let draft = draft(parentID)
        guard draft.canPublish else { return nil }
        let draftScope = scope(parentID)
        let generation = identity
        isPublishing = true; error = nil; notice = nil
        defer { if identity == generation { isPublishing = false } }
        do {
            let post = try await client.publish(draft)
            // A response for another account can acknowledge only that account's exact stored draft.
            archive.acknowledge(scope: draftScope, idempotencyKey: draft.idempotencyKey)
            persistDrafts()
            guard identity == generation else { return nil }
            notice = parentID == nil ? "Posted to \(serviceHost)." : "Reply posted."
            await refresh()
            return post
        } catch {
            report(error, generation: generation, suffix: draftsPersisted
                ? " Your draft is saved. Retry to confirm this same post without creating a duplicate."
                : " Your draft remains on screen. Copy it before leaving. Retry this same draft to avoid a duplicate.")
            return nil
        }
    }
    func fetchThread(_ id: String, after: Int? = nil) async throws -> SocialThread {
        guard let client else { throw SocialError(status: 401, message: "Sign in to read this conversation.") }
        let generation = identity
        let thread = try await client.thread(id, after: after)
        guard generation == identity else { throw CancellationError() }
        return thread
    }
    func fetchProfile(_ handle: String) async throws -> SocialProfilePage {
        guard let client else { throw SocialError(status: 401, message: "Sign in to view profiles.") }
        let generation = identity
        let profile = try await client.profile(handle)
        guard generation == identity else { throw CancellationError() }
        return profile
    }
    func react(_ post: SocialPost, like: Bool) async -> SocialPost? {
        guard let client, !busyPosts.contains(post.id) else { return nil }
        let generation = identity
        busyPosts.insert(post.id)
        defer { if identity == generation { busyPosts.remove(post.id) } }
        do {
            let updated = try await (like ? client.setLike(post.id, enabled: !post.liked) : client.setRepost(post.id, enabled: !post.reposted))
            guard generation == identity else { return nil }
            replace(updated)
            if !like { await refresh() }
            return updated
        } catch { report(error, generation: generation); return nil }
    }
    func delete(_ post: SocialPost) async -> SocialPost? {
        guard let client, account?.id == post.author.id, !busyPosts.contains(post.id) else { return nil }
        let generation = identity
        busyPosts.insert(post.id)
        defer { if identity == generation { busyPosts.remove(post.id) } }
        do {
            let deleted = try await client.delete(post.id)
            guard generation == identity else { return nil }
            items.removeAll { $0.post.id == post.id }
            return deleted
        } catch { report(error, generation: generation); return nil }
    }
    func relationship(_ profile: SocialProfile, mute: Bool) async -> SocialProfile? {
        guard let client else { return nil }
        let generation = identity
        do {
            let changed = try await (mute ? client.setMute(profile.handle, enabled: !profile.muted) : client.setFollow(profile.handle, enabled: !profile.following))
            guard generation == identity else { return nil }
            await refresh()
            return changed
        } catch { report(error, generation: generation); return nil }
    }
    private func replace(_ post: SocialPost) {
        for index in items.indices where items[index].post.id == post.id { items[index].post = post }
    }
    private func report(_ error: Error, generation: UUID, suffix: String = "") {
        guard generation == identity, !(error is CancellationError) else { return }
        self.error = error.localizedDescription + suffix
    }
}
