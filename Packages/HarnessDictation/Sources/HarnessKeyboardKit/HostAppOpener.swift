#if os(iOS)
import ObjectiveC
import UIKit

/// Opens the Harness app from the keyboard.
///
/// Keyboard extensions have no supported API for opening URLs, so this walks the responder chain to
/// the extension process's UIApplication and calls `openURL:options:completionHandler:` dynamically.
/// This is an experimental compatibility path, not a supported keyboard-extension API.
/// A true return only means invocation was attempted; it does not prove that iOS opened the app.
/// Supported cold-start alternatives are the app's Start Speak shortcut or manual activation.
/// If the attempt fails, the keyboard explains how to open Harness instead.
///
/// Automatic return to the originating app is not assumed. The handoff screen tells the user
/// how to return after the app starts the microphone.
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
