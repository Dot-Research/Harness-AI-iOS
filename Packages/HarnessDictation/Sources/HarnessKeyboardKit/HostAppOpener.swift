#if os(iOS)
import ObjectiveC
import UIKit

/// Opens the Harness app from the keyboard.
///
/// Keyboard extensions have no supported API for opening URLs, so this walks the responder chain to
/// the extension process's UIApplication and calls `openURL:options:completionHandler:` dynamically.
/// This is the approach shipping dictation keyboards use; keep it isolated here so it can be
/// swapped if Apple adds a sanctioned API. If it fails, the keyboard shows a "Open Harness"
/// instruction instead.
///
/// Since iOS 26.4 the system no longer returns the user to the previous app automatically, so the
/// app shows "Swipe right along the bottom edge to go back" while the microphone warms up.
enum HostAppOpener {
    @discardableResult
    static func open(_ url: URL, from responder: UIResponder) -> Bool {
        var current: UIResponder? = responder
        while let node = current {
            if let application = node as? UIApplication {
                return invokeOpen(on: application, url: url)
            }
            current = node.next
        }
        return false
    }

    private static func invokeOpen(on application: UIApplication, url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard let method = class_getInstanceMethod(type(of: application), selector) else { return false }
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let implementation = unsafeBitCast(method_getImplementation(method), to: OpenURL.self)
        implementation(application, selector, url as NSURL, NSDictionary(), nil)
        return true
    }
}
#endif
