import SwiftUI
import HarnessCore

enum HarnessTheme {
    static let background = Color(red: 0.065, green: 0.070, blue: 0.070)
    static let surface = Color(red: 0.115, green: 0.122, blue: 0.122)
    static let raised = Color(red: 0.155, green: 0.160, blue: 0.160)
    static let text = Color(red: 0.94, green: 0.91, blue: 0.85)
    static let secondary = Color(red: 0.60, green: 0.63, blue: 0.62)
    static let coral = Color(red: 0.98, green: 0.49, blue: 0.38)
    static let amber = Color(red: 0.89, green: 0.76, blue: 0.48)
    static let green = Color(red: 0.62, green: 0.78, blue: 0.66)
    static let border = Color.white.opacity(0.09)
}

struct HarnessMark: View {
    var size: CGFloat = 72
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(HarnessTheme.coral)
            Image(systemName: "h.square.fill")
                .font(.system(size: size * 0.62, weight: .light))
                .foregroundStyle(HarnessTheme.background)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    var title: String
    var symbol: String = "circle.fill"
    var color: Color = HarnessTheme.green
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 1))
    }
}

struct HarnessCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(HarnessTheme.border, lineWidth: 1))
    }
}

struct HarnessErrorBanner: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let error = model.error {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(HarnessTheme.coral)
                Text(error).font(.subheadline).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { model.clearError() } label: {
                    Image(systemName: "xmark").font(.caption)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss error")
            }
            .padding(15).background(HarnessTheme.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
        }
    }
}

struct SectionEyebrow: View {
    var title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title.uppercased())
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .tracking(1.8).foregroundStyle(HarnessTheme.secondary)
        .padding(.top, 10)
    }
}

struct HarnessEmptyState: View {
    var symbol: String
    var title: String
    var detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(HarnessTheme.amber)
            Text(title).font(.system(.title2, design: .serif))
            Text(detail).font(.subheadline).foregroundStyle(HarnessTheme.secondary).lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 15)
    }
}

struct SettingsRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    var color: Color = HarnessTheme.amber
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                .foregroundStyle(color).frame(width: 42, height: 42)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(HarnessTheme.text)
                Text(subtitle).font(.caption).foregroundStyle(HarnessTheme.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HarnessTheme.secondary)
        }
        .padding(.vertical, 5).frame(minHeight: 44).contentShape(Rectangle())
    }
}

struct CapabilityTags: View {
    let capabilities: Set<Capability>
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(capabilities.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                Label(capability.rawValue, systemImage: "key.horizontal")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(HarnessTheme.amber)
            }
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .foregroundStyle(HarnessTheme.background).padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(HarnessTheme.coral.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 15))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct HarnessScreenModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(HarnessTheme.text)
            .background(HarnessTheme.background)
            .toolbarBackground(HarnessTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(HarnessTheme.coral)
    }
}

extension View {
    func harnessScreen() -> some View { modifier(HarnessScreenModifier()) }
}
