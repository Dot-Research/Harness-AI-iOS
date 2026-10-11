import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A speech-to-text endpoint that speaks the widely used OpenAI-compatible
/// `POST /v1/audio/transcriptions` multipart API. That covers OpenAI, Groq, and self-hosted
/// servers such as whisper.cpp's server and faster-whisper servers, which is also what the
/// Harness computer companion exposes over the pairing channel.
public struct TranscriptionEndpoint: Codable, Hashable, Sendable {
    public var name: String
    public var baseURL: URL
    public var model: String
    /// Keychain item holding the bearer token. The key itself never leaves the Keychain except to
    /// sign this one request.
    public var credentialID: String?

    public init(name: String, baseURL: URL, model: String, credentialID: String?) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.credentialID = credentialID
    }

    public var transcriptionsURL: URL {
        let trimmed = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        if trimmed.hasSuffix("/audio/transcriptions") { return URL(string: trimmed)! }
        if trimmed.hasSuffix("/v1") { return URL(string: trimmed + "/audio/transcriptions")! }
        return URL(string: trimmed + "/v1/audio/transcriptions")!
    }
}

public enum TranscriptionAPIError: Error, Equatable, Sendable {
    case audioTooLarge(bytes: Int)
    case insecureEndpoint
    case http(status: Int, message: String)
    case unreadableResponse
}

public enum TranscriptionAPI {
    /// The common upload limit for these APIs.
    public static let maxUploadBytes = 25 * 1024 * 1024

    public static func makeRequest(
        endpoint: TranscriptionEndpoint,
        wav: Data,
        languageCode: String?,
        vocabularyPrompt: String?,
        bearerToken: String?,
        boundary: String = "harness-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard wav.count <= maxUploadBytes else { throw TranscriptionAPIError.audioTooLarge(bytes: wav.count) }
        let url = endpoint.transcriptionsURL
        // Plain HTTP only for loopback/LAN development servers; anything public must be HTTPS.
        if url.scheme?.lowercased() != "https" && !isLocalHost(url.host) {
            throw TranscriptionAPIError.insecureEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        var form = MultipartForm(boundary: boundary)
        form.addField(name: "model", value: endpoint.model)
        form.addField(name: "response_format", value: "json")
        form.addField(name: "temperature", value: "0")
        if let languageCode, let primary = languageCode.split(separator: "-").first, !primary.isEmpty {
            form.addField(name: "language", value: String(primary).lowercased())
        }
        if let vocabularyPrompt, !vocabularyPrompt.isEmpty {
            form.addField(name: "prompt", value: String(vocabularyPrompt.prefix(800)))
        }
        form.addFile(name: "file", filename: "dictation.wav", mimeType: "audio/wav", data: wav)
        request.httpBody = form.finalized()
        return request
    }

    public static func parse(data: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else {
            let message = errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw TranscriptionAPIError.http(status: statusCode, message: message)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["text"] as? String {
            return text
        }
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.hasPrefix("{") {
            return text
        }
        throw TranscriptionAPIError.unreadableResponse
    }

    /// Dictionary terms as a hint prompt, which Whisper-family models use to bias spelling.
    public static func vocabularyPrompt(from dictionary: PersonalDictionary) -> String? {
        let terms = dictionary.contextualStrings
        guard !terms.isEmpty else { return nil }
        return "Vocabulary: " + terms.joined(separator: ", ") + "."
    }

    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["error"] as? String { return message }
        if let message = object["message"] as? String { return message }
        return nil
    }

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 100 && (64...127).contains(parts[1]) { return true } // Tailscale CGNAT range
        return false
    }
}

struct MultipartForm {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }
}
