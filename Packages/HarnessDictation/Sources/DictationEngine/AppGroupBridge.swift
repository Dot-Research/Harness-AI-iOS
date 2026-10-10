#if os(iOS)
import Combine
import Foundation
import DictationCore

/// The App Group shared by the Harness app and the Harness Keyboard extension.
public struct AppGroupConfiguration: Sendable {
    public var identifier: String

    public init(identifier: String = "group.org.harness.ios") {
        self.identifier = identifier
    }

    public var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// Directory for the bridge files. Excluded from backups; transient by design.
    public func bridgeDirectory() -> URL? {
        guard var url = containerURL?.appendingPathComponent("Dictation", isDirectory: true) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            return nil
        }
        return url
    }
}

/// Reads and writes the two bridge files. Each file has exactly one writer process.
public final class BridgeFiles {
    private let commandsURL: URL
    private let statusURL: URL

    public init?(group: AppGroupConfiguration) {
        guard let directory = group.bridgeDirectory() else { return nil }
        commandsURL = directory.appendingPathComponent(BridgeNames.commandsFile)
        statusURL = directory.appendingPathComponent(BridgeNames.statusFile)
    }

    public func readQueue() -> CommandQueue {
        guard let data = try? Data(contentsOf: commandsURL),
              let queue = try? BridgeCodec.decode(CommandQueue.self, from: data) else { return CommandQueue() }
        return queue
    }

    /// Keyboard only.
    public func writeQueue(_ queue: CommandQueue) {
        guard let data = try? BridgeCodec.encode(queue) else { return }
        try? data.write(to: commandsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func readStatus() -> HostStatus {
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? BridgeCodec.decode(HostStatus.self, from: data) else { return HostStatus() }
        return status
    }

    /// App only.
    public func writeStatus(_ status: HostStatus) {
        guard let data = try? BridgeCodec.encode(status) else { return }
        try? data.write(to: statusURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Settings shared through App Group defaults (no secrets in here).
public final class DictationSettingsStore: ObservableObject {
    @Published public private(set) var settings: DictationSettings
    private let defaults: UserDefaults?
    private var observer: DarwinNotificationObserver?

    public init(group: AppGroupConfiguration) {
        defaults = group.defaults
        settings = DictationSettings.decode(group.defaults?.data(forKey: BridgeNames.settingsKey))
        observer = DarwinNotificationObserver(name: BridgeNames.settingsChanged) { [weak self] in
            self?.reload()
        }
    }

    public func update(_ change: (inout DictationSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        settings = copy
        defaults?.set(copy.encoded(), forKey: BridgeNames.settingsKey)
        DarwinNotificationObserver.post(BridgeNames.settingsChanged)
    }

    public func reload() {
        let fresh = DictationSettings.decode(defaults?.data(forKey: BridgeNames.settingsKey))
        if fresh != settings { settings = fresh }
    }
}

/// What the keyboard reports about itself, so the app can show setup status.
public struct KeyboardPresence: Codable, Equatable, Sendable {
    public var lastSeen: Date
    public var hasFullAccess: Bool

    public init(lastSeen: Date, hasFullAccess: Bool) {
        self.lastSeen = lastSeen
        self.hasFullAccess = hasFullAccess
    }

    public static func read(from group: AppGroupConfiguration) -> KeyboardPresence? {
        guard let data = group.defaults?.data(forKey: BridgeNames.keyboardSeenKey) else { return nil }
        return try? JSONDecoder().decode(KeyboardPresence.self, from: data)
    }

    public func write(to group: AppGroupConfiguration) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        group.defaults?.set(data, forKey: BridgeNames.keyboardSeenKey)
    }
}
#endif
