#if os(iOS)
import SwiftUI
import DictationCore
import DictationEngine

public struct AppleRewriteSettingsView: View {
    @ObservedObject private var store: DictationSettingsStore
    private let cloud = PrivateCloudRewriter()
    public init(store: DictationSettingsStore) { self.store = store }

    public var body: some View {
        Form {
            Section {
                Picker("Text cleanup model", selection: Binding(get: { store.settings.effectiveAppleRewriteRoute }, set: { value in store.update { $0.appleRewriteRoute = value } })) {
                    ForEach(AppleRewriteRoute.allCases, id: \.self) { route in Text(route.displayName).tag(route) }
                }
                Text("Speech recognition and text rewriting are separate. This setting chooses the model for Polish, Fix and Rewrite; it doesn't change where your audio is transcribed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On device") {
                Label(OnDeviceRewriter().isAvailable ? "Apple Intelligence ready" : "Apple Intelligence unavailable", systemImage: "iphone")
                Text("The default route keeps transcript and instructions on this device. It never switches to a cloud model automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Private Cloud") {
                Text(cloud.availabilityDescription).font(.subheadline)
                Text("Choosing a Private Cloud route allows your transcript and instruction.md to be sent to Apple for rewriting. The cloud route needs internet and has a daily limit. If rewriting fails, dictation keeps its original text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Text cleanup model").navigationBarTitleDisplayMode(.inline)
    }
}
#endif
