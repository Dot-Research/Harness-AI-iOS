import SwiftUI
import HarnessCore

/// The persisted Social timeline keeps the original route type for existing navigation links.
struct RedView: View {
    @StateObject private var social = SocialModel()
    @State private var showAccount = false
    @State private var showFind = false
    @State private var showLibrary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 22)
                SocialMessageBanner()
                if social.isConnected {
                    SocialComposer().padding(.bottom, 18)
                    feedPicker
                    if social.items.isEmpty && !social.isLoading {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(social.mode == .following ? "Make this feed yours." : "The conversation starts here.")
                                .font(.title2.weight(.semibold))
                            Text(social.mode == .following ? "Follow people from their profiles to bring their posts and reposts into this timeline." : "Publish a thought or find someone by their handle. Posts appear here in time order.")
                                .foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                            Button("Find someone") { showFind = true }.font(.subheadline.weight(.semibold))
                        }.padding(.vertical, 30)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(social.items) { item in
                            SocialPostRow(post: item.post, repostedBy: item.repostedBy)
                        }
                    }
                    if social.isLoading { ProgressView().frame(maxWidth: .infinity).padding(22) }
                    if social.nextCursor != nil && !social.isLoading {
                        Button("Load earlier posts") { Task { await social.refresh(loadMore: true) } }
                            .frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, 8)
                    }
                } else {
                    disconnected
                }
            }
            .padding(22).frame(maxWidth: 740).frame(maxWidth: .infinity)
        }
        .refreshable { await social.refresh() }
        .navigationTitle("Social").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Social account", systemImage: "person.crop.circle") { showAccount = true }
                    if social.isConnected { Button("Find someone", systemImage: "magnifyingglass") { showFind = true } }
                    Button("Skill library", systemImage: "square.stack") { showLibrary = true }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("Social options")
            }
        }
        .navigationDestination(for: SocialRoute.self) { route in
            switch route {
            case .thread(let id): SocialThreadView(postID: id).environmentObject(social)
            case .profile(let handle): SocialProfileView(handle: handle).environmentObject(social)
            }
        }
        .sheet(isPresented: $showAccount) { NavigationStack { SocialAccountView().environmentObject(social) } }
        .sheet(isPresented: $showFind) { NavigationStack { SocialFindView().environmentObject(social) } }
        .sheet(isPresented: $showLibrary) { NavigationStack { SocialDiscoveryView() } }
        .environmentObject(social)
        .socialScreen()
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Social").font(.system(size: 44, weight: .bold)).tracking(-1.8)
                Text("A little more conversation.").foregroundStyle(HarnessTheme.secondary)
            }
            Spacer(minLength: 10)
            Button { showAccount = true } label: {
                if let account = social.account { SocialAvatar(profile: account) }
                else {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2).foregroundStyle(HarnessTheme.purple)
                        .frame(width: 48, height: 48).background(HarnessTheme.purple.opacity(0.1), in: Circle())
                }
            }.accessibilityLabel("Social account")
        }
    }
    private var feedPicker: some View {
        HStack(spacing: 26) {
            ForEach(SocialFeedMode.allCases, id: \.self) { mode in
                Button { Task { await social.selectMode(mode) } } label: {
                    VStack(spacing: 12) {
                        Text(mode.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(social.mode == mode ? HarnessTheme.text : HarnessTheme.secondary)
                        Capsule().fill(social.mode == mode ? HarnessTheme.purple : .clear).frame(height: 3)
                    }
                }.buttonStyle(.plain).accessibilityAddTraits(social.mode == mode ? .isSelected : [])
            }
            Spacer(minLength: 0)
            Text("LATEST FIRST").font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(HarnessTheme.secondary).padding(.bottom, 14)
        }.overlay(alignment: .bottom) { Rectangle().fill(HarnessTheme.border).frame(height: 1) }
    }
    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 20) {
            StatusPill(title: "NOT CONNECTED", symbol: "network", color: HarnessTheme.purple)
            Text("Find your people.\nBring your thoughts.")
                .font(.system(size: 30, weight: .semibold)).tracking(-0.8)
            Text("Connect to a Social service to post, reply, follow people, and join conversations. Your account belongs to the service you choose.")
                .foregroundStyle(HarnessTheme.secondary).lineSpacing(5)
            Button { showAccount = true } label: {
                Label("Connect to Social", systemImage: "arrow.right").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).tint(HarnessTheme.purple).foregroundStyle(HarnessTheme.background)
            Text("No service has been bundled with this build. Add an HTTPS address from your community. Existing drafts return when you sign in to the same account and service.")
                .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
        }.padding(.vertical, 28)
    }
}

