import SwiftUI
import AVFoundation
import HarnessCore

struct PrivacyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var prompt = ""
    @State private var loaded = false
    @State private var auditing = false
    @State private var resettingRule: String?
    private var transmissions: [ActivityEntry] { model.state.activity.filter { $0.destination != nil } }
    private var latestAudit: ActivityEntry? { model.state.activity.filter { $0.title.localizedCaseInsensitiveContains("audit") }.max(by: { $0.date < $1.date }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Privacy you\ncan observe.").font(.system(.largeTitle, design: .serif))
                Text("Inspect current configuration, recorded destinations, permissions, and learning. Evidence is more useful than a promise.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                HarnessCard {
                    VStack(alignment: .leading, spacing: 18) {
                        observation("Model route", value: model.routeDescription, symbol: model.routeIsLocal ? "iphone" : "network")
                        Divider()
                        observation("Credential storage", value: "Apple Keychain · opaque provider handles", symbol: "key.horizontal")
                        Divider()
                        observation("Learning", value: "\(model.state.learningMode.rawValue) · \(model.state.proposals.count) pending proposals", symbol: "leaf")
                        Divider()
                        observation("Camera access", value: cameraStatus, symbol: "camera")
                    }
                }
                SectionEyebrow(title: "Configured destinations")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 13) {
                        if model.state.providers.filter({ $0.kind != .apple }).isEmpty && model.state.devices.isEmpty {
                            Text("No cloud providers or paired computers configured.").font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                        }
                        ForEach(model.state.providers.filter { $0.kind != .apple }) { provider in
                            observation(provider.name, value: "\(URL(string: provider.endpoint)?.host ?? provider.endpoint) · \(provider.enabled ? "enabled" : "disabled")", symbol: "network")
                        }
                        ForEach(model.state.devices) { device in
                            observation(device.name, value: URL(string: device.url)?.host ?? device.url, symbol: "desktopcomputer")
                        }
                    }
                }
                SectionEyebrow(title: "Deterministic permissions", trailing: "\(model.state.permissionRules.count)")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.state.permissionRules.isEmpty {
                            Text("No persistent overrides. Tool capability and risk defaults apply.").font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                        }
                        ForEach(model.state.permissionRules.keys.sorted(), id: \.self) { rule in
                            HStack(alignment: .top) {
                                Text(rule).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text(model.state.permissionRules[rule]?.rawValue ?? "").font(.caption).foregroundStyle(HarnessTheme.amber)
                                Button("Reset") { resettingRule = rule }
                                    .font(.caption)
                                    .accessibilityLabel("Reset saved decision for \(rule)")
                            }
                        }
                        Text("Each agent also has an independent capability ceiling. Model output cannot change these rules.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                SectionEyebrow(title: "Recent recorded destinations", trailing: "\(transmissions.count)")
                if transmissions.isEmpty {
                    Text("No external destination has been recorded in the local audit trail.")
                        .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                } else {
                    ForEach(transmissions.sorted(by: { $0.date > $1.date }).prefix(5)) { entry in
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.title).font(.subheadline.weight(.medium))
                                Text(entry.destination ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.coral)
                                Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(HarnessTheme.secondary)
                            }
                        }
                    }
                }
                NavigationLink { ActivityView() } label: { Label("Inspect the full audit trail", systemImage: "arrow.up.right") }.font(.subheadline)
                SectionEyebrow(title: "Your audit prompt")
                TextEditor(text: $prompt).font(.system(.subheadline, design: .monospaced))
                    .scrollContentBackground(.hidden).frame(height: 210).padding(12)
                    .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Editable privacy audit prompt")
                HStack {
                    Button("Save prompt") { Task { await model.saveAuditPrompt(prompt) } }
                        .font(.subheadline)
                    Spacer()
                    if prompt == model.state.auditPrompt { Label("Saved locally", systemImage: "checkmark").font(.caption).foregroundStyle(HarnessTheme.secondary) }
                }
                Button {
                    auditing = true
                    Task {
                        await model.saveAuditPrompt(prompt)
                        if model.error == nil { await model.runAudit() }
                        auditing = false
                    }
                } label: { Label(auditing ? "Inspecting…" : "Run privacy audit", systemImage: "checklist") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(auditing || model.isWorking || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Label(model.canSend || (auditing && model.isWorking) ? "Interpretation route: \(model.routeDescription)" : "Local inspection only · no model available", systemImage: model.routeIsLocal ? "iphone" : "network")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                Text("The audit saves local observations first. When a model is available, it interprets the report using this route and the usual permissions. This is not a capture of all device traffic or a security certification. Distinguish model conclusions from verified evidence.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                if let audit = latestAudit {
                    HarnessCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Latest observations").font(.system(.title3, design: .serif))
                            Text(audit.date, format: .dateTime.month(.abbreviated).day().hour().minute()).font(.caption).foregroundStyle(HarnessTheme.amber)
                            Text(audit.detail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
        .onAppear { if !loaded { prompt = model.state.auditPrompt; loaded = true } }
        .confirmationDialog("Reset this saved permission?", isPresented: Binding(get: { resettingRule != nil }, set: { if !$0 { resettingRule = nil } }), titleVisibility: .visible) {
            if let rule = resettingRule {
                Button("Use capability and risk defaults") { Task { await model.clearPermissionRule(rule); resettingRule = nil } }
            }
            Button("Cancel", role: .cancel) { resettingRule = nil }
        } message: {
            Text("The saved decision is removed. Future requests use the tool’s declared capability and risk defaults, within the agent’s permission ceiling.")
        }
        .harnessScreen()
    }

    private func observation(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(HarnessTheme.green).frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(HarnessTheme.secondary)
                Text(value).font(.subheadline).textSelection(.enabled)
            }
        }
    }
    private var cameraStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: "Allowed for pairing QR scanning"
        case .denied: "Denied · manual pairing available"
        case .restricted: "Restricted · manual pairing available"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }
}
