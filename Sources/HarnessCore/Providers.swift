import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors intentionally exclude response bodies, endpoint queries, and credentials.
public enum ProviderFailure: Error, LocalizedError, Equatable {
    case invalidEndpoint, unsupportedProvider, missingModel, missingCredential, invalidRequest
    case network, httpStatus(Int), invalidResponse, invalidToolArguments
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Use an HTTPS model endpoint, or HTTP on this device's loopback interface."
        case .unsupportedProvider: return "This provider requires a platform-specific adapter."
        case .missingModel: return "Choose a model for this provider."
        case .missingCredential: return "Add this provider's API key in Settings."
        case .invalidRequest: return "The model request contains an invalid message or credential."
        case .network: return "The model endpoint could not be reached securely."
        case .httpStatus(let status): return "The model provider returned HTTP \(status)."
        case .invalidResponse: return "The model provider returned an unsupported response."
        case .invalidToolArguments: return "The model returned malformed tool arguments."
        }
    }
}

/// An OpenAI-compatible chat completions client. Consent is enforced by AgentRuntime
/// before invoking this provider; the provider never supplies its own permission bypass.
public final class OpenAICompatibleProvider: ModelProvider, @unchecked Sendable {
    public let id: String
    public let isLocal: Bool
    public let endpoint: URL
    private let defaultModel: String
    private let credential: @Sendable () async throws -> String?
    private let session: URLSession

    public init(configuration: ProviderConfiguration,
                credential: @escaping @Sendable () async throws -> String?,
                session: URLSession? = nil) throws {
        guard configuration.kind != .apple else { throw ProviderFailure.unsupportedProvider }
        let endpoint = try Self.validateEndpoint(configuration.endpoint)
        self.id = configuration.id
        self.endpoint = Self.completionsURL(endpoint)
        self.defaultModel = configuration.model
        self.isLocal = Self.isLoopback(endpoint.host)
        self.credential = credential
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }

