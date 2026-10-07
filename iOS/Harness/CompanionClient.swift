import Foundation
import Security
import CryptoKit
import HarnessCore

/// A certificate-pinned client. Every request establishes TLS trust before the
/// one-time pairing token or a persistent bearer credential can leave the phone.
final class CompanionClient: ExternalToolExecutor, @unchecked Sendable {
    private let credentials: KeychainStore
    init(credentials: KeychainStore = .shared) { self.credentials = credentials }

    func pair(payload: String, deviceName: String) async throws -> PairedDevice {
        let pairing = try CompanionPairingPayload.parse(payload)
        let base = try CompanionPairingPayload.validateURL(pairing.url)
        let data = try await send(path: "pair", body: ["token": pairing.token, "deviceName": String(deviceName.prefix(80))],
                                  base: base, fingerprint: pairing.fingerprint, token: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["nodeId"] as? String, !id.isEmpty, id.utf8.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let name = json["name"] as? String, !name.isEmpty, name.utf8.count <= 256,
              let token = json["token"] as? String, CompanionPairingPayload.validToken(token),
              let credentialID = json["deviceId"] as? String, UUID(uuidString: credentialID) != nil,
              let rawCapabilities = json["capabilities"] as? [String] else { throw PairingFailure.invalidResponse }
        let mapping: [String: Capability] = ["readFile": .computerRead, "writeFile": .computerWrite, "execute": .computerExecute]
        guard rawCapabilities.allSatisfy({ mapping[$0] != nil }) else { throw PairingFailure.invalidResponse }
        let capabilities = Set(rawCapabilities.compactMap { mapping[$0] })
        try credentials.set(token, for: "companion:\(id)")
        return PairedDevice(id: id, name: name, url: pairing.url, fingerprint: pairing.fingerprint, capabilities: capabilities, credentialID: credentialID)
    }

    func removeCredentials(for deviceID: String) throws { try credentials.remove("companion:\(deviceID)") }

    func execute(_ call: ToolCall, device: PairedDevice) async throws -> String {
        let base = try CompanionPairingPayload.validateURL(device.url)
        guard CompanionPairingPayload.validFingerprint(device.fingerprint) else { throw PairingFailure.invalidFingerprint }
        let path: String
        let body: [String: Any]
        let capability: Capability
        switch call.name {
        case "computer_readFile":
            capability = .computerRead
            path = "tools/readFile"
            body = ["path": try Self.filePath(call.arguments["path"])]
        case "computer_writeFile":
            capability = .computerWrite
            path = "tools/writeFile"
            guard let content = call.arguments["content"]?.string, content.utf8.count <= 1024 * 1024 else { throw PairingFailure.invalidArguments }
            body = ["path": try Self.filePath(call.arguments["path"]), "content": content]
        case "computer_execute":
            capability = .computerExecute
            path = "tools/execute"
            guard case .array(let rawCommand) = call.arguments["command"], !rawCommand.isEmpty, rawCommand.count <= 128,
                  rawCommand.allSatisfy({ $0.string != nil }), let executable = rawCommand.first?.string, !executable.isEmpty else {
                throw PairingFailure.invalidArguments
            }
            let command = rawCommand.compactMap(\.string)
            guard command.allSatisfy({ $0.utf8.count <= 8192 && !$0.contains("\0") }) else { throw PairingFailure.invalidArguments }
            var request: [String: Any] = ["command": command]
            if let timeout = call.arguments["timeout"] {
                guard case .number(let seconds) = timeout, seconds.isFinite, (0.1...60).contains(seconds) else { throw PairingFailure.invalidArguments }
                request["timeout"] = seconds
            }
            body = request
        default: throw PairingFailure.unsupportedTool
        }
        guard device.capabilities.contains(capability) else { throw PairingFailure.capabilityDenied }
        guard let token = try credentials.token(for: "companion:\(device.id)"), CompanionPairingPayload.validToken(token) else { throw PairingFailure.missingCredential }
        let data = try await send(path: path, body: body, base: base, fingerprint: device.fingerprint, token: token)
        guard let text = String(data: data, encoding: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else { throw PairingFailure.invalidResponse }
        return text
    }

    private static func filePath(_ value: JSONValue?) throws -> String {
        guard let path = value?.string, !path.isEmpty, path.utf8.count <= 4096,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw PairingFailure.invalidArguments
        }
        return path
    }

    private func send(path: String, body: [String: Any], base: URL, fingerprint: String, token: String?) async throws -> Data {
        guard let host = base.host else { throw PairingFailure.insecureURL }
        let delegate = PinnedCompanionDelegate(host: host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), fingerprint: fingerprint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 70
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard (request.httpBody?.count ?? 0) <= 1024 * 1024 else { throw PairingFailure.invalidArguments }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled && !delegate.rejectedCertificate { throw CancellationError() }
        catch { throw delegate.rejectedCertificate ? PairingFailure.certificateMismatch : PairingFailure.network }
        guard let http = response as? HTTPURLResponse else { throw PairingFailure.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw PairingFailure.httpStatus(http.statusCode) }
        // A 1 MiB text file can expand to 6 MiB when JSON escapes Unicode/control characters.
        guard data.count <= 8 * 1024 * 1024 else { throw PairingFailure.invalidResponse }
        return data
    }
}

private final class PinnedCompanionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String
    private let fingerprint: String
    private let lock = NSLock()
    private var rejected = false
    var rejectedCertificate: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    init(host: String, fingerprint: String) { self.host = host; self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount == 0, challenge.protectionSpace.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else { reject(completionHandler); return }
        let bytes = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else { reject(completionHandler); return }
        // Trust only the exact pinned leaf while retaining hostname, validity-date,
        // and TLS-policy checks. This permits the companion's self-signed certificate.
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { reject(completionHandler); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func reject(_ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock(); rejected = true; lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