enum SocialRoute: Hashable { case thread(String), profile(String) }

private struct SocialAvatar: View {
    let profile: SocialProfile
    var size: CGFloat = 42
    var body: some View {
        Text(String(profile.displayName.prefix(1)).uppercased())
            .font(.system(size: size * 0.43, weight: .medium))
            .foregroundStyle(HarnessTheme.purple)
            .frame(width: size, height: size)
            .background(HarnessTheme.purple.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(HarnessTheme.purple.opacity(0.23), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct SocialMessageBanner: View {
    @EnvironmentObject private var social: SocialModel
    var body: some View {
        if let text = social.error ?? social.notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: social.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                Text(text).font(.caption).lineSpacing(3).textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    social.error = nil; social.notice = nil
                } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }
                    .accessibilityLabel("Dismiss Social message")
            }.foregroundStyle(social.error == nil ? HarnessTheme.purple : HarnessTheme.coral)
                .padding(12).background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 12)).padding(.bottom, 14)
        }
    }
}

private struct SocialComposer: View {
    @EnvironmentObject private var social: SocialModel
    var parentID: String? = nil
    var onPublished: () async -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = social.account {
                HStack(spacing: 10) {
                    SocialAvatar(profile: account, size: 30)
                    Text("@" + account.handle).font(.caption.weight(.medium)).foregroundStyle(HarnessTheme.secondary)
                    Spacer()
                    Text("DRAFT · THIS IPHONE").font(.system(size: 9, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                }
            }
            TextField(parentID == nil ? "What's on your mind?" : "Add to the conversation…", text: Binding(
                get: { social.draft(parentID).text },
                set: { social.updateDraft($0, parentID: parentID) }
            ), axis: .vertical)
                .lineLimit(3...10).font(.body).lineSpacing(5)
                .accessibilityLabel(parentID == nil ? "Write a post" : "Write a reply")
            HStack {
                Text("\(social.draft(parentID).characterCount)/500")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(social.draft(parentID).characterCount > 500 ? HarnessTheme.coral : HarnessTheme.secondary)
                Spacer()
                Button {
                    Task { if await social.publish(parentID: parentID) != nil { await onPublished() } }
                } label: {
                    HStack(spacing: 8) {
                        if social.isPublishing { ProgressView().tint(HarnessTheme.background) }
                        Text(parentID == nil ? "Post" : "Reply").font(.subheadline.weight(.semibold))
                    }.padding(.horizontal, 15).frame(minHeight: 40)
                }.buttonStyle(.borderedProminent).tint(HarnessTheme.purple).foregroundStyle(HarnessTheme.background)
                    .disabled(!social.draft(parentID).canPublish || social.isPublishing || !social.isConnected)
            }
        }.padding(17).background(HarnessTheme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(HarnessTheme.border, lineWidth: 1))
    }
}

