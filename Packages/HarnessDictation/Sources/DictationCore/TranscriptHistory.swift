import Foundation

/// Opt-in, text-only history kept in the app's own container (never the shared App Group, never
/// audio). Entries expire after the retention period.
public struct TranscriptHistory: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Identifiable, Sendable {
        public var id: UUID
        public var text: String
        public var modeID: String
        public var route: TranscriptionRoute?
        public var createdAt: Date

        public init(id: UUID = UUID(), text: String, modeID: String, route: TranscriptionRoute?, createdAt: Date) {
            self.id = id
            self.text = text
            self.modeID = modeID
            self.route = route
            self.createdAt = createdAt
        }
    }

    public private(set) var entries: [Entry]
    public var maxEntries: Int

    public init(entries: [Entry] = [], maxEntries: Int = 500) {
        self.entries = entries
        self.maxEntries = maxEntries
    }

    public mutating func add(_ entry: Entry, retentionDays: Int, now: Date = Date()) {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(entry, at: 0)
        purge(retentionDays: retentionDays, now: now)
    }

    public mutating func purge(retentionDays: Int, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, retentionDays)) * 86_400)
        entries.removeAll { $0.createdAt < cutoff }
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    public func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
