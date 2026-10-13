import SwiftUI
import HarnessCore

struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rename = false
    @State private var name = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionEyebrow(title: "Connections & SSH")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 16) {
                        NavigationLink { DevicesView() } label: {
                            SettingsRow(symbol: "laptopcomputer.and.iphone", title: "Connections & SSH", subtitle: connectionSummary, color: HarnessTheme.coral)
                        }
                        Text("Manage the computers and SSH routes Dot can use. You choose each connection's permissions.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }.buttonStyle(.plain)
                }

                SectionEyebrow(title: "Models & providers")
                HarnessCard {
                    NavigationLink { ProvidersView() } label: {
                        SettingsRow(symbol: "cpu", title: "Models & providers", subtitle: model.state.routingPreference.rawValue, color: HarnessTheme.coral)
                    }.buttonStyle(.plain)
                }

                SectionEyebrow(title: "Account & subscription")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 15) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 38, weight: .light)).foregroundStyle(HarnessTheme.amber)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your local identity").font(.body.weight(.medium))
                                Text("Your conversations and preferences live on this iPhone.")
                                    .font(.caption).foregroundStyle(HarnessTheme.secondary)
                            }
                        }
                        Divider()
                        NavigationLink { SubscriptionView() } label: {
                            SettingsRow(symbol: "keyboard", title: "Harness subscription", subtitle: "Includes Speak and the system-wide keyboard", color: HarnessTheme.coral)
                        }
                    }.buttonStyle(.plain)
                }

                SectionEyebrow(title: "Your intelligence")
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

                SectionEyebrow(title: "Privacy & activity")
                HarnessCard {
                    VStack(spacing: 14) {
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
                        Text("Harness is open source. Your notes are portable Markdown, and you choose which models and devices receive your context.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Me").navigationBarTitleDisplayMode(.inline)
        .alert("Rename your director", isPresented: $rename) {
            TextField("Name", text: $name)
            Button("Save") { Task { await model.renameDirector(name) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Dot's role remains General Orchestrator Director.") }
        .harnessScreen()
    }

    private var connectionSummary: String {
        let count = model.state.devices.count
        return count == 0 ? "Pair a computer or set up SSH" : "\(count) paired \(count == 1 ? "computer" : "computers") · manage SSH"
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
