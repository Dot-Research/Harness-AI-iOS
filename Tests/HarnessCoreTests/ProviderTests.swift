import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HarnessCore

final class ProviderTests: XCTestCase {
    func testOnlyHTTPSOrLiteralLoopbackHTTPModelEndpointsAreAllowed() throws {
        for address in ["https://openrouter.ai/api/v1", "https://api.openai.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1"] {
            XCTAssertNoThrow(try OpenAICompatibleProvider.validateEndpoint(address), address)
        }
        for address in ["http://192.168.1.8:11434/v1", "http://models.example/v1", "ftp://localhost/v1", "https://user:secret@api.example/v1", "https://api.example/v1?key=secret", "https://api.example/v1#secret", "https://api.example:70000/v1", "http://localhost.evil.example/v1", "http://127.1/v1"] {
            XCTAssertThrowsError(try OpenAICompatibleProvider.validateEndpoint(address), address)
        }
    }

    func testSerializesConversationAndParsesMultipleToolCalls() async throws {
        let capture = RequestCapture()
        ModelURLProtocol.configure { request in
            capture.set(request)
            return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"read_1","type":"function","function":{"name":"local_readFile","arguments":"{\"path\":\"MEMORY.md\"}"}},{"id":"read_2","type":"function","function":{"name":"local_readFile","arguments":"{\"path\":\"USER.md\"}"}}]}}],"usage":{"prompt_tokens":11,"completion_tokens":7}}"#.utf8))
        }
        let provider = try makeProvider()
        let previous = ToolCall(id: "previous", name: "local_readFile", arguments: ["path": .string("SOUL.md")])
        let response = try await provider.complete(ModelRequest(messages: [
            AgentMessage(role: .system, content: "Use consent."),
            AgentMessage(role: .user, content: "Read my files."),
            AgentMessage(role: .assistant, content: "", toolCalls: [previous]),
            AgentMessage(role: .tool, content: "My instructions", toolCallID: "previous")
        ], tools: [ToolDefinition(name: "local_readFile", description: "Read workspace", capability: .localRead,
                                 parameters: ["type": .string("object"), "properties": .object(["path": .object(["type": .string("string")])])])]))
        XCTAssertEqual(response.content, "")
        XCTAssertEqual(response.toolCalls.map(\.id), ["read_1", "read_2"])
        XCTAssertEqual(response.toolCalls.map { $0.arguments["path"]?.string }, ["MEMORY.md", "USER.md"])
        XCTAssertEqual(response.inputTokens, 11)
        XCTAssertEqual(response.outputTokens, 7)
        let request = try XCTUnwrap(capture.get())
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-not-a-secret")
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: try bodyData(request)) as? [String: Any])
        XCTAssertEqual(encoded["model"] as? String, "test-model")
        XCTAssertEqual(encoded["stream"] as? Bool, false)
        let messages = try XCTUnwrap(encoded["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "previous")
        let calls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        let arguments = try XCTUnwrap(function["arguments"] as? String)
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: Data(arguments.utf8)), previous.arguments)
        XCTAssertEqual((encoded["tools"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(encoded["credential"])
    }

    func testLoopbackProviderCanRunWithoutCloudCredentialAndOmitsEmptyTools() async throws {
        let capture = RequestCapture()
        ModelURLProtocol.configure { request in
            capture.set(request)
            return (200, Data(#"{"choices":[{"message":{"content":"Local answer"}}]}"#.utf8))
        }
        let provider = try makeProvider(endpoint: "http://127.0.0.1:11434/v1", credential: { nil })
        XCTAssertTrue(provider.isLocal)
        let response = try await provider.complete(ModelRequest(messages: [AgentMessage(role: .user, content: "Hi")], model: "local-model"))
        XCTAssertEqual(response.content, "Local answer")
        let request = try XCTUnwrap(capture.get())
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: try bodyData(request)) as? [String: Any])
        XCTAssertEqual(encoded["model"] as? String, "local-model")
        XCTAssertNil(encoded["tools"])
        XCTAssertNil(encoded["tool_choice"])
    }

    func testHTTPErrorNeverReturnsRawServerErrorOrCredentials() async throws {
        ModelURLProtocol.configure { _ in
            (401, Data(#"{"error":{"message":"test-key-not-a-secret and private conversation echoed by server"}}"#.utf8))
        }
        do {
            _ = try await makeProvider().complete(ModelRequest(messages: [AgentMessage(role: .user, content: "Private conversation")]))
            XCTFail("Expected status rejection")
        } catch {
            XCTAssertEqual(error as? ProviderFailure, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("test-key-not-a-secret"))
            XCTAssertFalse(error.localizedDescription.contains("private conversation"))
        }
    }

    func testNetworkErrorAndCredentialErrorsAreRedacted() async throws {
        ModelURLProtocol.configure { _ in throw NSError(domain: "contains private data", code: 1, userInfo: [NSLocalizedDescriptionKey: "server echoed secret"]) }
        do {
            _ = try await makeProvider().complete(ModelRequest(messages: []))
            XCTFail("Expected network failure")
        } catch { XCTAssertEqual(error as? ProviderFailure, .network) }
        let provider = try makeProvider(credential: { throw NSError(domain: "keychain private", code: 1) })
        do {
            _ = try await provider.complete(ModelRequest(messages: []))
            XCTFail("Expected credential failure")
        } catch { XCTAssertEqual(error as? ProviderFailure, .missingCredential) }
    }

    func testMalformedToolArgumentsAndDuplicateIDsRejectResponse() async throws {
        for payload in [
            #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"x","type":"function","function":{"name":"read","arguments":"not json"}}]}}]}"#,
            #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"x","type":"function","function":{"name":"read","arguments":"[]"}}]}}]}"#,
            #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"x","type":"function","function":{"name":"read","arguments":"{}"}},{"id":"x","type":"function","function":{"name":"write","arguments":"{}"}}]}}]}"#
        ] {
            ModelURLProtocol.configure { _ in (200, Data(payload.utf8)) }
            do {
                _ = try await makeProvider().complete(ModelRequest(messages: []))
                XCTFail("Expected malformed tool rejection")
            } catch { XCTAssertEqual(error as? ProviderFailure, .invalidToolArguments) }
        }
    }

    func testRemoteCredentialAndToolReplyIDAreRequiredBeforeSending() async throws {
        let capture = RequestCapture()
        ModelURLProtocol.configure { request in capture.set(request); return (200, Data()) }
        let noCredential = try makeProvider(credential: { nil })
        do { _ = try await noCredential.complete(ModelRequest(messages: [])); XCTFail("Expected missing credential") }
        catch { XCTAssertEqual(error as? ProviderFailure, .missingCredential) }
        XCTAssertNil(capture.get())
        do { _ = try await makeProvider().complete(ModelRequest(messages: [AgentMessage(role: .tool, content: "result")])); XCTFail("Expected missing call ID") }
        catch { XCTAssertEqual(error as? ProviderFailure, .invalidRequest) }
        XCTAssertNil(capture.get())
    }

    func testPairingAcceptsOnlyUnexpiredPinnedHTTPSPayload() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiration = ISO8601DateFormatter().string(from: now.addingTimeInterval(120))
        let valid = try pairingJSON(expiration: expiration)
        XCTAssertEqual(try CompanionPairingPayload.parse(valid, now: now).version, 1)
        XCTAssertThrowsError(try CompanionPairingPayload.parse(try pairingJSON(url: "http://192.168.1.2:8443", expiration: expiration), now: now)) {
            XCTAssertEqual($0 as? PairingFailure, .insecureURL)
        }
        XCTAssertThrowsError(try CompanionPairingPayload.parse(try pairingJSON(fingerprint: String(repeating: "A", count: 64), expiration: expiration), now: now)) {
            XCTAssertEqual($0 as? PairingFailure, .invalidFingerprint)
        }
        XCTAssertThrowsError(try CompanionPairingPayload.parse(try pairingJSON(expiration: ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))), now: now)) {
            XCTAssertEqual($0 as? PairingFailure, .expired)
        }
        XCTAssertThrowsError(try CompanionPairingPayload.parse(try pairingJSON(token: "short", expiration: expiration), now: now))
        XCTAssertThrowsError(try CompanionPairingPayload.parse(try pairingJSON(url: "https://user:password@computer:8443", expiration: expiration), now: now))
        XCTAssertThrowsError(try CompanionPairingPayload.parse(try pairingJSON(url: "https://computer:8443/pair", expiration: expiration), now: now))
        XCTAssertThrowsError(try CompanionPairingPayload.parse("https://example.com", now: now))
    }

    private func makeProvider(endpoint: String = "https://openrouter.ai/api/v1", credential: @escaping @Sendable () async throws -> String? = { "test-key-not-a-secret" }) throws -> OpenAICompatibleProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelURLProtocol.self]
        return try OpenAICompatibleProvider(configuration: ProviderConfiguration(id: "test", name: "Test", kind: .openRouter, endpoint: endpoint, model: "test-model"), credential: credential, session: URLSession(configuration: configuration))
    }

    private func bodyData(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw ProviderFailure.invalidRequest }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw ProviderFailure.invalidRequest }
            if read == 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func pairingJSON(url: String = "https://192.168.1.2:8443", token: String = "single-use-test-pairing-token", fingerprint: String = String(repeating: "a", count: 64), expiration: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "url": url, "token": token, "fingerprint": fingerprint, "expiresAt": expiration])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    func set(_ value: URLRequest) { lock.lock(); defer { lock.unlock() }; request = value }
    func get() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return request }
}

private final class ModelURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var handler: Handler?
    static func configure(_ value: @escaping Handler) { lock.lock(); defer { lock.unlock() }; handler = value }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            let (status, data) = try XCTUnwrap(handler)(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
