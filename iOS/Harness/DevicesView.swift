import SwiftUI
import HarnessCore

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var addingAgent = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your machines.\nOne conversation.").font(.system(.largeTitle, design: .serif))
                Text("Connect a computer, then give Dot a route to pi-coding-agent, Claude Code or Hermes. SSH routes use that computer's saved host aliases and keys.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                SectionEyebrow(title: "Agent & SSH routes")
                if model.state.remoteAgentConnections.isEmpty {
                    Text("Save a route after pairing a computer. Dot can then delegate from the General Orchestrator Director conversation.")
                        .font(.subheadline).foregroundStyle(HarnessTheme.secondary)
                }
                ForEach(model.state.remoteAgentConnections) { connection in
                    NavigationLink { RemoteAgentEditor(connection: connection) } label: {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 12) {
                                    Image(systemName: connection.sshAlias == nil ? "terminal" : "network").foregroundStyle(HarnessTheme.coral)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(connection.name).font(.headline)
                                        Text(connection.runtime.rawValue).font(.caption).foregroundStyle(HarnessTheme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(HarnessTheme.secondary)
                                }
                                Text("\(computerName(connection.deviceID)) · \(connection.routeDescription)").font(.caption)
                                Text(routeStatus(connection)).font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                Button { addingAgent = true } label: { Label("Add agent or SSH route", systemImage: "plus") }
                    .buttonStyle(.bordered).disabled(model.state.devices.isEmpty)
                SectionEyebrow(title: "Paired computers")
                if model.state.devices.isEmpty {
                    HarnessCard {
                        HarnessEmptyState(symbol: "laptopcomputer.and.iphone", title: "Put your computer to work.", detail: "Start the Harness companion on your Mac, Windows, or Linux computer, then run harness pair and scan its one-time code.")
                    }
                }
                ForEach(model.state.devices) { device in
                    NavigationLink { DeviceDetailView(deviceID: device.id) } label: {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 15) {
                                HStack(spacing: 14) {
                                    Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(HarnessTheme.amber)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(device.name).font(.title3.weight(.medium))
                                        Text(URL(string: device.url)?.host ?? device.url).font(.caption).foregroundStyle(HarnessTheme.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right").foregroundStyle(HarnessTheme.secondary)
                                }
                                CapabilityTags(capabilities: device.capabilities)
                                Text("PAIRED · CONNECTION CHECKED WHEN USED")
                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                Button { adding = true } label: { Label("Add computer", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
                HarnessCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("A code, not a password.", systemImage: "qrcode").font(.subheadline.weight(.medium)).foregroundStyle(HarnessTheme.green)
                        Text("Pairing uses a short-lived invitation and the companion’s certificate fingerprint. The resulting device credential stays in Keychain.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                Text("Agent runtimes must be installed and signed in on the selected computer or SSH host. SSH requires a saved host alias, known host key and noninteractive authentication. Agent jobs can run for up to 30 minutes while the companion is running. Results remain available for one hour; restarting the companion ends its jobs.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Connections & SSH").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { NavigationStack { AddDeviceView() } }
        .sheet(isPresented: $addingAgent) { NavigationStack { RemoteAgentEditor() } }
        .harnessScreen()
    }
    private func computerName(_ id: String) -> String { model.state.devices.first { $0.id == id }?.name ?? "Computer unavailable" }
    private func routeStatus(_ connection: RemoteAgentConnection) -> String {
        if !connection.enabled { return "DISABLED" }
        if model.state.devices.first(where: { $0.id == connection.deviceID })?.capabilities.contains(.computerExecute) != true { return "EXECUTION PERMISSION REQUIRED" }
        return "SAVED · CONNECTION CHECKED WHEN USED"
    }
}

private struct RemoteAgentEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let connection: RemoteAgentConnection?
    @State private var name = ""
    @State private var deviceID = ""
    @State private var runtime: RemoteAgentRuntime = .pi
    @State private var executable = "pi"
    @State private var sshAlias = ""
    @State private var directory = ""
    @State private var saving = false
    @State private var initialized = false

    init(connection: RemoteAgentConnection? = nil) { self.connection = connection }

    var body: some View {
        Form {
            Section("Agent") {
                TextField("Name", text: $name)
                Picker("Runtime", selection: $runtime) {
                    ForEach(RemoteAgentRuntime.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Paired computer", selection: $deviceID) {
                    ForEach(model.state.devices) { Text($0.name).tag($0.id) }
                }
            }
            Section {
                TextField("SSH host alias (optional)", text: $sshAlias)
                TextField("Absolute working directory (optional)", text: $directory)
                TextField("Executable name or absolute path", text: $executable)
            } header: { Text("Route") } footer: {
                Text("Leave SSH empty to run on the paired computer. For SSH, use an alias from that computer's ~/.ssh/config. Keys stay on the computer, and host-key checking stays enabled.")
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
            Section {
                if let device = model.state.devices.first(where: { $0.id == deviceID }), !device.capabilities.contains(.computerExecute) {
                    NavigationLink { DeviceDetailView(deviceID: device.id) } label: {
                        Label("Enable execution on \(device.name)", systemImage: "lock")
                    }
                }
                Text("Each delegated task shows its exact route and command for approval. The external agent follows its own installed tool permissions. A saved route is checked when used.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(HarnessTheme.coral) }
                Button(saving ? "Saving…" : "Save route") { save() }
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceID.isEmpty)
                if let connection {
                    Button("Ask Dot to use this agent") {
                        if model.prefillComposer("Use the saved remote agent \(connection.name) (connectionID: \(connection.id)) to ") { dismiss() }
                    }.disabled(model.isWorking)
                    Button("Remove route", role: .destructive) {
                        Task { await model.removeRemoteAgent(connection.id); dismiss() }
                    }.disabled(model.isWorking)
                }
            }
        }
        .scrollContentBackground(.hidden).harnessScreen()
        .navigationTitle(connection == nil ? "Add agent route" : "Agent route")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialized else { return }; initialized = true
            if let connection {
                name = connection.name; deviceID = connection.deviceID; runtime = connection.runtime
                executable = connection.executable; sshAlias = connection.sshAlias ?? ""; directory = connection.workingDirectory ?? ""
            } else { name = runtime.rawValue; deviceID = model.state.devices.first?.id ?? "" }
        }
        .onChange(of: runtime) { old, new in if executable == old.executable { executable = new.executable } }
    }

    private func save() {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let route = RemoteAgentConnection(id: connection?.id ?? UUID().uuidString, name: String(trim(name).prefix(80)), deviceID: deviceID,
            runtime: runtime, executable: trim(executable), sshAlias: trim(sshAlias).isEmpty ? nil : trim(sshAlias),
            workingDirectory: trim(directory).isEmpty ? nil : trim(directory))
        saving = true
        Task { let saved = await model.saveRemoteAgent(route); saving = false; if saved { dismiss() } }
    }
}

private struct AddDeviceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var payload = ""
    @State private var pairing = false
    @State private var scanError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HarnessErrorBanner()
                Image(systemName: "qrcode.viewfinder").font(.system(size: 62, weight: .ultraLight)).foregroundStyle(HarnessTheme.amber).padding(.top, 12)
                Text("Give your node\na trusted partner.").font(.system(.largeTitle, design: .serif))
                HarnessCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("ON YOUR COMPUTER").font(.system(.caption2, design: .monospaced)).tracking(1.5).foregroundStyle(HarnessTheme.secondary)
                        Text("harness pair").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Text("Use the companion setup instructions to start an HTTPS node and generate a short-lived pairing invitation.")
                            .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                    }
                }
                Button { scanning = true } label: { Label("Scan pairing QR", systemImage: "camera") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(pairing)
                Text("Camera permission is requested only when you choose to scan. You can pair by pasting the invitation instead.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                if let scanError { Text(scanError).font(.caption).foregroundStyle(HarnessTheme.coral) }
                SectionEyebrow(title: "Or paste your invitation")
                TextEditor(text: $payload).font(.system(.caption, design: .monospaced)).scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().frame(height: 150).padding(10)
                    .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Pairing invitation")
                Button { pair(payload) } label: { Label(pairing ? "Authenticating…" : "Pair with invitation", systemImage: "link") }
                    .buttonStyle(.bordered).disabled(pairing || payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("The initial phone grant is filesystem read access. Enable writing or terminal execution separately after pairing. The companion independently enforces its own capability limits.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
            }.padding(22)
        }.navigationTitle("Add computer").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(pairing) } }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                QRScanner(onPayload: { scanned in
                    scanning = false
                    payload = scanned
                    pair(scanned)
                }, onError: { error in scanError = error })
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan pairing code").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
                .harnessScreen()
            }
        }
        .interactiveDismissDisabled(pairing).harnessScreen()
    }

    private func pair(_ invitation: String) {
        guard !pairing else { return }
        pairing = true
        Task {
            await model.pair(invitation)
            pairing = false
            if model.error == nil { payload = ""; dismiss() }
        }
    }
}

private struct DeviceDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let deviceID: String
    @State private var removing = false
    @State private var changing = false
    private var device: PairedDevice? { model.state.devices.first { $0.id == deviceID } }
    var body: some View {
        ScrollView {
            if let device {
                VStack(alignment: .leading, spacing: 24) {
                    Text(device.name).font(.system(.largeTitle, design: .serif))
                    StatusPill(title: "AUTHENTICATED PAIRING", symbol: "link", color: HarnessTheme.green)
                    HarnessCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("NODE ENDPOINT").font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                            Text(device.url).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("CERTIFICATE FINGERPRINT").font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.secondary)
                            Text(device.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    SectionEyebrow(title: "Independent capability grants")
                    HarnessCard {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(device.availableCapabilities.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                                Toggle(isOn: binding(for: capability)) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(capabilityTitle(capability)).font(.subheadline.weight(.medium))
                                        Text(capability.rawValue).font(.system(.caption2, design: .monospaced)).foregroundStyle(capability == .computerRead ? HarnessTheme.secondary : HarnessTheme.amber)
                                    }
                                }.disabled(changing)
                            }
                            Text("Granting a capability makes it available to authorized agents. Elevated actions still require the Permission Kernel’s decision; sensitive actions require device authentication.")
                                .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                        }
                    }
                    Button("Unpair computer", role: .destructive) { removing = true }
                    Text("Unpairing removes this phone’s credential. It does not delete files on your computer.")
                        .font(.caption).foregroundStyle(HarnessTheme.secondary)
                    if let credentialID = device.credentialID {
                        HarnessCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("REVOKE ON THE COMPUTER").font(.system(.caption2, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
                                Text("To invalidate the companion-side credential, stop the companion, run this command on the computer, then restart it.")
                                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
                                Text("harness revoke --device \(credentialID)")
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
        }.navigationTitle("Computer").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Unpair this computer?", isPresented: $removing, titleVisibility: .visible) {
            Button("Unpair computer", role: .destructive) { Task { await model.unpair(deviceID); if model.error == nil { dismiss() } } }
        }.harnessScreen()
    }

    private func binding(for capability: Capability) -> Binding<Bool> {
        Binding(get: { device?.capabilities.contains(capability) ?? false }, set: { allowed in
            guard let device else { return }
            var capabilities = device.capabilities
            if allowed { capabilities.insert(capability) } else { capabilities.remove(capability) }
            changing = true
            Task { await model.updateDeviceCapabilities(deviceID, capabilities: capabilities); changing = false }
        })
    }
    private func capabilityTitle(_ capability: Capability) -> String {
        switch capability {
        case .computerRead: "Read files"
        case .computerWrite: "Write files"
        case .computerExecute: "Execute terminal commands"
        default: capability.rawValue
        }
    }
}
