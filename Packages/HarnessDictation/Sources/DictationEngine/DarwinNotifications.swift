#if os(iOS)
import Foundation

/// Darwin notifications are the only cross-process signal available to a keyboard extension.
/// They carry no payload; they just say "go read the file".
public final class DarwinNotificationObserver {
    private let name: String
    private let handler: () -> Void

    public init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let me = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { me.handler() }
        }
        CFNotificationCenterAddObserver(center, observer, callback, name as CFString, nil, .deliverImmediately)
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(center, Unmanaged.passUnretained(self).toOpaque(), CFNotificationName(name as CFString), nil)
    }

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}
#endif
