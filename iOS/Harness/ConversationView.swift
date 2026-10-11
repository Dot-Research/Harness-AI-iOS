import SwiftUI
import HarnessCore

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft = ""
    @State private var showSessions = false
    @State private var sessionQuery = ""
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 46
    @FocusState private var composerFocused: Bool

    private var messages: [AgentMessage] { model.currentSession?.messages.filter { $0.role != .system } ?? [] }
    private var agentName: String {
        guard let id = model.currentSession?.agentID, id != "god" else { return model.state.directorName }
        return model.state.agents.first { $0.id == id }?.name ?? "Agent"
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                conversation
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                if geometry.size.width >= 720 && !dynamicTypeSize.isAccessibilitySize {
                    Rectangle().fill(HarnessTheme.border).frame(width: 1)
                    workspacePanel.frame(width: 260)
                }
            }
        }
        .navigationTitle(agentName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSessions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("Conversation history")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { AgentsView() } label: { Image(systemName: "square.stack.3d.up") }
                    .accessibilityLabel("Agents")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.newSession() } } label: { Image(systemName: "square.and.pencil") }
                    .disabled(model.isWorking).accessibilityLabel("New conversation")
            }
        }
        .sheet(isPresented: $showSessions) { sessions }
        .onChange(of: model.composerPrefill, initial: true) { _, text in
            guard let text else { return }
            draft = text
            model.composerPrefill = nil
            composerFocused = true
        }
        .harnessScreen()
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if messages.isEmpty { welcome }
                    if !model.state.proposals.isEmpty {
                        NavigationLink { LearningView() } label: {
                            HarnessCard {
                                HStack {
                                    Image(systemName: "leaf").foregroundStyle(HarnessTheme.green)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Something worth remembering").font(.subheadline.weight(.medium))
                                        Text("\(model.state.proposals.count) learning \(model.state.proposals.count == 1 ? "proposal" : "proposals") for your review")
                                            .font(.caption).foregroundStyle(HarnessTheme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right").foregroundStyle(HarnessTheme.secondary)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                    ForEach(messages) { message in
                        MessageView(message: message, agentName: agentName).id(message.id)
                    }
                    if model.isWorking {
                        HStack(spacing: 12) {
                            ProgressView().tint(HarnessTheme.coral)
                            Text("Working through your request…").font(.caption).foregroundStyle(HarnessTheme.secondary)
                        }.padding(.vertical, 10).accessibilityLabel("Agent working")
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }
                .padding(.horizontal, 22).padding(.top, 15)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.sessionID) { _, _ in
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
            .onChange(of: model.isWorking) { _, _ in
                withAnimation { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack {
                StatusPill(title: "YOUR PERSONAL AGENT", symbol: "sparkle", color: HarnessTheme.amber)
                Spacer()
            }
            HarnessMark(size: 78).padding(.top, 15)
            VStack(alignment: .leading, spacing: 14) {
                Text("A little more\npossible.")
                    .font(.system(size: heroSize, weight: .regular, design: .serif))
                    .tracking(-1.6).fixedSize(horizontal: false, vertical: true)
                Text("Think clearly. Get things done.\nBuild an agent that learns with you.")
                    .font(.body).foregroundStyle(HarnessTheme.secondary).lineSpacing(5)
            }
            HarnessCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Image(systemName: "iphone.gen3").foregroundStyle(HarnessTheme.green)
                        Text("Starts with your iPhone.").font(.subheadline.weight(.medium))
                    }
                    Text(model.readinessDescription)
                        .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    NavigationLink { ProvidersView() } label: {
                        Label(model.hasAvailableModel ? "Model settings" : "Choose a model", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(HarnessTheme.coral)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            SectionEyebrow(title: "Start anywhere")
            VStack(spacing: 0) {
                suggestion("Help me make a decision", symbol: "arrow.triangle.branch")
                Divider().overlay(HarnessTheme.border)
                suggestion("What do you remember about me?", symbol: "book.closed")
                Divider().overlay(HarnessTheme.border)
                suggestion("Help me plan my next project", symbol: "square.stack")
            }
        }.padding(.bottom, 10)
    }

    private func suggestion(_ text: String, symbol: String) -> some View {
        Button {
            draft = text
            composerFocused = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).foregroundStyle(HarnessTheme.secondary).frame(width: 22)
                Text(text).font(.subheadline).foregroundStyle(HarnessTheme.text)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(HarnessTheme.secondary)
            }.padding(.vertical, 17)
        }.buttonStyle(.plain)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 11) {
            NavigationLink { ProvidersView() } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.routeUsesAppleModel ? "iphone" : "network")
                        .foregroundStyle(model.hasAvailableModel ? HarnessTheme.green : HarnessTheme.amber)
                    Text(model.routeDescription).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(HarnessTheme.secondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens model and provider settings")
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask \(agentName)…", text: $draft, axis: .vertical)
                    .lineLimit(1...6).font(.body).focused($composerFocused)
                    .textInputAutocapitalization(.sentences).padding(.vertical, 13)
                    .accessibilityLabel("Message to \(agentName)")
                Button {
                    if model.isWorking { model.cancel() }
                    else {
                        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !message.isEmpty else { return }
                        draft = ""
                        composerFocused = false
                        Task { await model.send(message) }
                    }
                } label: {
                    Image(systemName: model.isWorking ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HarnessTheme.background)
                        .frame(width: 44, height: 44)
                        .background(HarnessTheme.coral, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel(model.isWorking ? "Cancel request" : "Send message")
                .disabled(!model.isWorking && (!model.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .opacity(!model.isWorking && (!model.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.4 : 1)
                .padding(.bottom, 4)
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 21))
            .overlay(RoundedRectangle(cornerRadius: 21).stroke(HarnessTheme.border, lineWidth: 1))
        }
        .padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 12)
        .frame(maxWidth: 860).frame(maxWidth: .infinity)
        .background(HarnessTheme.background)
    }

    private var workspacePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionEyebrow(title: "Your workspace")
                Text("A little context.\nA lot of possibility.")
                    .font(.system(.title2, design: .serif)).lineSpacing(3)
                NavigationLink { LearningView() } label: {
                    HarnessCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Image(systemName: "leaf")
                                .font(.title2).foregroundStyle(HarnessTheme.green)
                            Text("Growing with you")
                                .font(.system(.title3, design: .serif))
                            Text(learningSummary)
                                .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                            Label("Learning · \(model.state.learningMode.rawValue)", systemImage: "arrow.up.right")
                                .font(.caption.weight(.medium)).foregroundStyle(HarnessTheme.green)
                        }
                    }
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 12) {
                    SectionEyebrow(title: "In your corner")
                    ForEach(model.state.agents) { agent in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: agent.id == "god" ? "sparkle" : "square.stack.3d.up")
                                .foregroundStyle(agent.id == "god" ? HarnessTheme.coral : HarnessTheme.amber)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(agent.name).font(.subheadline.weight(.medium))
                                Text(model.isWorking && (model.currentSession?.agentID ?? "god") == agent.id ? "Working on your request" : agent.purpose)
                                    .font(.caption).foregroundStyle(HarnessTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.vertical, 5)
                    }
                    NavigationLink { AgentsView() } label: {
                        Label("Explore your agents", systemImage: "arrow.up.right")
                            .font(.caption.weight(.medium)).frame(minHeight: 44)
                    }
                }
                Divider().overlay(HarnessTheme.border)
                NavigationLink { SkillsView() } label: {
                    workspaceLink(symbol: "books.vertical", title: "Skills library",
                                  detail: "\(model.state.skills.filter(\.enabled).count) enabled methods")
                }.buttonStyle(.plain)
                NavigationLink { DevicesView() } label: {
                    workspaceLink(symbol: "desktopcomputer", title: "Your devices",
                                  detail: model.state.devices.isEmpty ? "Pair a computer with QR" : "\(model.state.devices.count) paired computers")
                }.buttonStyle(.plain)
                NavigationLink { PrivacyView() } label: {
                    Label("Your permissions. Your call.", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(HarnessTheme.green)
                        .frame(minHeight: 44)
                }.buttonStyle(.plain)
            }.padding(20)
        }
        .background(HarnessTheme.surface.opacity(0.3))
    }

    private var learningSummary: String {
        if !model.state.proposals.isEmpty {
            return "\(model.state.proposals.count) proposed \(model.state.proposals.count == 1 ? "change is" : "changes are") ready for your review."
        }
        switch model.state.learningMode {
        case .off: return "Learning is paused. Your saved memories and skills are still here."
        case .ask: return "Useful lessons become proposed memories and skills. You approve each change."
        case .automatic: return "Low-risk lessons may be saved automatically. Review and undo changes in Journey."
        }
    }

    private func workspaceLink(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(HarnessTheme.amber)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(HarnessTheme.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(HarnessTheme.secondary)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }

    private var filteredSessions: [AgentSession] {
        model.state.sessions.filter { session in
            sessionQuery.isEmpty || session.title.localizedCaseInsensitiveContains(sessionQuery)
                || session.messages.contains { $0.content.localizedCaseInsensitiveContains(sessionQuery) }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sessions: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if filteredSessions.isEmpty {
                        HarnessEmptyState(symbol: "bubble.left.and.bubble.right",
                                          title: sessionQuery.isEmpty ? "A fresh start." : "No conversations found.",
                                          detail: sessionQuery.isEmpty ? "Your conversation history is stored on this device. Return to it when you need to." : "Try another word or clear your search.")
                    }
                    if model.isWorking {
                        Text("Finish or cancel the current request before switching conversations.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary)
                    }
                    ForEach(filteredSessions) { session in
                        Button {
                            model.selectSession(session.id)
                            showSessions = false
                        } label: {
                            HarnessCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(session.title).font(.body.weight(.medium)).foregroundStyle(HarnessTheme.text)
                                    Text(session.updatedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.caption).foregroundStyle(HarnessTheme.secondary)
                                }
                            }
                        }.buttonStyle(.plain).disabled(model.isWorking)
                    }
                }.padding(22)
            }
            .navigationTitle("Conversations").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $sessionQuery, prompt: "Search local conversations")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSessions = false } } }
            .harnessScreen()
        }.presentationDetents([.medium, .large])
    }
}

private struct MessageView: View {
    let message: AgentMessage
    let agentName: String
    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 28)
                Text(message.content).font(.body).lineSpacing(4).textSelection(.enabled)
                    .padding(17).background(HarnessTheme.raised, in: RoundedRectangle(cornerRadius: 19))
            }
        } else if message.role == .tool {
            DisclosureGroup {
                Text(message.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: {
                Label("Tool result", systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(HarnessTheme.secondary)
            }.padding(15).background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        } else {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle").foregroundStyle(HarnessTheme.coral)
                    Text(agentName.uppercased()).font(.system(.caption2, design: .monospaced)).tracking(1.7)
                }
                Text(message.content).font(.body).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.toolCalls.isEmpty {
                    ForEach(message.toolCalls) { call in
                        Label(call.name, systemImage: "arrow.triangle.branch")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                    }
                }
            }.padding(.vertical, 8)
        }
    }
}
