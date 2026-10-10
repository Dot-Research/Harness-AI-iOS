#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import DictationCore
import DictationEngine

/// The Dictation tab: try it, set up the keyboard, and control how speech becomes text.
public struct DictationTabView: View {
    @ObservedObject var host: DictationHost
    @ObservedObject var store: DictationSettingsStore
    private let group: AppGroupConfiguration
    private let credentials: KeychainCredentialProvider

    @State private var presence: KeyboardPresence?
    @State private var micPermission = AudioCapture.permission
    @State private var availability: RouteAvailability?
    @State private var path = NavigationPath()

    public init(host: DictationHost, group: AppGroupConfiguration = AppGroupConfiguration(), credentials: KeychainCredentialProvider = KeychainCredentialProvider()) {
        self.host = host
        self.store = host.settingsStore
        self.group = group
        self.credentials = credentials
    }

    private var settings: DictationSettings { store.settings }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    TryDictationView(host: host)
                } footer: {
                    Text("Audio is processed in memory and discarded. It's never saved.")
                }

                if !setupComplete {
                    setupSection
                }

                if host.status.phase != .inactive {
                    micSessionSection
                }

                Section("Modes") {
                    ForEach(settings.modes) { mode in
                        NavigationLink(value: Destination.mode(mode.id)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.name)
                                    Text(modeSummary(mode)).font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mode.id == settings.defaultModeID {
                                    Text("Default").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button {
                        let mode = DictationMode(id: UUID().uuidString, name: "New mode", style: .custom, instruction: nil, aiPolish: true)
                        store.update { $0.modes.append(mode) }
                        path.append(Destination.mode(mode.id))
                    } label: {
                        Label("Add a mode", systemImage: "plus")
                    }
                    Toggle("Pick mode from the text field", isOn: binding(\.smartModeFromField))
                }

                Section {
                    Picker("Transcribe", selection: binding(\.routePreference)) {
                        ForEach(RoutePreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Allow cloud when nothing else works", isOn: binding(\.allowCloudFallback))
                    NavigationLink("Cloud endpoint", value: Destination.cloud)
                    NavigationLink(value: Destination.language) {
                        LabeledContent("Language", value: languageName(settings.languageCode))
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(routeFootnote)
                }

                Section {
                    Toggle("Remove filler words", isOn: cleanupBinding(\.removeFillers))
                    Toggle("Remove repeated words", isOn: cleanupBinding(\.removeRepetitions))
                    Toggle("Apply self-corrections", isOn: cleanupBinding(\.applySelfCorrections))
                    Toggle("Format spoken lists", isOn: cleanupBinding(\.formatLists))
                    Toggle("Voice commands", isOn: cleanupBinding(\.spokenCommands))
                    Toggle("Spoken punctuation", isOn: cleanupBinding(\.spokenPunctuation))
                } header: {
                    Text("Cleanup")
                } footer: {
                    Text("Runs on this iPhone. Voice commands: \"new line\", \"new paragraph\", \"bullet point\", \"scratch that\". Spoken punctuation turns \"comma\" and \"period\" into marks.")
                }

                Section {
                    Picker("Keep mic ready", selection: binding(\.warmSessionMinutes)) {
                        Text("Off").tag(0)
                        Text("1 minute").tag(1)
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                    }
                    Picker("Stop after silence", selection: binding(\.silenceAutoStopSeconds)) {
                        Text("Never").tag(0)
                        Text("2 seconds").tag(2)
                        Text("3 seconds").tag(3)
                        Text("5 seconds").tag(5)
                    }
                    Toggle("Haptics", isOn: binding(\.haptics))
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("While the mic is ready, the keyboard starts dictating instantly without switching apps. The orange dot shows the mic is on; audio is dropped until you tap Dictate.")
                }

                Section("Personal dictionary") {
                    NavigationLink(value: Destination.dictionary) {
                        LabeledContent("Words and names", value: "\(settings.dictionary.entries.count)")
                    }
                }

                Section {
                    Toggle("Keep text history", isOn: binding(\.historyEnabled))
                    if settings.historyEnabled {
                        Picker("Keep for", selection: binding(\.historyRetentionDays)) {
                            Text("1 day").tag(1)
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                        }
                        NavigationLink(value: Destination.history) {
                            LabeledContent("History", value: "\(host.history.entries.count)")
                        }
                    }
                } header: {
                    Text("History")
                } footer: {
                    Text("Off by default. Only text is kept, on this iPhone, never audio.")
                }
            }
            .navigationTitle("Dictation")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case let .mode(id): ModeEditorView(store: store, modeID: id)
                case .cloud: CloudEndpointView(store: store, credentials: credentials)
                case .language: LanguagePickerView(store: store)
                case .dictionary: PersonalDictionaryView(store: store)
                case .history: HistoryView(host: host)
                }
            }
            .task { await refresh() }
            .refreshable { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await refresh() }
            }
            // initial: a link that opened the app may have set this before the tab existed.
            .onChange(of: host.requestedSection, initial: true) { _, section in
                guard let section else { return }
                host.requestedSection = nil
                switch section {
                case "dictionary": path.append(Destination.dictionary)
                case "history": path.append(Destination.history)
                default: break
                }
            }
        }
    }

    enum Destination: Hashable {
        case mode(String), cloud, language, dictionary, history
    }

    // MARK: Setup

    private var keyboardActive: Bool { presence != nil }
    private var fullAccess: Bool { presence?.hasFullAccess ?? false }
    private var onDeviceReady: Bool { availability?.onDeviceInstalled ?? false }
    private var setupComplete: Bool { keyboardActive && fullAccess && micPermission == .granted && onDeviceReady }

    private var setupSection: some View {
        Section {
            SetupRow(done: keyboardActive, title: "Add Harness Keyboard", detail: "Settings > Harness > Keyboards > turn on Harness.") {
                openSettings()
            }
            SetupRow(done: fullAccess, title: "Allow Full Access", detail: "Lets the keyboard reach the Harness app on this iPhone. Nothing you type is collected.") {
                openSettings()
            }
            SetupRow(done: micPermission == .granted, title: "Allow the microphone", detail: micPermission == .denied ? "Turn it on in Settings > Harness." : "Harness records only while you dictate.") {
                if micPermission == .undetermined {
                    Task {
                        _ = await AudioCapture.requestPermission()
                        micPermission = AudioCapture.permission
                    }
                } else {
                    openSettings()
                }
            }
            SetupRow(done: onDeviceReady, title: "Download the speech model", detail: availability?.onDeviceSupported == false ? "Your language isn't available on device yet. Pair a computer or set up a cloud endpoint." : "One-time download so dictation works offline.") {
                Task {
                    let locale = settings.languageCode.map(Locale.init(identifier:)) ?? Locale.current
                    let transcriber = OnDeviceTranscriber(locale: locale, contextualStrings: [])
                    try? await transcriber.prepare()
                    await transcriber.cancel()
                    await refresh()
                }
            }
        } header: {
            Text("Set up")
        }
    }

    private var micSessionSection: some View {
        Section {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text(host.status.phase == .listening ? "Listening" : "Mic ready")
                    if let until = host.status.warmUntil {
                        Text("Until \(until.formatted(date: .omitted, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Turn off") { host.endSession() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func refresh() async {
        presence = KeyboardPresence.read(from: group)
        micPermission = AudioCapture.permission
        availability = await host.routeAvailability(languageCode: settings.languageCode)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private var routeFootnote: String {
        guard let availability else { return "On device keeps audio on this iPhone." }
        let decision = RouteSelector.select(preference: settings.routePreference, allowCloudFallback: settings.allowCloudFallback, availability: availability)
        return decision.explanation
    }

    private func modeSummary(_ mode: DictationMode) -> String {
        switch mode.style {
        case .message: return "Casual, no final period on one-liners"
        case .email: return "Clear paragraphs, lists"
        case .note: return "Tidy notes and lists"
        case .verbatim: return "Exactly what you said"
        case .custom: return mode.instruction ?? "Your own instruction"
        }
    }

    private func languageName(_ code: String?) -> String {
        guard let code else { return "Same as iPhone" }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }

    // MARK: Bindings

    private func binding<T>(_ keyPath: WritableKeyPath<DictationSettings, T>) -> Binding<T> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { value in store.update { $0[keyPath: keyPath] = value } })
    }

    private func cleanupBinding(_ keyPath: WritableKeyPath<CleanupOptions, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings.cleanup[keyPath: keyPath] }, set: { value in store.update { $0.cleanup[keyPath: keyPath] = value } })
    }
}

