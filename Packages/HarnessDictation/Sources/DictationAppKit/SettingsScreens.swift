#if os(iOS)
import Speech
import SwiftUI
import UIKit
import DictationCore
import DictationEngine

// MARK: - Mode editor

struct ModeEditorView: View {
    @ObservedObject var store: DictationSettingsStore
    let modeID: String
    @Environment(\.dismiss) private var dismiss

    private var isBuiltIn: Bool { DictationMode.builtIns.contains(where: { $0.id == modeID }) }

    var body: some View {
        Form {
            if let mode = store.settings.modes.first(where: { $0.id == modeID }) {
                Section {
                    TextField("Name", text: modeBinding(mode, \.name))
                        .disabled(isBuiltIn)
                    if !isBuiltIn {
                        Picker("Based on", selection: modeBinding(mode, \.style)) {
                            Text("Message").tag(DictationMode.Style.message)
                            Text("Email").tag(DictationMode.Style.email)
                            Text("Note").tag(DictationMode.Style.note)
                            Text("Custom").tag(DictationMode.Style.custom)
                        }
                    }
                }
                Section {
                    Toggle("Polish with on-device AI", isOn: modeBinding(mode, \.aiPolish))
                        .disabled(mode.style == .verbatim)
                    TextField("Instruction (optional)", text: Binding(
                        get: { modeBinding(mode, \.instruction).wrappedValue ?? "" },
                        set: { modeBinding(mode, \.instruction).wrappedValue = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(2...5)
                } footer: {
                    Text("For example: \"Write like I'm texting a client: warm, brief, no emoji.\" The instruction is used with the on-device model, so it stays on this iPhone.")
                }
                Section {
                    Button("Use as default") { store.update { $0.defaultModeID = modeID } }
                        .disabled(store.settings.defaultModeID == modeID)
                    if !isBuiltIn {
                        Button("Delete mode", role: .destructive) {
                            store.update { settings in
                                settings.modes.removeAll { $0.id == modeID }
                                if settings.defaultModeID == modeID { settings.defaultModeID = DictationMode.message.id }
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(store.settings.modes.first(where: { $0.id == modeID })?.name ?? "Mode")
    }

    /// Looks the mode up by id on every read and write: the list can change underneath an open editor
    /// (deleted here, or reloaded after the keyboard saved settings).
    private func modeBinding<T>(_ snapshot: DictationMode, _ keyPath: WritableKeyPath<DictationMode, T>) -> Binding<T> {
        Binding(
            get: { (store.settings.modes.first(where: { $0.id == modeID }) ?? snapshot)[keyPath: keyPath] },
            set: { value in
                store.update { settings in
                    guard let i = settings.modes.firstIndex(where: { $0.id == modeID }) else { return }
                    settings.modes[i][keyPath: keyPath] = value
                }
            }
        )
    }
}

// MARK: - Cloud endpoint

struct CloudEndpointView: View {
    @ObservedObject var store: DictationSettingsStore
    let credentials: KeychainCredentialProvider

    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var error: String?

    private static let credentialID = "dictation.cloud"

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(hasKey ? "API key (saved in Keychain)" : "API key", text: $apiKey)
            } footer: {
                Text("Any OpenAI-compatible speech-to-text endpoint, e.g. OpenAI (https://api.openai.com, gpt-4o-transcribe) or Groq (https://api.groq.com/openai/v1, whisper-large-v3-turbo). The key is stored in the Keychain and only used to send your audio for transcription.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button("Save") { save() }
                    .disabled(baseURL.isEmpty || model.isEmpty)
                if store.settings.cloudEndpoint != nil {
                    Button("Remove endpoint", role: .destructive) {
                        credentials.removeSecret(for: Self.credentialID)
                        store.update { $0.cloudEndpoint = nil }
                        name = ""; baseURL = ""; model = ""; apiKey = ""; hasKey = false
                    }
                }
            }
        }
        .navigationTitle("Cloud endpoint")
        .onAppear {
            if let endpoint = store.settings.cloudEndpoint {
                name = endpoint.name
                baseURL = endpoint.baseURL.absoluteString
                model = endpoint.model
            }
            hasKey = credentials.hasSecret(for: Self.credentialID)
        }
    }

    private func save() {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme, url.host != nil else {
            error = "Enter a full URL, starting with https://"
            return
        }
        if scheme.lowercased() != "https" && !(url.host?.hasSuffix(".local") ?? false) {
            error = "Use https:// for cloud endpoints."
            return
        }
        if !apiKey.isEmpty {
            guard credentials.setSecret(apiKey, for: Self.credentialID) else {
                error = "Couldn't save the key to the Keychain."
                return
            }
            apiKey = ""
            hasKey = true
        }
        let endpoint = TranscriptionEndpoint(
            name: name.isEmpty ? (url.host ?? "Cloud") : name,
            baseURL: url,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialID: hasKey ? Self.credentialID : nil
        )
        store.update { $0.cloudEndpoint = endpoint }
        error = nil
    }
}

// MARK: - Language

struct LanguagePickerView: View {
    @ObservedObject var store: DictationSettingsStore
    @State private var locales: [Locale] = []
    @State private var query = ""

    var body: some View {
        List {
            Button {
                store.update { $0.languageCode = nil }
            } label: {
                row(title: "Same as iPhone", selected: store.settings.languageCode == nil)
            }
            ForEach(filtered, id: \.identifier) { locale in
                Button {
                    store.update { $0.languageCode = locale.identifier(.bcp47) }
                } label: {
                    row(title: Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                        selected: store.settings.languageCode == locale.identifier(.bcp47))
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Language")
        .task {
            let supported = await SpeechTranscriber.supportedLocales
            let dictation = await DictationTranscriber.supportedLocales
            var seen = Set<String>()
            locales = (supported + dictation)
                .filter { seen.insert($0.identifier(.bcp47)).inserted }
                .sorted { (Locale.current.localizedString(forIdentifier: $0.identifier) ?? "") < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? "") }
        }
    }

    private var filtered: [Locale] {
        guard !query.isEmpty else { return locales }
        return locales.filter { (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier).localizedCaseInsensitiveContains(query) }
    }

    private func row(title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
    }
}

// MARK: - Personal dictionary

struct PersonalDictionaryView: View {
    @ObservedObject var store: DictationSettingsStore
    @State private var newWord = ""
    @State private var newSoundsLike = ""

    var body: some View {
        List {
            Section {
                TextField("Word or name, as written", text: $newWord)
                    .autocorrectionDisabled()
                TextField("Sounds like (optional)", text: $newSoundsLike)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Add") { add() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("Harness writes these exactly as entered and helps the speech model recognize them. \"OpenRouter\" also matches \"open router\" automatically.")
            }
            Section {
                ForEach(store.settings.dictionary.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.written)
                        if !entry.soundsLike.isEmpty {
                            Text("Sounds like: " + entry.soundsLike.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    store.update { $0.dictionary.entries.remove(atOffsets: offsets) }
                }
            }
        }
        .navigationTitle("Dictionary")
        .toolbar { EditButton() }
    }

    private func add() {
        let written = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let sounds = newSoundsLike.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        store.update { $0.dictionary.entries.insert(DictionaryEntry(written: written, soundsLike: sounds), at: 0) }
        newWord = ""
        newSoundsLike = ""
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var host: DictationHost
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        List {
            ForEach(host.history.search(query)) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text).textSelection(.enabled)
                    Text("\(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.route?.displayName ?? "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { host.deleteHistoryEntry(entry.id) }
                }
                .contextMenu {
                    Button("Copy") { UIPasteboard.general.string = entry.text }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("History")
        .toolbar {
            Button("Clear", role: .destructive) { confirmClear = true }
                .disabled(host.history.entries.isEmpty)
        }
        .confirmationDialog("Delete all dictation history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { host.clearHistory() }
        }
        .overlay {
            if host.history.entries.isEmpty {
                ContentUnavailableView("No history", systemImage: "text.bubble", description: Text("Dictations appear here while history is on."))
            }
        }
    }
}
#endif
