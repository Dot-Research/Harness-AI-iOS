#if os(iOS)
import SwiftUI
import DictationCore

/// The Harness Keyboard: dictation first, with the control layer from the spec
/// (Dictate | Fix | Rewrite | Ask Harness). Below it, either the dictation panel with just enough
/// keys to finish a message, or a full typing layer (letters, numbers, symbols).
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardViewModel
    let showsGlobe: Bool
    let globe: () -> AnyView

    @Environment(\.colorScheme) private var scheme

    private var palette: KeyboardPalette { KeyboardPalette(scheme) }

    var body: some View {
        VStack(spacing: 8) {
            controlBar
            Group {
                if showingKeys {
                    typingPanel
                } else if !model.hasFullAccess && model.phase == .idle {
                    fullAccessCard
                } else {
                    switch model.phase {
                    case .idle: idlePanel
                    case .waitingForApp: waitingPanel
                    case .listening: listeningPanel
                    case .finishing: progressPanel("Cleaning up…")
                    case .rewriteMenu: rewriteMenu
                    case .rewriting: progressPanel("Rewriting…")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !showingKeys {
                bottomRow
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(palette.background)
        .overlay(alignment: .top) { messageBanner }
        .tint(palette.accent)
    }

    /// Typing keys replace the dictation panel only at rest; dictation and rewrite progress always show.
    private var showingKeys: Bool { model.showsKeys && model.phase == .idle }

    // MARK: Control layer

    private var controlBar: some View {
        HStack(spacing: 6) {
            ControlButton(title: model.phase == .listening ? "Stop" : "Dictate",
                          systemImage: model.phase == .listening ? "stop.fill" : "mic.fill",
                          prominent: true, active: model.phase == .listening, palette: palette) { model.micTapped() }
            ControlButton(title: "Fix", systemImage: "checkmark.circle", palette: palette) { model.fixTapped() }
                .disabled(!model.rewriteAvailable || !model.canUseTextActions)
            ControlButton(title: "Rewrite", systemImage: "wand.and.stars", active: model.phase == .rewriteMenu, palette: palette) { model.rewriteTapped() }
                .disabled(!model.rewriteAvailable || !model.canUseTextActions)
            ControlButton(title: "Ask", systemImage: "circle.circle", palette: palette) { model.askHarnessTapped() }
                .accessibilityLabel("Ask Harness")
                .disabled(!model.canUseTextActions)
        }
        .frame(height: 40)
    }

    // MARK: Panels

    private var idlePanel: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.modes) { mode in
                        Button(mode.name) { model.selectedModeID = mode.id }
                            .buttonStyle(ChipStyle(selected: model.selectedModeID == mode.id, palette: palette))
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 14) {
                Spacer(minLength: 0)
                if model.canUndo {
                    Button { model.undoTapped() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(ChipStyle(selected: false, palette: palette))
                } else {
                    routeChip
                }
                Button { model.micTapped() } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 68, height: 68)
                        .background(Circle().fill(palette.primaryFill))
                        .foregroundStyle(palette.primaryText)
                }
                .accessibilityLabel("Start dictation")
                Group {
                    if model.micIsWarm {
                        Button { model.endMicSession() } label: { Label("Mic on", systemImage: "waveform") }
                            .buttonStyle(ChipStyle(selected: true, palette: palette))
                            .accessibilityHint("Turns the microphone session off")
                    } else {
                        Text("Tap to talk").font(.footnote).foregroundStyle(palette.secondaryText)
                    }
                }
                .frame(minWidth: 72)
                Spacer(minLength: 0)
            }
        }
    }

    private var routeChip: some View {
        Text(model.routeLabel)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().stroke(palette.border))
            .foregroundStyle(palette.secondaryText)
            .frame(minWidth: 72)
            .accessibilityLabel("Transcription: \(model.routeLabel)")
    }

    private var waitingPanel: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Opening Harness to turn on the mic…").font(.subheadline.weight(.medium))
            Text("Then swipe right along the bottom edge to come back.").font(.footnote).foregroundStyle(palette.secondaryText)
            Button("Cancel") { model.cancel() }.font(.footnote.weight(.medium))
        }
        .multilineTextAlignment(.center)
    }

    private var listeningPanel: some View {
        VStack(spacing: 10) {
            Waveform(level: model.level, color: palette.accent)
                .frame(height: 34)
            Text(model.partialText.isEmpty ? "Listening…" : model.partialText)
                .font(.subheadline)
                .foregroundStyle(model.partialText.isEmpty ? palette.secondaryText : palette.text)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 12)
            HStack(spacing: 16) {
                // Equal side widths keep Stop centered.
                Button { model.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
                        .background(Circle().fill(palette.key))
                }
                .accessibilityLabel("Cancel dictation")
                .frame(width: 84, alignment: .trailing)
                Button { model.micTapped() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 22, weight: .semibold)).frame(width: 60, height: 60)
                        .background(Circle().fill(palette.accent))
                        .foregroundStyle(Color.black)
                }
                .accessibilityLabel("Stop and insert")
                Text(model.routeLabel)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 84, alignment: .leading)
                    .accessibilityLabel("Transcription: \(model.routeLabel)")
            }
        }
    }

    private func progressPanel(_ title: String) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(title).font(.subheadline).foregroundStyle(palette.secondaryText)
            if model.phase == .rewriting {
                Button("Cancel") { model.cancel() }.font(.footnote.weight(.medium))
            }
        }
    }

    private var rewriteMenu: some View {
        VStack(spacing: 8) {
            Text("Rewrite the selection or current paragraph").font(.footnote).foregroundStyle(palette.secondaryText)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.rewriteChoices) { choice in
                    Button(choice.title) { model.rewriteChosen(choice.action) }
                        .buttonStyle(KeyStyle(palette: palette, height: 40))
                }
            }
        }
    }

    private var fullAccessCard: some View {
        VStack(spacing: 8) {
            Text("Turn on Full Access").font(.headline)
            Text("Settings > General > Keyboard > Keyboards > Harness > Allow Full Access. Harness uses it to reach the Harness app on this iPhone. Your audio and text are never stored.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Button("How it works") { model.openSettings() }.font(.footnote.weight(.semibold))
        }
    }

    // MARK: Keys

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if showsGlobe {
                globe().frame(width: 44, height: 42)
            }
            Button { model.toggleKeys() } label: { Image(systemName: "keyboard") }
                .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: true))
                .frame(width: 44)
                .accessibilityLabel("Show keyboard")
            ForEach([",", ".", "?", "!"], id: \.self) { mark in
                Button(mark) { model.insert(mark) }
                    .buttonStyle(KeyStyle(palette: palette, height: 42))
                    .frame(width: 34)
            }
            Button("space") { model.spaceTapped() }
                .buttonStyle(KeyStyle(palette: palette, height: 42))
            RepeatingKey(action: { model.deleteBackward() }) {
                Image(systemName: "delete.left")
            }
            .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: true))
            .frame(width: 48)
            .accessibilityLabel("Delete")
            returnKey
        }
    }

    private var returnKey: some View {
        Button { model.returnTapped() } label: {
            if let title = model.returnKeyTitle {
                Text(verbatim: title).font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            } else {
                Image(systemName: "return")
            }
        }
        .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: true))
        .frame(width: model.returnKeyTitle == nil ? 48 : 74)
        .accessibilityLabel(model.returnKeyTitle ?? "Return")
    }

    // MARK: Typing layer

    private var typingPanel: some View {
        let rows = TypingKeyboard.rows(for: model.plane)
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    ForEach(rows[index], id: \.self) { key in
                        typingKey(key)
                    }
                }
                // The 9-key middle letter row sits inset, as on the system keyboard.
                .padding(.horizontal, model.plane == .letters && index == 1 ? 17 : 0)
            }
            typingBottomRow
        }
    }

    @ViewBuilder
    private func typingKey(_ key: TypingKey) -> some View {
        switch key {
        case .character(let character):
            Button { model.keyTapped(key) } label: {
                Text(verbatim: model.plane == .letters ? model.shift.apply(to: character) : character)
            }
            .buttonStyle(KeyStyle(palette: palette, height: 42))
        case .shift:
            Button { model.keyTapped(key) } label: { Image(systemName: shiftSymbol) }
                .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: !model.shift.isActive))
                .frame(width: 44)
                .accessibilityLabel(model.shift.state == .locked ? "Caps lock" : "Shift")
                .accessibilityValue(model.shift.isActive ? "On" : "Off")
        case .delete:
            RepeatingKey(action: { model.keyTapped(key) }) {
                Image(systemName: "delete.left")
            }
            .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: true))
            .frame(width: 44)
            .accessibilityLabel("Delete")
        case .plane(let plane):
            Button { model.keyTapped(key) } label: {
                Text(verbatim: plane == .symbols ? "#+=" : "123").font(.system(size: 15))
            }
            .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: true))
            .frame(width: 44)
            .accessibilityLabel(plane == .symbols ? "More symbols" : "Numbers")
        }
    }

    private var shiftSymbol: String {
        switch model.shift.state {
        case .off: return "shift"
        case .once: return "shift.fill"
        case .locked: return "capslock.fill"
        }
    }

    private var typingBottomRow: some View {
        HStack(spacing: 5) {
            Button { model.keyTapped(.plane(model.plane == .letters ? .numbers : .letters)) } label: {
                Text(verbatim: model.plane == .letters ? "123" : "ABC").font(.system(size: 15))
            }
            .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: true))
            .frame(width: 44)
            .accessibilityLabel(model.plane == .letters ? "Numbers" : "Letters")
            if showsGlobe {
                globe().frame(width: 40, height: 42)
            }
            Button { model.toggleKeys() } label: { Image(systemName: "waveform") }
                .buttonStyle(KeyStyle(palette: palette, height: 42, secondary: true))
                .frame(width: 40)
                .accessibilityLabel("Show dictation panel")
            ForEach(model.spaceBarNeighbors, id: \.self) { key in
                Button { model.insert(key) } label: { Text(verbatim: key) }
                    .buttonStyle(KeyStyle(palette: palette, height: 42))
                    .frame(width: 34)
            }
            Button("space") { model.spaceTapped() }
                .buttonStyle(KeyStyle(palette: palette, height: 42))
            returnKey
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let message = model.message {
            Text(message)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(palette.banner))
                .foregroundStyle(palette.text)
                .padding(.top, 50)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Pieces