    public static func validateEndpoint(_ text: String) throws -> URL {
        guard let components = URLComponents(string: text), let url = components.url,
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              components.scheme?.lowercased() == "https" ||
                (components.scheme?.lowercased() == "http" && isLoopback(host)) else {
            throw ProviderFailure.invalidEndpoint
        }
        return url
    }

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost" || normalized == "::1" { return true }
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { value in
            guard let integer = Int(value), (0...255).contains(integer) else { return false }
            return value.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    private static func completionsURL(_ base: URL) -> URL {
        let path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") { return base }
        return base.appendingPathComponent("chat/completions")
    }

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let model = request.model.isEmpty ? defaultModel : request.model
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderFailure.missingModel }
        var body: [String: Any] = ["model": model, "stream": false]
        body["messages"] = try request.messages.map(Self.encodeMessage)
        if !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.parameters))
                return ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": schema]]
            }
            body["tool_choice"] = "auto"
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let secret: String?
        do { secret = try await credential() } catch { throw ProviderFailure.missingCredential }
        if let secret, !secret.isEmpty {
            guard !secret.contains(where: { $0.isNewline || $0 == "\r" }) else { throw ProviderFailure.invalidRequest }
            urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        } else if !isLocal { throw ProviderFailure.missingCredential }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: urlRequest) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ProviderFailure.network }
        guard let http = response as? HTTPURLResponse else { throw ProviderFailure.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw ProviderFailure.httpStatus(http.statusCode) }
        guard data.count <= 8 * 1024 * 1024 else { throw ProviderFailure.invalidResponse }
        return try Self.decodeResponse(data)
    }

    private static func encodeMessage(_ message: AgentMessage) throws -> [String: Any] {
        var encoded: [String: Any] = ["role": message.role.rawValue, "content": message.content]
        if message.role == .tool {
            guard let toolID = message.toolCallID, !toolID.isEmpty else { throw ProviderFailure.invalidRequest }
            encoded["tool_call_id"] = toolID
        }
        if !message.toolCalls.isEmpty {
            guard message.role == .assistant else { throw ProviderFailure.invalidRequest }
            encoded["tool_calls"] = try message.toolCalls.map { call -> [String: Any] in
                let data = try JSONEncoder().encode(call.arguments)
                guard let arguments = String(data: data, encoding: .utf8) else { throw ProviderFailure.invalidRequest }
                return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": arguments]]
            }
        }
        return encoded
    }

    private static func decodeResponse(_ data: Data) throws -> ModelResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else { throw ProviderFailure.invalidResponse }
        let content: String
        if let text = message["content"] as? String { content = text }
        else if let parts = message["content"] as? [[String: Any]] {
            guard parts.allSatisfy({ $0["type"] as? String == "text" && $0["text"] is String }) else { throw ProviderFailure.invalidResponse }
            content = parts.compactMap { $0["text"] as? String }.joined()
        } else if message["content"] == nil || message["content"] is NSNull { content = "" }
        else { throw ProviderFailure.invalidResponse }
        var calls: [ToolCall] = []
        if let rawCalls = message["tool_calls"] {
            guard let rawCalls = rawCalls as? [[String: Any]] else { throw ProviderFailure.invalidResponse }
            var ids = Set<String>()
            for raw in rawCalls {
                guard raw["type"] as? String == "function", let id = raw["id"] as? String, !id.isEmpty,
                      ids.insert(id).inserted, let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String, !name.isEmpty,
                      let arguments = function["arguments"] as? String,
                      let bytes = arguments.data(using: .utf8), bytes.count <= 1024 * 1024,
                      let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: bytes) else {
                    throw ProviderFailure.invalidToolArguments
                }
                calls.append(ToolCall(id: id, name: name, arguments: decoded))
            }
        }
        guard !content.isEmpty || !calls.isEmpty else { throw ProviderFailure.invalidResponse }
        let usage = json["usage"] as? [String: Any]
        return ModelResponse(content: content, toolCalls: calls, inputTokens: usage?["prompt_tokens"] as? Int, outputTokens: usage?["completion_tokens"] as? Int)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum PairingFailure: Error, LocalizedError, Equatable {
    case invalidPayload, expired, insecureURL, invalidFingerprint, certificateMismatch
    case missingCredential, network, httpStatus(Int), invalidResponse, unsupportedTool, capabilityDenied, invalidArguments
    public var errorDescription: String? {
        switch self {
        case .invalidPayload: return "This QR code is not a Harness Companion pairing code."
        case .expired: return "This pairing code has expired. Generate a new code on your computer."
        case .insecureURL: return "Companion connections require an HTTPS address."
        case .invalidFingerprint: return "The pairing code is missing a valid certificate fingerprint."
        case .certificateMismatch: return "The computer's certificate does not match the pairing code. Pair again from the computer."
        case .missingCredential: return "Pair this computer again to restore its credentials."
        case .network: return "The computer could not be reached securely."
        case .httpStatus(let status): return "The companion returned HTTP \(status)."
        case .invalidResponse: return "The companion returned an unsupported response."
        case .unsupportedTool: return "This computer tool is not supported."
        case .capabilityDenied: return "This computer has not granted that capability."
        case .invalidArguments: return "The computer tool's arguments are invalid."
        }
    }
}

/// Pairing tokens stay transient and never belong in HarnessState or activity logs.
public struct CompanionPairingPayload: Decodable, Sendable {
    public let version: Int
    public let url: String
    public let token: String
    public let fingerprint: String
    public let expiresAt: String

    public static func parse(_ text: String, now: Date = Date()) throws -> CompanionPairingPayload {
        guard let bytes = text.data(using: .utf8), bytes.count <= 8192,
              let payload = try? JSONDecoder().decode(Self.self, from: bytes), payload.version == 1,
              validToken(payload.token), payload.expiresAt.hasSuffix("Z") else { throw PairingFailure.invalidPayload }
        _ = try validateURL(payload.url)
        guard validFingerprint(payload.fingerprint) else { throw PairingFailure.invalidFingerprint }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = format.date(from: payload.expiresAt)
        format.formatOptions = [.withInternetDateTime]
        guard let expiration = fractional ?? format.date(from: payload.expiresAt) else { throw PairingFailure.invalidPayload }
        guard expiration > now else { throw PairingFailure.expired }
        return payload
    }

    public static func validateURL(_ text: String) throws -> URL {
        guard let components = URLComponents(string: text), let url = components.url,
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw PairingFailure.insecureURL }
        return url
    }

    public static func validFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0)) }
    }

    public static func validToken(_ value: String) -> Bool {
        (16...512).contains(value.utf8.count) && value.allSatisfy { $0.isASCII && !$0.isWhitespace && !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
    }
}