private struct SocialPostRow: View {
    @EnvironmentObject private var social: SocialModel
    let post: SocialPost
    var repostedBy: SocialProfile? = nil
    var linksToThread = true
    var onUpdate: (SocialPost) -> Void = { _ in }
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reposter = repostedBy {
                NavigationLink(value: SocialRoute.profile(reposter.handle)) {
                    Label("\(reposter.displayName) reposted", systemImage: "arrow.2.squarepath")
                        .font(.caption).foregroundStyle(HarnessTheme.secondary)
                }.buttonStyle(.plain).padding(.leading, 53)
            }
            HStack(alignment: .top, spacing: 12) {
                NavigationLink(value: SocialRoute.profile(post.author.handle)) { SocialAvatar(profile: post.author) }
                    .buttonStyle(.plain).accessibilityLabel("View \(post.author.displayName)'s profile")
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        NavigationLink(value: SocialRoute.profile(post.author.handle)) {
                            Text(post.author.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(HarnessTheme.text).lineLimit(1)
                        }.buttonStyle(.plain)
                        Text("@" + post.author.handle).font(.caption).foregroundStyle(HarnessTheme.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(post.date, style: .relative).font(.caption2).foregroundStyle(HarnessTheme.secondary).lineLimit(1)
                    }
                    if linksToThread {
                        NavigationLink(value: SocialRoute.thread(post.id)) { content }
                            .buttonStyle(.plain)
                    } else { content.textSelection(.enabled) }
                    HStack(spacing: 22) {
                        NavigationLink(value: SocialRoute.thread(post.id)) {
                            Label(post.replyCount == 0 ? "" : String(post.replyCount), systemImage: "bubble")
                        }.accessibilityLabel("\(post.replyCount) replies. Open conversation")
                        Button { Task { if let updated = await social.react(post, like: false) { onUpdate(updated) } } } label: {
                            Label(post.repostCount == 0 ? "" : String(post.repostCount), systemImage: "arrow.2.squarepath")
                                .foregroundStyle(post.reposted ? HarnessTheme.purple : HarnessTheme.secondary)
                        }.accessibilityLabel("\(post.reposted ? "Undo repost" : "Repost"). \(post.repostCount) reposts")
                        Button { Task { if let updated = await social.react(post, like: true) { onUpdate(updated) } } } label: {
                            Label(post.likeCount == 0 ? "" : String(post.likeCount), systemImage: post.liked ? "heart.fill" : "heart")
                                .foregroundStyle(post.liked ? HarnessTheme.purple : HarnessTheme.secondary)
                        }.accessibilityLabel("\(post.liked ? "Unlike" : "Like"). \(post.likeCount) likes")
                        Spacer(minLength: 0)
                        if social.account?.id == post.author.id && !post.deleted {
                            Button { confirmDelete = true } label: { Image(systemName: "trash").frame(minWidth: 30, minHeight: 36) }
                                .accessibilityLabel("Delete your post")
                        }
                    }.font(.caption).foregroundStyle(HarnessTheme.secondary).buttonStyle(.plain)
                        .frame(minHeight: 40)
                        .disabled(post.deleted || social.busyPosts.contains(post.id))
                }
            }
        }.padding(.vertical, 18)
            .overlay(alignment: .bottom) { Rectangle().fill(HarnessTheme.border).frame(height: 1) }
            .confirmationDialog("Delete this post?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete post", role: .destructive) { Task { if let updated = await social.delete(post) { onUpdate(updated) } } }
            } message: { Text("The text will be removed. Other people's replies stay in the conversation.") }
    }
    private var content: some View {
        Text(post.deleted ? "This post was deleted." : post.text)
            .font(.body).foregroundStyle(post.deleted ? HarnessTheme.secondary : HarnessTheme.text)
            .lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

private struct SocialThreadView: View {
    @EnvironmentObject private var social: SocialModel
    let postID: String
    @State private var thread: SocialThread?
    @State private var loading = false
    @State private var loadError: String?
    @State private var loadRequest = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SocialMessageBanner()
                if let thread {
                    if let parentID = thread.post.parentID {
                        NavigationLink("View parent conversation", value: SocialRoute.thread(parentID)).font(.subheadline)
                    }
                    SocialPostRow(post: thread.post, linksToThread: false) { updated in self.thread?.post = updated }
                    if !thread.post.deleted && social.isConnected {
                        SocialComposer(parentID: postID) { await load() }
                    }
                    Text("Replies").font(.headline).padding(.top, 6)
                    if thread.replies.isEmpty { Text("Leave the first reply.").font(.subheadline).foregroundStyle(HarnessTheme.secondary) }
                    LazyVStack(spacing: 0) {
                        ForEach(thread.replies) { reply in
                            SocialPostRow(post: reply) { updated in
                                if let index = self.thread?.replies.firstIndex(where: { $0.id == updated.id }) { self.thread?.replies[index] = updated }
                            }
                        }
                    }
                    if thread.nextCursor != nil && !loading { Button("Load more replies") { Task { await load(more: true) } } }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                if let loadError {
                    Text(loadError).font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                    Button("Try again") { Task { await load() } }
                }
            }.padding(22).frame(maxWidth: 740).frame(maxWidth: .infinity)
        }
        .navigationTitle("Conversation").navigationBarTitleDisplayMode(.inline)
        .socialScreen()
        .task(id: social.identity) { thread = nil; await load() }
        .refreshable { await load() }
    }
    private func load(more: Bool = false) async {
        let request = UUID()
        loadRequest = request
        loading = true; loadError = nil
        let identity = social.identity
        defer { if loadRequest == request { loading = false } }
        do {
            let result = try await social.fetchThread(postID, after: more ? thread?.nextCursor : nil)
            guard social.identity == identity && loadRequest == request else { return }
            if more, var current = thread {
                let ids = Set(current.replies.map(\.id))
                current.replies.append(contentsOf: result.replies.filter { !ids.contains($0.id) })
                current.post = result.post; current.nextCursor = result.nextCursor
                thread = current
            } else { thread = result }
        } catch { if !(error is CancellationError) && social.identity == identity && loadRequest == request { loadError = error.localizedDescription } }
    }
}

