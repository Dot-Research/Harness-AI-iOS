import UIKit
enum HostAppOpener {
    @MainActor @discardableResult static func open(_ url: URL, from responder: UIResponder) -> Bool { false }
}
