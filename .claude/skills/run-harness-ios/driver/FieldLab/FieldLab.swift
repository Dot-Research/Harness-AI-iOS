// FieldLab: text fields with known traits, so the Harness Keyboard can be driven deterministically.
// Each field's accessibilityIdentifier is its name; XCUITest reads the text back through `.value`.
import SwiftUI
import UIKit

@main
struct FieldLabApp: App {
    var body: some Scene {
        WindowGroup { FieldList() }
    }
}

struct FieldSpec: Identifiable {
    let id: String
    var keyboard: UIKeyboardType = .default
    var returnKey: UIReturnKeyType = .default
    var capitalization: UITextAutocapitalizationType = .sentences
    var multiline = false
}

let fieldSpecs: [FieldSpec] = [
    FieldSpec(id: "plain"),
    FieldSpec(id: "notes", multiline: true),
    FieldSpec(id: "email", keyboard: .emailAddress, capitalization: .none),
    FieldSpec(id: "send", returnKey: .send),
    FieldSpec(id: "search", keyboard: .webSearch, returnKey: .search),
    FieldSpec(id: "url", keyboard: .URL, returnKey: .go, capitalization: .none),
]

struct FieldList: View {
    var body: some View {
        // `-only <id>` shows one field (largest tap target, nothing scrolls under the keyboard).
        let only = UserDefaults.standard.string(forKey: "only")
        VStack(alignment: .leading, spacing: 10) {
            Text("FieldLab").font(.headline)
            ForEach(fieldSpecs.filter { only == nil || $0.id == only }) { spec in
                Text(spec.id).font(.caption).foregroundStyle(.secondary)
                Field(spec: spec).frame(height: spec.multiline ? 90 : 36)
            }
            Spacer()
        }
        .padding()
    }
}

struct Field: UIViewRepresentable {
    let spec: FieldSpec

    func makeUIView(context: Context) -> UIView {
        if spec.multiline {
            let text = UITextView()
            text.font = .preferredFont(forTextStyle: .body)
            text.layer.borderWidth = 1
            text.layer.borderColor = UIColor.separator.cgColor
            text.keyboardType = spec.keyboard
            text.returnKeyType = spec.returnKey
            text.autocapitalizationType = spec.capitalization
            text.autocorrectionType = .no
            text.spellCheckingType = .no
            text.accessibilityIdentifier = spec.id
            return text
        }
        let text = UITextField()
        text.borderStyle = .roundedRect
        text.placeholder = spec.id
        text.keyboardType = spec.keyboard
        text.returnKeyType = spec.returnKey
        text.autocapitalizationType = spec.capitalization
        text.autocorrectionType = .no
        text.spellCheckingType = .no
        text.accessibilityIdentifier = spec.id
        return text
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