private struct SocialProfileView: View {
    @EnvironmentObject private var social: SocialModel
    let handle: String
    @State private var page: SocialProfilePage?
    @State private var loading = false
    @State private var changing = false
    @State private var loadError: String?
    @State private var loadRequest = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SocialMessageBanner()
                if let page {
                    HStack(alignment: .top) {
                        SocialAvatar(profile: page.profile, size: 64)
                        Spacer()
                        if social.account?.id != page.profile.id {
                            Button(page.profile.following ? "Following" : "Follow") { Task { await change(mute: false) } }
                                .buttonStyle(.borderedProminent).tint(HarnessTheme.purple).foregroundStyle(HarnessTheme.background)
                                .disabled(changing)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(page.profile.displayName).font(.title.bold())
                        Text("@" + page.profile.handle).foregroundStyle(HarnessTheme.secondary)
                    }
                    HStack(spacing: 20) {
                        Text("\(page.profile.followingCount) following")
                        Text("\(page.profile.followerCount) followers")
                    }.font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                    if social.account?.id != page.profile.id {
                        Button(page.profile.muted ? "Unmute this account" : "Mute this account in my feed", systemImage: page.profile.muted ? "speaker.wave.2" : "speaker.slash") {
                            Task { await change(mute: true) }
                        }.font(.caption).disabled(changing)
                    }
                    Divider().overlay(HarnessTheme.border)
                    Text("Recent posts").font(.headline)
                    if page.posts.isEmpty { Text("No posts yet.").foregroundStyle(HarnessTheme.secondary) }
                    LazyVStack(spacing: 0) {
                        ForEach(page.posts) { post in
                            SocialPostRow(post: post) { updated in
                                if let index = self.page?.posts.firstIndex(where: { $0.id == updated.id }) { self.page?.posts[index] = updated }
                            }
                        }
                    }
                    if page.posts.count == 50 { Text("Showing the 50 most recent posts.").font(.caption).foregroundStyle(HarnessTheme.secondary) }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                if let loadError {
                    Text(loadError).foregroundStyle(HarnessTheme.secondary)
                    Button("Try again") { Task { await load() } }
                }
            }.padding(22).frame(maxWidth: 740).frame(maxWidth: .infinity)
        }
        .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
        .socialScreen()
        .task(id: social.identity) { page = nil; await load() }
        .refreshable { await load() }
    }
    private func load() async {
        let request = UUID()
        loadRequest = request
        loading = true; loadError = nil
        let identity = social.identity
        defer { if loadRequest == request { loading = false } }
        do { let result = try await social.fetchProfile(handle); if identity == social.identity && loadRequest == request { page = result } }
        catch { if !(error is CancellationError) && identity == social.identity && loadRequest == request { loadError = error.localizedDescription } }
    }
    private func change(mute: Bool) async {
        guard let profile = page?.profile, !changing else { return }
        changing = true
        if let updated = await social.relationship(profile, mute: mute) { page?.profile = updated }
        changing = false
    }
}

