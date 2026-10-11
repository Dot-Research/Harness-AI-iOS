@_exported import Foundation
@_exported import ObjectiveC

// UIKit is imported from Objective-C, which Swift treats as @preconcurrency.
@preconcurrency @MainActor open class UIResponder: NSObject {
    open var next: UIResponder? { nil }
}

public struct UIApplicationOpenExternalURLOptionsKey: Hashable, Sendable { public var rawValue: String }

@preconcurrency @MainActor open class UIApplication: UIResponder {
    public class var shared: UIApplication { fatalError() }
    nonisolated public static let openSettingsURLString = "app-settings:"
    nonisolated public static let didBecomeActiveNotification = Notification.Name("UIApplicationDidBecomeActiveNotification")
    open func open(_ url: URL, options: [UIApplicationOpenExternalURLOptionsKey: Any] = [:], completionHandler: (@MainActor @Sendable (Bool) -> Void)? = nil) {}
}

open class CALayer: NSObject { open var cornerRadius: CGFloat = 0 }

@preconcurrency @MainActor open class UIColor: NSObject {
    public class var clear: UIColor { fatalError() }
    public class var label: UIColor { fatalError() }
    public class var secondarySystemFill: UIColor { fatalError() }
    public class var systemBackground: UIColor { fatalError() }
}

@preconcurrency @MainActor open class UIImage: NSObject {
    public init?(systemName: String) { super.init() }
}

@preconcurrency @MainActor open class NSLayoutConstraint: NSObject {
    open var priority: UILayoutPriority = UILayoutPriority(1000)
    open var isActive = false
    public class func activate(_ constraints: [NSLayoutConstraint]) {}
}
public struct UILayoutPriority: Hashable, Sendable {
    public var rawValue: Float
    public init(_ rawValue: Float) { self.rawValue = rawValue }
}
@preconcurrency @MainActor open class NSLayoutAnchor<AnchorType: AnyObject>: NSObject {
    open func constraint(equalTo anchor: NSLayoutAnchor<AnchorType>) -> NSLayoutConstraint { fatalError() }
}
@preconcurrency @MainActor open class NSLayoutXAxisAnchor: NSLayoutAnchor<NSLayoutXAxisAnchor> {}
@preconcurrency @MainActor open class NSLayoutYAxisAnchor: NSLayoutAnchor<NSLayoutYAxisAnchor> {}
@preconcurrency @MainActor open class NSLayoutDimension: NSLayoutAnchor<NSLayoutDimension> {
    open func constraint(equalToConstant c: CGFloat) -> NSLayoutConstraint { fatalError() }
}

@preconcurrency @MainActor open class UIView: UIResponder {
    open var backgroundColor: UIColor?
    open var tintColor: UIColor!
    open var translatesAutoresizingMaskIntoConstraints = true
    open var layer: CALayer { fatalError() }
    open var accessibilityLabel: String?
    open var leadingAnchor: NSLayoutXAxisAnchor { fatalError() }
    open var trailingAnchor: NSLayoutXAxisAnchor { fatalError() }
    open var topAnchor: NSLayoutYAxisAnchor { fatalError() }
    open var bottomAnchor: NSLayoutYAxisAnchor { fatalError() }
    open var heightAnchor: NSLayoutDimension { fatalError() }
    open var widthAnchor: NSLayoutDimension { fatalError() }
    open func addSubview(_ view: UIView) {}
}

@preconcurrency @MainActor open class UIControl: UIView {
    public struct Event: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let touchUpInside = Event(rawValue: 1 << 6)
        public static let allTouchEvents = Event(rawValue: 0xFFF)
    }
    public struct State: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let normal = State([])
    }
    open func addTarget(_ target: Any?, action: Selector, for controlEvents: UIControl.Event) {}
}

@preconcurrency @MainActor open class UIButton: UIControl {
    public enum ButtonType: Int, Sendable { case custom, system }
    public convenience init(type buttonType: UIButton.ButtonType) { self.init() }
    open func setImage(_ image: UIImage?, for state: UIControl.State) {}
}

open class UIEvent: NSObject {}
@MainActor public protocol UITextInput: AnyObject {}

@preconcurrency @MainActor open class UIViewController: UIResponder {
    open var view: UIView! { get { fatalError() } set {} }
    open func viewDidLoad() {}
    open func viewWillAppear(_ animated: Bool) {}
    open func viewWillDisappear(_ animated: Bool) {}
    open func addChild(_ childController: UIViewController) {}
    open func didMove(toParent parent: UIViewController?) {}
}

public enum UIKeyboardType: Int, Sendable {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad, emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}

public enum UIReturnKeyType: Int, Sendable {
    case `default`, go, google, join, next, route, search, send, yahoo, done, emergencyCall, `continue`
}

public struct UITextContentType: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Mirrors how Swift sees the real protocol's optional requirements (they come back optional).
@MainActor public protocol UITextDocumentProxy: AnyObject {
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    var selectedText: String? { get }
    var keyboardType: UIKeyboardType? { get }
    var returnKeyType: UIReturnKeyType? { get }
    var textContentType: UITextContentType?? { get }
    func insertText(_ text: String)
    func deleteBackward()
}

@preconcurrency @MainActor open class UIInputViewController: UIViewController {
    open var textDocumentProxy: UITextDocumentProxy { fatalError() }
    open var hasFullAccess: Bool { fatalError() }
    open var needsInputModeSwitchKey: Bool { fatalError() }
    open func textWillChange(_ textInput: UITextInput?) {}
    open func textDidChange(_ textInput: UITextInput?) {}
    open func handleInputModeList(from view: UIView, with event: UIEvent) {}
}

@preconcurrency @MainActor open class UIImpactFeedbackGenerator: NSObject {
    public enum FeedbackStyle: Int { case light, medium, heavy }
    public init(style: FeedbackStyle) {}
    public func impactOccurred() {}
}

@preconcurrency @MainActor open class UIPasteboard: NSObject {
    public class var general: UIPasteboard { fatalError() }
    open var string: String?
}
