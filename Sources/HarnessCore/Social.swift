import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SocialServiceURL: Sendable, Equatable {
    public let url: URL
    public init(_ value: String, allowLoopbackHTTP: Bool = false) throws {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (allowLoopbackHTTP && parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
        else { throw SocialError(status: 0, message: "Enter an HTTPS service address, such as https://social.example.com, without a path or password.") }
        parts.path = ""
        parts.host = host.lowercased()
        guard let url = parts.url else { throw SocialError(status: 0, message: "The service address is invalid.") }
        self.url = url
    }
}

public struct SocialError: Error, LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public init(status: Int, message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}

public struct SocialProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var handle: String
    public var displayName: String
    public var followerCount: Int
    public var followingCount: Int
    public var following: Bool
    public var muted: Bool
}

public struct SocialPost: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var author: SocialProfile
    public var text: String
    public var parentID: String?
    public var createdAt: TimeInterval
    public var deleted: Bool
    public var replyCount: Int
    public var likeCount: Int
    public var repostCount: Int
    public var liked: Bool
    public var reposted: Bool
    public var date: Date { Date(timeIntervalSince1970: createdAt) }
}

public struct SocialFeedItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var sequence: Int
    public var post: SocialPost
    public var repostedBy: SocialProfile?
}
public struct SocialFeedPage: Codable, Sendable {
    public var items: [SocialFeedItem]
    public var nextCursor: Int?
}
public struct SocialThread: Codable, Sendable {
    public var post: SocialPost
    public var replies: [SocialPost]
    public var nextCursor: Int?
}
public struct SocialProfilePage: Codable, Sendable {
    public var profile: SocialProfile
    public var posts: [SocialPost]
}
public struct SocialSession: Codable, Sendable {
    public var token: String
    public var expiresAt: TimeInterval
    public var profile: SocialProfile
}
public enum SocialFeedMode: String, CaseIterable, Sendable {
    case all, following
    public var title: String { self == .all ? "Everyone" : "Following" }
}

/// Stored only on this device, independently of public content and agent context.
public struct SocialDraft: Codable, Equatable, Sendable {
    public private(set) var text: String
    public let parentID: String?
    public private(set) var idempotencyKey: String
    public init(text: String = "", parentID: String? = nil) {
        self.text = text; self.parentID = parentID; self.idempotencyKey = UUID().uuidString
    }
    public var characterCount: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }
    public var canPublish: Bool { characterCount > 0 && characterCount <= 500 }
    public mutating func updateText(_ value: String) {
        guard value != text else { return }
        text = value
        idempotencyKey = UUID().uuidString
    }
    public static func scope(service: String, account: String, parentID: String?) -> String {
        // Length prefixes avoid collisions if a future service or identifier contains separators.
        [service, account, parentID ?? ""].map { "\($0.utf8.count):\($0)" }.joined()
    }
}

private final class SocialRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Social credentials and traffic never use the companion or the agent permission channel.
public final class SocialClient: @unchecked Sendable {
    public let service: SocialServiceURL
    private let token: String?
    private let session: URLSession
    public init(service: SocialServiceURL, token: String? = nil) {
        self.service = service; self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: SocialRedirectPolicy(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func signIn(handle: String, password: String, displayName: String? = nil) async throws -> SocialSession {
        var body = ["handle": handle, "password": password]
        if let displayName { body["displayName"] = displayName }
        return try await request("POST", displayName == nil ? "/login" : "/register", body: body)
    }
    public func me() async throws -> SocialProfile { try await request("GET", "/me") }
    public func signOut() async throws {
        let _: Acknowledgement = try await request("POST", "/logout", body: [:])
    }
    public func feed(_ mode: SocialFeedMode, before: Int? = nil) async throws -> SocialFeedPage {
        var query = [URLQueryItem(name: "mode", value: mode.rawValue)]
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        return try await request("GET", "/feed", query: query)
    }
    public func publish(_ draft: SocialDraft) async throws -> SocialPost {
        guard draft.canPublish else { throw SocialError(status: 400, message: "Write between 1 and 500 characters.") }
        var body = ["text": draft.text]
        if let parentID = draft.parentID { body["parentID"] = parentID }
        return try await request("POST", "/posts", body: body, idempotencyKey: draft.idempotencyKey)
    }
    public func thread(_ postID: String, after: Int? = nil) async throws -> SocialThread {
        try validateID(postID)
        return try await request("GET", "/posts/\(postID)/thread", query: after.map { [URLQueryItem(name: "after", value: String($0))] } ?? [])
    }
    public func profile(_ handle: String) async throws -> SocialProfilePage {
        let handle = try validatedHandle(handle)
        return try await request("GET", "/profiles/\(handle)")
    }
    public func setLike(_ postID: String, enabled: Bool) async throws -> SocialPost {
        try validateID(postID)
        return try await request(enabled ? "PUT" : "DELETE", "/posts/\(postID)/like")
    }
    public func setRepost(_ postID: String, enabled: Bool) async throws -> SocialPost {
        try validateID(postID)
        return try await request(enabled ? "PUT" : "DELETE", "/posts/\(postID)/repost")
    }
    public func delete(_ postID: String) async throws -> SocialPost {
        try validateID(postID)
        return try await request("DELETE", "/posts/\(postID)")
    }
    public func setFollow(_ handle: String, enabled: Bool) async throws -> SocialProfile {
        let handle = try validatedHandle(handle)
        return try await request(enabled ? "PUT" : "DELETE", "/profiles/\(handle)/follow")
    }
    public func setMute(_ handle: String, enabled: Bool) async throws -> SocialProfile {
        let handle = try validatedHandle(handle)
        return try await request(enabled ? "PUT" : "DELETE", "/profiles/\(handle)/mute")
    }
    private func validatedHandle(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard value.range(of: "^[a-z0-9_]{1,24}$", options: .regularExpression) != nil else {
            throw SocialError(status: 400, message: "Enter a handle using letters, numbers, or underscores.")
        }
        return value
    }
    private func validateID(_ value: String) throws {
        guard value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw SocialError(status: 400, message: "The post address is invalid.")
        }
    }
    private struct Acknowledgement: Decodable { let ok: Bool }
    private struct ErrorEnvelope: Decodable { let error: String }
    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                       body: [String: String]? = nil, idempotencyKey: String? = nil) async throws -> T {
        var parts = URLComponents(url: service.url, resolvingAgainstBaseURL: false)!
        parts.path = "/v1" + path
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 1_048_576 else {
            throw SocialError(status: 0, message: "Social returned an unreadable response.")
        }
        guard (200...299).contains(response.statusCode) else {
            let serverError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            throw SocialError(status: response.statusCode, message: serverError?.error ?? "Social could not finish that request (\(response.statusCode)).")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SocialError(status: 0, message: "This Social service uses an incompatible response format.") }
    }
}

public struct SocialDraftArchive: Codable, Sendable {
    private var drafts: [String: SocialDraft] = [:]
    public init() {}
    public func draft(scope: String, parentID: String?) -> SocialDraft {
        drafts[scope] ?? SocialDraft(parentID: parentID)
    }
    public mutating func update(_ text: String, scope: String, parentID: String?) {
        var draft = draft(scope: scope, parentID: parentID)
        draft.updateText(text)
        drafts[scope] = draft
    }
    public mutating func acknowledge(scope: String, idempotencyKey: String) {
        if drafts[scope]?.idempotencyKey == idempotencyKey { drafts.removeValue(forKey: scope) }
    }
}