private struct SocialAccountView: View {
    @EnvironmentObject private var social: SocialModel
    @Environment(\.dismiss) private var dismiss
    @State private var service = ""
    @State private var handle = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var createAccount = false
    var body: some View {
        Form {
            if let account = social.account {
                Section {
                    HStack(spacing: 12) {
                        SocialAvatar(profile: account)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(account.displayName).font(.headline)
                            Text("@\(account.handle) · \(social.serviceHost)").font(.caption).foregroundStyle(HarnessTheme.secondary)
                        }
                    }
                    Button("Sign out", role: .destructive) { Task { await social.signOut() } }.disabled(social.isAuthenticating)
                } footer: { Text("Your drafts remain on this iPhone, saved separately for this account and service.") }
            } else {
                Section {
                    TextField("https://social.example.com", text: $service)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Social service address")
                } header: { Text("Your community's Social address") }
                  footer: { Text("Use an HTTPS service you trust. Posts are shared with other accounts on that service. Your agent workspace and device connections stay separate.") }
                Section {
                    Picker("Account", selection: $createAccount) {
                        Text("Sign in").tag(false)
                        Text("Create account").tag(true)
                    }.pickerStyle(.segmented)
                    TextField("Handle", text: $handle).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if createAccount { TextField("Display name", text: $displayName).textContentType(.name) }
                    SecureField(createAccount ? "Password (12+ characters)" : "Password", text: $password)
                        .textContentType(createAccount ? .newPassword : .password)
                    Button {
                        Task {
                            if await social.signIn(serviceAddress: service, handle: handle, password: password, displayName: createAccount ? displayName : nil) {
                                password = ""; dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Text(createAccount ? "Create account" : "Sign in")
                            Spacer()
                            if social.isAuthenticating { ProgressView() }
                        }
                    }.disabled(social.isAuthenticating || service.isEmpty || handle.isEmpty || password.isEmpty || (createAccount && displayName.isEmpty))
                }
            }
            if social.error != nil || social.notice != nil { Section { SocialMessageBanner() } }
        }
        .scrollContentBackground(.hidden).socialScreen()
        .navigationTitle("Social account").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .onAppear { service = social.serviceAddress }
    }
}

private struct SocialFindView: View {
    @EnvironmentObject private var social: SocialModel
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    var body: some View {
        Form {
            Section {
                TextField("@handle", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Find a Social handle")
                NavigationLink("View profile") { SocialProfileView(handle: handle).environmentObject(social) }
                    .disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("Find someone on \(social.serviceHost)") }
            if let account = social.account {
                Section { NavigationLink("My profile") { SocialProfileView(handle: account.handle).environmentObject(social) } }
            }
        }
        .navigationTitle("Find someone").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).socialScreen()
        .navigationDestination(for: SocialRoute.self) { route in
            switch route {
            case .thread(let id): SocialThreadView(postID: id).environmentObject(social)
            case .profile(let handle): SocialProfileView(handle: handle).environmentObject(social)
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
    }
}

private extension View {
    func socialScreen() -> some View {
        foregroundStyle(HarnessTheme.text)
            .background(HarnessTheme.background)
            .toolbarBackground(HarnessTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(HarnessTheme.purple)
    }
}
