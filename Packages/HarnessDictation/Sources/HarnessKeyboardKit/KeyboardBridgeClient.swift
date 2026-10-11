#if os(iOS)
import Foundation
import DictationCore
import DictationEngine

/// The keyboard's side of the bridge: appends commands to the queue and watches the app's status.
/// Requires Full Access (the App Group container is closed to keyboards without it).
@MainActor
public final class KeyboardBridgeClient {
    public var onStatus: ((HostStatus) -> Void)?

    private let files: BridgeFiles?
    private var observer: DarwinNotificationObserver?
    private var pollTimer: Timer?
    public private(set) var status = HostStatus()

    public init(group: AppGroupConfiguration) {
        files = BridgeFiles(group: group)
        status = files?.readStatus() ?? HostStatus()
    }

    public var isAvailable: Bool { files != nil }

    /// Begin watching status. Darwin notifications are the fast path; a light poll covers the rare
    /// missed notification while something is in flight.
    public func startObserving() {
        observer = DarwinNotificationObserver(name: BridgeNames.statusChanged) { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    public func stopObserving() {
        observer = nil
        setPolling(false)
    }

    public func setPolling(_ on: Bool) {
        if on, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else if !on {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    public func refresh() {
        guard let files else { return }
        status = files.readStatus()
        onStatus?(status)
    }

    @discardableResult
    public func send(_ kind: BridgeCommandKind) -> BridgeCommand? {
        guard let files else { return nil }
        var queue = files.readQueue()
        queue.prune(processedThrough: status.lastProcessedSeq)
        let command = queue.append(kind)
        files.writeQueue(queue)
        DarwinNotificationObserver.post(BridgeNames.commandsPosted)
        return command
    }
}
#endif