private struct SetupRow: View {
    let done: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(done)
        .accessibilityValue(done ? "Done" : "Not done")
    }
}

// MARK: - Try it

struct TryDictationView: View {
    @ObservedObject var host: DictationHost
    @State private var text = ""
    @State private var activeID: UUID?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $text)
                .frame(minHeight: 96)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && activeID == nil {
                        Text("Tap the mic and talk. Try \"um, let's meet Tuesday, no wait, Thursday\".")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                if let partial = host.status.partialText, activeID != nil {
                    Text(partial).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                } else if let errorText, activeID == nil {
                    Text(errorText).font(.footnote).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button {
                    toggle()
                } label: {
                    Label(activeID == nil ? "Dictate" : "Stop", systemImage: activeID == nil ? "mic.fill" : "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(activeID == nil ? .primary : .red)
            }
        }
        .onChange(of: host.latestLocalOutcome) { _, outcome in
            guard let outcome, outcome.requestID == activeID else { return }
            activeID = nil
            show(outcome)
        }
    }

    private func toggle() {
        if let id = activeID {
            host.stopLocalDictation(id)
        } else {
            errorText = nil
            Task {
                let id = await host.startLocalDictation()
                // A start that fails (mic off) is delivered before this returns.
                if let outcome = host.latestLocalOutcome, outcome.requestID == id {
                    show(outcome)
                } else {
                    activeID = id
                }
            }
        }
    }

    private func show(_ outcome: DictationOutcome) {
        if let result = outcome.text {
            text += InsertionPlanner.fit(result, into: InsertionContext(before: text, after: ""))
        } else if let error = outcome.error, error.code != .cancelled, error.code != .emptyTranscript {
            errorText = error.message
        }
    }
}

// MARK: - Handoff screen

/// Shown when the keyboard opens the app to start the microphone. The user swipes back to the
/// app they were typing in; dictation continues there.
public struct HandoffListeningView: View {
    @ObservedObject var host: DictationHost

    public init(host: DictationHost) {
        self.host = host
    }

    public var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, isActive: host.status.phase == .listening)
            Text(host.status.phase == .listening ? "Listening" : "Mic is on")
                .font(.title2.weight(.semibold))
            if let partial = host.status.partialText, !partial.isEmpty {
                Text(partial)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 32)
            }
            VStack(spacing: 8) {
                Image(systemName: "arrow.right")
                    .font(.title3)
                Text("Swipe right along the bottom edge to go back")
                    .font(.headline)
                Text("Keep talking. Your words appear where you were typing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 12)
            if let notice = host.status.notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 32).multilineTextAlignment(.center)
            }
            Spacer()
            Button("Turn mic off") { host.endSession() }
                .buttonStyle(.bordered)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
#endif
