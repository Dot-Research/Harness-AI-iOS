import SwiftUI
import HarnessCore

struct ProvidersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: ProviderConfiguration?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Choose where\nintelligence lives.").font(.system(.largeTitle, design: .serif))
                Text("Start on device. Add cloud models when you want more capability. Every request shows its destination before you send.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                HarnessCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Routing preference", systemImage: "arrow.triangle.branch").font(.subheadline.weight(.medium))
                        Picker("Routing preference", selection: Binding(get: { model.state.routingPreference }, set: { value in Task { await model.setRouting(value) } })) {
                            ForEach(RoutingPreference.allCases, id: \.self) { preference in Text(preference.rawValue).tag(preference) }
                        }.pickerStyle(.menu).tint(HarnessTheme.coral)
                        Text(model.routeDescription).font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                        Text("Balanced prefers on-device processing. Cloud preferred sends selected context to an enabled cloud provider. On device only blocks cloud fallback.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                SectionEyebrow(title: "On this iPhone")
                HarnessCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "apple.intelligence").font(.title2).foregroundStyle(HarnessTheme.green)
                            Text("Apple Foundation Models").font(.body.weight(.medium))
                        }
                        Text(model.appleModelStatusDescription).font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                        Text("Availability depends on device support, language, and Apple Intelligence settings. No API key is needed.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                SectionEyebrow(title: "Additional endpoints · optional")
                ForEach(model.state.providers.filter { $0.kind != .apple }) { provider in
                    Button { editing = provider } label: {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 11) {
                                HStack {
                                    Text(provider.name).font(.body.weight(.medium)).foregroundStyle(HarnessTheme.text)
                                    Spacer()
                                    StatusPill(title: provider.enabled ? "Enabled" : "Disabled", symbol: provider.enabled ? "checkmark" : "pause", color: provider.enabled ? HarnessTheme.coral : HarnessTheme.secondary)
                                }
                                if provider.kind == .openRouter {
                                    Text("Recommended cloud setup · one key, your choice of models")
                                        .font(.caption).foregroundStyle(HarnessTheme.amber)
                                }
                                Text(provider.model).font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                                Text(URL(string: provider.endpoint)?.host ?? provider.endpoint).font(.caption).foregroundStyle(HarnessTheme.secondary)
                                Label("Provider credentials use Apple Keychain", systemImage: "key.horizontal").font(.caption).foregroundStyle(HarnessTheme.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                if !model.state.providers.contains(where: { $0.kind == .openRouter }) {
                    Button {
                        editing = ProviderConfiguration(id: "openrouter", name: "OpenRouter", kind: .openRouter, endpoint: "https://openrouter.ai/api/v1", model: "")
                    } label: {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 13) {
                                HStack {
                                    Text("OpenRouter").font(.title3.weight(.medium)).foregroundStyle(HarnessTheme.text)
                                    Spacer()
                                    StatusPill(title: "RECOMMENDED", symbol: "sparkle", color: HarnessTheme.amber)
                                }
                                Text("One credential. Your choice of cloud models.")
                                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                                Label("Set up OpenRouter", systemImage: "plus").font(.subheadline.weight(.semibold)).foregroundStyle(HarnessTheme.coral)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                Button {
                    editing = ProviderConfiguration(id: UUID().uuidString, name: "", kind: .openAICompatible, endpoint: "", model: "")
                } label: { Label("Add a cloud or local endpoint", systemImage: "plus.circle") }
                    .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                Text("Cloud providers receive request text and selected agent context. Configure only endpoints you trust. Keys never enter model prompts or agent files.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .navigationTitle("Models & providers").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { provider in NavigationStack { ProviderEditorView(provider: provider) } }
        .harnessScreen()
    }
}

private struct ProviderEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let provider: ProviderConfiguration
    @State private var name: String
    @State private var endpoint: String
    @State private var modelName: String
    @State private var key = ""
    @State private var enabled: Bool
    @State private var saving = false
    @State private var deleting = false
    private var existing: Bool { model.state.providers.contains { $0.id == provider.id } }
    private var endpointIsLocal: Bool {
        var candidate = provider
        candidate.endpoint = endpoint
        return (try? OpenAICompatibleProvider(configuration: candidate, credential: { nil }))?.isLocal ?? false
    }
    init(provider: ProviderConfiguration) {
        self.provider = provider
        _name = State(initialValue: provider.name)
        _endpoint = State(initialValue: provider.endpoint)
        _modelName = State(initialValue: provider.model)
        _enabled = State(initialValue: provider.enabled)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HarnessErrorBanner()
                Text(provider.kind == .openRouter ? "A doorway to model choice." : "Bring your own endpoint.")
                    .font(.system(.title, design: .serif))
                HarnessCard {
                    VStack(alignment: .leading, spacing: 18) {
                        labeledField("PROVIDER NAME", value: $name, placeholder: "My provider")
                        Divider()
                        labeledField("API BASE URL", value: $endpoint, placeholder: "https://…/v1")
                        Divider()
                        labeledField("MODEL IDENTIFIER", value: $modelName, placeholder: "provider/model")
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API KEY").font(.system(.caption2, design: .monospaced)).tracking(1.3).foregroundStyle(HarnessTheme.secondary)
                            SecureField(existing ? "Leave blank to keep saved key" : endpointIsLocal ? "Optional for this local endpoint" : "Paste your API key", text: $key)
                                .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        Toggle("Enabled", isOn: $enabled)
                    }
                }
                HarnessCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Stored in Apple Keychain", systemImage: "key.horizontal").font(.subheadline.weight(.medium)).foregroundStyle(HarnessTheme.green)
                        Text("The agent receives a provider handle, never your key. Saving configuration does not change your on-device routing preference.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                        Text("Destination: \(URL(string: endpoint)?.host ?? "not configured")")
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                        Text("Remote endpoints require HTTPS and an API key. HTTP and a blank key are supported only for a model endpoint on this iPhone’s loopback interface.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                if provider.kind == .openRouter {
                    Link("Get a key and choose a model at OpenRouter", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                        .font(.subheadline)
                }
                if existing { Button("Remove provider and key", role: .destructive) { deleting = true } }
            }.padding(22)
        }
        .navigationTitle(existing ? "Edit provider" : "Add provider").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { key = ""; dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    var updated = provider
                    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.enabled = enabled
                    Task {
                        await model.saveProvider(updated, key: key)
                        saving = false
                        if model.error == nil { key = ""; dismiss() }
                    }
                }.disabled(saving || name.isEmpty || modelName.isEmpty || endpoint.isEmpty || (!existing && !endpointIsLocal && key.isEmpty))
            }
        }
        .confirmationDialog("Remove this provider?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Remove provider and key", role: .destructive) { Task { await model.removeProvider(provider.id); if model.error == nil { dismiss() } } }
        }
        .interactiveDismissDisabled(saving)
        .onDisappear { key = "" }
        .harnessScreen()
    }

    private func labeledField(_ label: String, value: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(.caption2, design: .monospaced)).tracking(1.3).foregroundStyle(HarnessTheme.secondary)
            TextField(placeholder, text: value).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(label.contains("URL") ? .URL : .default)
        }
    }
}
