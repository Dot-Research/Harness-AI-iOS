import SwiftUI
import HarnessCore
import DictationAppKit

enum HarnessTab: String, CaseIterable, Identifiable {
    case god = "Agent", dictation = "Dictation", red = "Red", vault = "Vault", me = "Me"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .god: return "sparkle"
        case .dictation: return "mic"
        case .vault: return "books.vertical"
        case .red: return "circle.hexagongrid"
        case .me: return "person.crop.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var dictation: DictationHost
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            let usesRail = geometry.size.width >= 760 && !dynamicTypeSize.isAccessibilitySize
            // Keep a single TabView mounted so opening more space does not discard
            // an in-progress draft or any tab's navigation history.
            HStack(spacing: 0) {
                if usesRail {
                    navigationRail
                    Rectangle().fill(HarnessTheme.border).frame(width: 1)
                }
                TabView(selection: $model.selectedTab) {
                    ForEach(HarnessTab.allCases) { tab in
                        tabRoot(tab)
                            .tabItem { Label(tab.rawValue, systemImage: tab.symbol) }
                            .tag(tab)
                            .toolbar(usesRail ? .hidden : .visible, for: .tabBar)
                    }
                }
                .toolbarBackground(HarnessTheme.surface, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            }
            .harnessScreen()
        }
        .sheet(item: permissionBinding) { request in
            PermissionSheet(request: request, decision: model.pendingDecision ?? .ask)
                .presentationDetents([.medium, .large])
                .interactiveDismissDisabled()
        }
        .alert("Harness needs your attention", isPresented: errorBinding) {
            Button("OK") { model.clearError() }
        } message: { Text(model.error ?? "") }
    }

    private var navigationRail: some View {
        ScrollView {
            VStack(spacing: 24) {
                HarnessMark(size: 42)
                    .padding(.top, 22)
                Text("HARNESS")
                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                    .tracking(1.1).foregroundStyle(HarnessTheme.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8).accessibilityHidden(true)
                VStack(spacing: 10) {
                    ForEach(HarnessTab.allCases) { tab in
                        Button { model.selectedTab = tab } label: {
                            VStack(spacing: 8) {
                                Image(systemName: tab.symbol).font(.title3)
                                Text(tab.rawValue).font(.caption.weight(.medium))
                            }
                            .foregroundStyle(model.selectedTab == tab ? HarnessTheme.coral : HarnessTheme.secondary)
                            .frame(maxWidth: .infinity, minHeight: 65)
                            .background(model.selectedTab == tab ? HarnessTheme.coral.opacity(0.09) : .clear,
                                        in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.rawValue)
                        .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 22)
        }
        .frame(width: 88)
        .frame(maxHeight: .infinity)
        .background(HarnessTheme.background)
        .accessibilityLabel("Main navigation")
    }

    @ViewBuilder private func tabRoot(_ tab: HarnessTab) -> some View {
        if tab == .dictation {
            // DictationTabView brings its own NavigationStack.
            DictationTabView(host: dictation)
                .scrollContentBackground(.hidden)
                .background(HarnessTheme.background)
        } else {
            NavigationStack { destination(tab) }
        }
    }

    @ViewBuilder private func destination(_ tab: HarnessTab) -> some View {
        switch tab {
        case .god: ConversationView()
        case .dictation: EmptyView()
        case .vault: VaultView(vault: model.vault)
        case .red: RedView()
        case .me: MeView()
        }
    }

    private var permissionBinding: Binding<PermissionRequest?> {
        Binding(get: { model.pendingPermission }, set: { _ in })
    }
    private var errorBinding: Binding<Bool> {
        Binding(get: { model.error != nil }, set: { if !$0 { model.clearError() } })
    }
}

private struct PermissionSheet: View {
    @EnvironmentObject private var model: AppModel
    let request: PermissionRequest
    let decision: PermissionDecision
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                Image(systemName: decision == .biometric ? "faceid" : "hand.raised")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(HarnessTheme.amber)
                Text("You hold the keys.").font(.system(.largeTitle, design: .serif))
                Text("\(request.agentName) requests permission to use \(request.tool.name).")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 12) {
                        StatusPill(title: request.tool.capability.rawValue, symbol: "key.horizontal", color: HarnessTheme.amber)
                        Text(request.detail).font(.subheadline).textSelection(.enabled)
                        Text("Risk: \(request.tool.risk.rawValue)").font(.caption).foregroundStyle(HarnessTheme.secondary)
                    }
                }
                if decision == .biometric {
                    Text("This action also requires device authentication. Your choice cannot bypass it.")
                        .font(.caption).foregroundStyle(HarnessTheme.secondary)
                }
                Button(decision == .biometric ? "Authenticate and allow once" : "Allow once") { model.resolvePermission(.allowOnce) }.buttonStyle(PrimaryButtonStyle())
                HStack {
                    if decision != .biometric {
                        Button { model.resolvePermission(.alwaysAllow) } label: {
                            Text("Always allow").frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }
                    Spacer()
                    Button { model.resolvePermission(.denyOnce) } label: {
                        Text("Deny once").frame(minHeight: 44).contentShape(Rectangle())
                    }
                }.font(.subheadline)
                Button(role: .destructive) { model.resolvePermission(.alwaysDeny) } label: {
                    Text("Always deny").font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
            }.padding(26)
        }.harnessScreen()
    }
}
