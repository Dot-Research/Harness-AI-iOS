import SwiftUI
import HarnessCore

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your iPhone.\nA wider reach.").font(.system(.largeTitle, design: .serif))
                Text("Pair a computer to delegate work beyond the phone. Each capability is separate, and every tool call passes through your permissions.")
                    .font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
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
                Text("Terminal, filesystem, and execution tools are available when supported by your companion. Browser, local models, and long-running delegation are future capabilities.")
                    .font(.caption).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }.navigationTitle("Devices").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { NavigationStack { AddDeviceView() } }
        .harnessScreen()
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
