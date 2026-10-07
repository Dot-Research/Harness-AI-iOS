import SwiftUI
import HarnessCore

struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rename = false
    @State private var name = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 62, weight: .ultraLight)).foregroundStyle(HarnessTheme.amber)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Your own intelligence.").font(.system(.title2, design: .serif))
                        Text("Local identity. No account required.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary)
                    }
                }.padding(.vertical, 14)
                HarnessCard {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("A personal node, on your terms.").font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "iphone.gen3").foregroundStyle(HarnessTheme.coral)
                        }
                        Text("Conversations, skills, and learning live on this iPhone. You choose the models and devices that can receive context.")
                            .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                SectionEyebrow(title: "Make it yours")
                HarnessCard {
                    VStack(spacing: 14) {
                        NavigationLink { IntelligenceView() } label: {
                            SettingsRow(symbol: "sparkles", title: "Intelligence", subtitle: "Agent files, learning, and skills")
                        }
                        Divider()
                        NavigationLink { JourneyView() } label: {
                            SettingsRow(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Journey", subtitle: "\(model.state.journey.count) visible changes")
                        }
                        Divider()
                        Button { name = model.state.directorName; rename = true } label: {
                            SettingsRow(symbol: "signature", title: "Your director", subtitle: model.state.directorName)
                        }
                    }.buttonStyle(.plain)
                }
                SectionEyebrow(title: "Connections & trust")
                HarnessCard {
                    VStack(spacing: 14) {
                        NavigationLink { ProvidersView() } label: {
                            SettingsRow(symbol: "cpu", title: "Models & providers", subtitle: model.state.routingPreference.rawValue, color: HarnessTheme.coral)
                        }
                        Divider()
                        NavigationLink { DevicesView() } label: {
                            SettingsRow(symbol: "desktopcomputer", title: "Devices", subtitle: "\(model.state.devices.count) paired computers", color: HarnessTheme.coral)
                        }
                        Divider()
                        NavigationLink { PrivacyView() } label: {
                            SettingsRow(symbol: "hand.raised", title: "Privacy", subtitle: "See where your information goes", color: HarnessTheme.green)
                        }
                        Divider()
                        NavigationLink { ActivityView() } label: {
                            SettingsRow(symbol: "clock", title: "Activity", subtitle: "Your local audit trail", color: HarnessTheme.green)
                        }
                    }.buttonStyle(.plain)
                }
                SectionEyebrow(title: "Open by design")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Link(destination: URL(string: "https://github.com/zeldangelo/Harness-AI-iOS")!) {
                            Label("Read the source", systemImage: "curlybraces").font(.subheadline.weight(.medium))
                        }
                        Text("Harness is open source. Apple integrations and the system keyboard are future work; this build focuses on the agent loop.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Me").navigationBarTitleDisplayMode(.inline)
        .alert("Rename your director", isPresented: $rename) {
            TextField("Name", text: $name)
            Button("Save") { Task { await model.renameDirector(name) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its role remains General Orchestration Director.") }
        .harnessScreen()
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("A record you can read.").font(.system(.title, design: .serif))
                Text("Important actions are recorded locally, including destinations and the selected request context prepared for a provider. Inspect each entry to distinguish authorization from completion.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                if model.state.activity.isEmpty {
                    HarnessEmptyState(symbol: "clock", title: "Nothing to reconstruct yet.", detail: "Model requests, permission decisions, learning changes, and paired-computer actions appear here as they happen.")
                }
                ForEach(model.state.activity.sorted(by: { $0.date > $1.date })) { entry in
                    HarnessCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                .font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                            Text(entry.title).font(.body.weight(.medium))
                            if let destination = entry.destination {
                                Label(destination, systemImage: "arrow.up.right").font(.caption).foregroundStyle(HarnessTheme.coral)
                            }
                            if !entry.detail.isEmpty {
                                DisclosureGroup("Inspect evidence") {
                                    Text(entry.detail).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                                }.font(.subheadline)
                            }
                        }
                    }
                }
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Activity").navigationBarTitleDisplayMode(.inline).harnessScreen()
    }
}
