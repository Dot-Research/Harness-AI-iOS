import Foundation
import CSQLite

public enum StoreError: LocalizedError {
    case database(String), corrupt(String)
    public var errorDescription: String? {
        switch self {
        case .database(let detail): return "The local store could not complete its transaction: \(detail)"
        case .corrupt(let detail): return "The local store contains unreadable data. It was preserved for recovery: \(detail)"
        }
    }
}

/// Serializes updates and commits all related session, learning, and audit changes together.
/// The database lives in the app sandbox; credentials are never part of HarnessState.
public actor SQLiteHarnessStore: HarnessStore {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cached: HarnessState?

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.deletingLastPathComponent().path)
        #endif
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if db != nil { sqlite3_close(db) }; db = nil
            throw StoreError.database(detail)
        }
        sqlite3_busy_timeout(db, 5_000)
        for sql in ["PRAGMA journal_mode=WAL", "PRAGMA synchronous=FULL", "PRAGMA foreign_keys=ON", "CREATE TABLE IF NOT EXISTS records (collection TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(collection,id))", "PRAGMA user_version=1"] {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let detail = String(cString: sqlite3_errmsg(db)); sqlite3_close(db); db = nil
                throw StoreError.database(detail)
            }
        }
        #if os(iOS)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path)
        }
        #endif
    }
    deinit { sqlite3_close(db) }

    public func load() throws -> HarnessState {
        if let cached { return cached }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, "SELECT collection, payload FROM records ORDER BY rowid", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        var state = HarnessState()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            try check(result, expected: SQLITE_ROW)
            guard let kindBytes = sqlite3_column_text(statement, 0), let payloadBytes = sqlite3_column_text(statement, 1) else { throw StoreError.corrupt("missing record") }
            let kind = String(cString: kindBytes)
            let data = Data(String(cString: payloadBytes).utf8)
            do {
                switch kind {
                case "settings": state = try decoder.decode(HarnessState.self, from: data)
                case "sessions": state.sessions.append(try decoder.decode(AgentSession.self, from: data))
                case "skills": state.skills.append(try decoder.decode(Skill.self, from: data))
                case "agents": state.agents.append(try decoder.decode(AgentProfile.self, from: data))
                case "proposals": state.proposals.append(try decoder.decode(LearningProposal.self, from: data))
                case "journey": state.journey.append(try decoder.decode(JourneyEntry.self, from: data))
                case "activity": state.activity.append(try decoder.decode(ActivityEntry.self, from: data))
                default: throw StoreError.corrupt("unknown collection \(kind)")
                }
            } catch let error as StoreError { throw error }
            catch { throw StoreError.corrupt(kind) }
        }
        cached = state
        return state
    }

    public func update(_ change: @Sendable (inout HarnessState) -> Void) throws {
        var state = try load()
        change(&state)
        // Encode before BEGIN: an encoding failure cannot erase existing data.
        var settings = state
        settings.sessions = []; settings.skills = []; settings.agents = []
        settings.proposals = []; settings.journey = []; settings.activity = []
        var records: [(String, String, String)] = []
        func add<T: Encodable>(_ collection: String, _ id: String, _ value: T) throws {
            records.append((collection, id, String(decoding: try encoder.encode(value), as: UTF8.self)))
        }
        try add("settings", "singleton", settings)
        for item in state.sessions { try add("sessions", item.id.uuidString, item) }
        for item in state.skills { try add("skills", item.id, item) }
        for item in state.agents { try add("agents", item.id, item) }
        for item in state.proposals { try add("proposals", item.id.uuidString, item) }
        for item in state.journey { try add("journey", item.id.uuidString, item) }
        for item in state.activity { try add("activity", item.id.uuidString, item) }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM records")
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "INSERT INTO records(collection,id,payload) VALUES(?,?,?)", -1, &statement, nil))
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for record in records {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try check(sqlite3_bind_text(statement, 1, record.0, -1, transient))
                try check(sqlite3_bind_text(statement, 2, record.1, -1, transient))
                try check(sqlite3_bind_text(statement, 3, record.2, -1, transient))
                try check(sqlite3_step(statement), expected: SQLITE_DONE)
            }
            try execute("COMMIT")
            cached = state
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    private func execute(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil)) }
    private func check(_ code: Int32, expected: Int32 = SQLITE_OK) throws {
        guard code == expected else { throw StoreError.database(String(cString: sqlite3_errmsg(db))) }
    }
}