struct KeyboardPalette {
    let background, key, secondaryKey, text, secondaryText, border, accent, primaryFill, primaryText, banner: Color

    init(_ scheme: ColorScheme) {
        accent = Color(red: 1.0, green: 0.30, blue: 0.24) // #FF4D3D
        if scheme == .dark {
            background = Color(red: 0.08, green: 0.08, blue: 0.09)
            key = Color(red: 0.23, green: 0.23, blue: 0.25)
            secondaryKey = Color(red: 0.15, green: 0.15, blue: 0.17)
            text = Color(red: 0.95, green: 0.95, blue: 0.95)
            secondaryText = Color(red: 0.66, green: 0.66, blue: 0.69)
            border = Color(red: 0.20, green: 0.20, blue: 0.23)
            primaryFill = Color(red: 0.95, green: 0.95, blue: 0.95)
            primaryText = Color(red: 0.04, green: 0.04, blue: 0.05)
            banner = Color(red: 0.16, green: 0.16, blue: 0.18)
        } else {
            background = Color(red: 0.82, green: 0.83, blue: 0.86)
            key = .white
            secondaryKey = Color(red: 0.67, green: 0.69, blue: 0.73)
            text = Color(red: 0.07, green: 0.07, blue: 0.08)
            secondaryText = Color(red: 0.30, green: 0.31, blue: 0.34)
            border = Color(red: 0.62, green: 0.63, blue: 0.67)
            primaryFill = Color(red: 0.07, green: 0.07, blue: 0.08)
            primaryText = .white
            banner = .white
        }
    }
}

