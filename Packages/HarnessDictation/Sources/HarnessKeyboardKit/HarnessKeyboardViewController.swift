#if os(iOS)
import SwiftUI
import UIKit
import DictationEngine

/// The keyboard extension's principal class. In the extension target, subclass it (or use it
/// directly via NSExtensionPrincipalClass) and set `appGroupIdentifier` if yours differs.
open class HarnessKeyboardViewController: UIInputViewController {
    open var appGroupIdentifier: String { "group.org.harness.ios" }
    open var keyboardHeight: CGFloat { 286 }

    public private(set) lazy var model = KeyboardViewModel(group: AppGroupConfiguration(identifier: appGroupIdentifier))
    private var hosting: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?

    open override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self

        let root = KeyboardRootView(model: model, showsGlobe: needsInputModeSwitchKey) { [weak self] in
            AnyView(GlobeKey(controller: self))
        }
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        self.hosting = hosting

        let height = view.heightAnchor.constraint(equalToConstant: keyboardHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hosting?.rootView = KeyboardRootView(model: model, showsGlobe: needsInputModeSwitchKey) { [weak self] in
            AnyView(GlobeKey(controller: self))
        }
        model.appear(hasFullAccess: hasFullAccess)
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    open override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.textDidChange()
    }
}

/// The globe key must be a UIKit control so it can show the system's input-mode list.
private struct GlobeKey: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.backgroundColor = .secondarySystemFill
        button.layer.cornerRadius = 7
        button.accessibilityLabel = "Next keyboard"
        if let controller {
            button.addTarget(controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
#endif