struct ControlButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var active = false
    let palette: KeyboardPalette
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(fill))
                .foregroundStyle(foreground)
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }

    private var fill: Color {
        if active { return palette.accent }
        return prominent ? palette.primaryFill : palette.key
    }

    private var foreground: Color {
        if active { return .black }
        return prominent ? palette.primaryText : palette.text
    }
}

struct KeyStyle: ButtonStyle {
    let palette: KeyboardPalette
    var height: CGFloat = 42
    var secondary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(RoundedRectangle(cornerRadius: 7).fill(configuration.isPressed ? palette.secondaryKey : (secondary ? palette.secondaryKey : palette.key)))
            .foregroundStyle(palette.text)
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
    }
}

struct ChipStyle: ButtonStyle {
    let selected: Bool
    let palette: KeyboardPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(selected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(selected ? palette.primaryFill : palette.key))
            .foregroundStyle(selected ? palette.primaryText : palette.text)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Deletes once on tap and keeps deleting while held (after 0.4 s, every 0.1 s).
struct RepeatingKey<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var repeater: Task<Void, Never>?
    @GestureState private var pressing = false

    var body: some View {
        Button(action: {}) { label() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
                    .onChanged { _ in
                        guard repeater == nil else { return }
                        action()
                        repeater = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                        }
                    }
                    .onEnded { _ in stopRepeating() }
            )
            // A cancelled gesture never calls onEnded, but it does reset `pressing`.
            .onChange(of: pressing) { _, isPressing in
                if !isPressing { stopRepeating() }
            }
            .onDisappear { stopRepeating() }
    }

    private func stopRepeating() {
        repeater?.cancel()
        repeater = nil
    }
}

struct Waveform: View {
    let level: Float
    let color: Color
    private let weights: [CGFloat] = [0.35, 0.6, 0.9, 0.7, 1.0, 0.8, 0.55, 0.95, 0.65, 0.4, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: max(4, 34 * CGFloat(level) * weights[i]))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
#endif
