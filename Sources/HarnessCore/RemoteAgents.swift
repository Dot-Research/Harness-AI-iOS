import Foundation

public enum RemoteAgentRuntime: String, Codable, CaseIterable, Sendable {
    case pi = "pi-coding-agent"
    case claudeCode = "Claude Code"
    case hermes = "Hermes Agent"

    public var executable: String {
        switch self { case .pi: "pi"; case .claudeCode: "claude"; case .hermes: "hermes" }
    }

    public func arguments(task: String) -> [String] {
        switch self {
        case .pi: ["--print", "--mode", "text", "--", task]
        case .claudeCode: ["--print", "--output-format", "text", "--", task]
        case .hermes: ["chat", "--oneshot", "--query", task]
        }
    }
}

/// A user-created route. Credentials and SSH keys remain on the paired computer.
public struct RemoteAgentConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var deviceID: String
    public var runtime: RemoteAgentRuntime
    public var executable: String
    public var sshAlias: String?
    public var workingDirectory: String?
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, deviceID: String, runtime: RemoteAgentRuntime,
                executable: String? = nil, sshAlias: String? = nil, workingDirectory: String? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.deviceID = deviceID; self.runtime = runtime
        self.executable = executable ?? runtime.executable; self.sshAlias = sshAlias
        self.workingDirectory = workingDirectory; self.enabled = enabled
    }
    public var routeDescription: String { sshAlias.map { "SSH · \($0)" } ?? "On paired computer" }
}

public struct RemoteAgentExecutionPlan: Equatable, Sendable {
    public let connection: RemoteAgentConnection
    public let device: PairedDevice
    public let task: String
    public let command: [String]

    public init(connection: RemoteAgentConnection, device: PairedDevice, task: String) throws {
        guard connection.enabled, connection.deviceID == device.id, device.capabilities.contains(.computerExecute) else {
            throw RuntimeError.deviceUnavailable(connection.deviceID)
        }
        guard !connection.name.isEmpty, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.utf8.count <= 6_000, !task.contains("\0") else {
            throw RuntimeError.invalidArguments("Task must contain between 1 and 6,000 UTF-8 bytes without NUL characters.")
        }
        let executable = connection.executable
        guard !executable.isEmpty, executable.utf8.count <= 512,
              !executable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              executable == connection.runtime.executable || executable.hasPrefix("/") else {
            throw RuntimeError.invalidArguments("Use the runtime's executable name or its absolute installed path.")
        }
        if let directory = connection.workingDirectory {
            guard directory.hasPrefix("/"), directory.utf8.count <= 1_024,
                  !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RuntimeError.invalidArguments("Working directory must be an absolute path without control characters.")
            }
        }
        let arguments = [executable] + connection.runtime.arguments(task: task)
        var script = arguments.map(Self.shellQuote).joined(separator: " ")
        if let directory = connection.workingDirectory { script = "cd \(Self.shellQuote(directory)) && exec " + script }
        else { script = "exec " + script }
        if let alias = connection.sshAlias {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard !alias.isEmpty, alias.utf8.count <= 128, alias.first != "-",
                  alias.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw RuntimeError.invalidArguments("SSH route must be a saved host alias using letters, digits, dots, underscores or hyphens.")
            }
            // SSH interprets its remote command with a shell; quote every literal argument.
            self.command = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "--", alias, script]
        } else if connection.workingDirectory != nil {
            // This shell is explicit and its complete, quoted script appears in the permission prompt.
            self.command = ["/bin/sh", "-c", script]
        } else { self.command = arguments }
        guard command.allSatisfy({ $0.utf8.count <= 8_192 }) else {
            throw RuntimeError.invalidArguments("The escaped command exceeds the companion's argument limit. Shorten the task.")
        }
        self.connection = connection; self.device = device; self.task = task
    }

    public var permissionDetail: String {
        "Agent: \(connection.name) (\(connection.runtime.rawValue))\nComputer: \(device.name)\nRoute: \(connection.routeDescription)\nTask: \(task)\nCommand: \(command.map(Self.shellQuote).joined(separator: " "))\nThe external agent uses its own installed permissions and tools. The companion runs this job for up to 30 minutes. Results remain available for one hour while the companion stays running; stopping it ends its jobs. Cancelling this task requests cancellation of this job and its descendants."
    }

    public func toolCall(id: String, jobID: UUID = UUID()) -> ToolCall {
        ToolCall(id: id, name: "remote_agent_execute", arguments: ["deviceID": .string(device.id), "jobID": .string(jobID.uuidString.lowercased()), "command": .array(command.map(JSONValue.string)), "timeout": .number(1800)])
    }
    private static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public enum RemoteAgentJobOperation: String, Sendable {
    case start, status, cancel
    public var path: String { "tools/jobs/" + rawValue }
}

/// The UUID is created before networking and reused for every retry and cancellation.
public struct RemoteAgentJobRequest: Sendable {
    public let jobID: UUID
    public let command: [String]
    public let timeout: Double

    public init(call: ToolCall) throws {
        guard call.name == "remote_agent_execute", let rawID = call.arguments["jobID"]?.string,
              rawID.count == 36, let jobID = UUID(uuidString: rawID),
              case .array(let values) = call.arguments["command"], !values.isEmpty, values.count <= 128,
              values.allSatisfy({ $0.string != nil }), let executable = values.first?.string, !executable.isEmpty,
              case .number(let timeout) = call.arguments["timeout"], timeout.isFinite, (0.1...1800).contains(timeout) else {
            throw PairingFailure.invalidArguments
        }
        let command = values.compactMap(\.string)
        guard command.allSatisfy({ $0.utf8.count <= 8192 && !$0.contains("\0") }) else { throw PairingFailure.invalidArguments }
        self.jobID = jobID; self.command = command; self.timeout = timeout
    }

    public func body(for operation: RemoteAgentJobOperation) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["jobID": .string(jobID.uuidString.lowercased())]
        if operation == .start {
            body["command"] = .array(command.map(JSONValue.string)); body["timeout"] = .number(timeout)
        }
        return body
    }
}

public struct RemoteAgentJobSnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, completed, failed, cancelled }
    public struct Result: Codable, Equatable, Sendable {
        public let exitCode: Int
        public let stdout: String
        public let stderr: String
        public let truncated: Bool
        public let timedOut: Bool
    }
    public let jobID: String
    public let state: State
    public let result: Result?
    public var hasFinalResult: Bool { result != nil && [.completed, .failed, .cancelled].contains(state) }

    public static func parse(_ data: Data, expectedJobID: UUID) throws -> Self {
        // Replacement decoding can turn 64 KiB of invalid UTF-8 into 192 KiB of text per pipe.
        guard data.count <= 2 * 1024 * 1024, let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.jobID.count == 36, UUID(uuidString: snapshot.jobID) == expectedJobID else { throw PairingFailure.invalidResponse }
        if let result = snapshot.result {
            guard Int32(exactly: result.exitCode) != nil, result.stdout.utf8.count <= 3 * 64 * 1024,
                  result.stderr.utf8.count <= 3 * 64 * 1024 else { throw PairingFailure.invalidResponse }
        }
        switch snapshot.state {
        case .queued, .running:
            guard snapshot.result == nil else { throw PairingFailure.invalidResponse }
        case .completed:
            guard let result = snapshot.result, result.exitCode == 0, !result.timedOut else { throw PairingFailure.invalidResponse }
        case .failed:
            guard let result = snapshot.result, result.exitCode != 0 || result.timedOut else { throw PairingFailure.invalidResponse }
        case .cancelled:
            guard snapshot.result?.timedOut != true else { throw PairingFailure.invalidResponse }
        }
        return snapshot
    }
}

/// A portable job driver; the iOS transport still performs certificate pinning on every request.
public enum RemoteAgentJobRunner {
    public typealias Transport = @Sendable (RemoteAgentJobOperation, [String: JSONValue]) async throws -> Data

    public static func run(request: RemoteAgentJobRequest, pollInterval: Duration = .seconds(1), transport: @escaping Transport) async -> String {
        let cancellation = JobCancellation(request: request, transport: transport)
        return await withTaskCancellationHandler(operation: {
            var snapshot: RemoteAgentJobSnapshot?
            let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(request.timeout)
            do {
                try Task.checkCancellation()
                for attempt in 0..<3 {
                    do {
                        snapshot = try await fetch(.start, request: request, transport: transport)
                        try Task.checkCancellation()
                        break
                    } catch {
                        try Task.checkCancellation()
                        guard retryable(error) else { throw error }
                        if attempt == 2 {
                            // A lost start response can still mean the companion accepted it.
                            // Query the existing handle; a status failure never creates a new job.
                            snapshot = try await fetch(.status, request: request, transport: transport)
                        } else {
                            guard clock.now < deadline else { throw error }
                            try await clock.sleep(until: min(clock.now + max(pollInterval, .milliseconds(1)), deadline))
                        }
                    }
                }
                var consecutiveFailures = 0
                while snapshot?.hasFinalResult != true {
                    try Task.checkCancellation()
                    guard clock.now < deadline else {
                        return describe(request: request, snapshot: snapshot, note: "The phone's wait limit was reached. This is the last confirmed server status; the job may still be running. Its configured command timeout is \(request.timeout) seconds. Reconnect with this jobID to retrieve its result. No new job was started.")
                    }
                    try await clock.sleep(until: min(clock.now + max(pollInterval, .milliseconds(1)), deadline))
                    // Fetch once at the deadline so a server timeout can publish its actual result.
                    do {
                        snapshot = try await fetch(.status, request: request, transport: transport)
                        consecutiveFailures = 0
                    } catch {
                        try Task.checkCancellation()
                        consecutiveFailures += 1
                        guard retryable(error), consecutiveFailures < 3 else { throw error }
                    }
                }
                try Task.checkCancellation()
                return describe(request: request, snapshot: snapshot)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    let outcome = await cancellation.begin().value
                    return describe(request: request, snapshot: outcome.snapshot ?? snapshot, note: outcome.note)
                }
                return describe(request: request, snapshot: snapshot, note: "The companion could not confirm further progress: \(error.localizedDescription) This is the last confirmed server status; the job may still be running. Preserve this jobID for a status request. No new job was started. Jobs expire one hour after finishing and end when the companion stops.")
            }
        }, onCancel: { _ = cancellation.begin() })
    }

    fileprivate static func fetch(_ operation: RemoteAgentJobOperation, request: RemoteAgentJobRequest, transport: Transport) async throws -> RemoteAgentJobSnapshot {
        try RemoteAgentJobSnapshot.parse(await transport(operation, request.body(for: operation)), expectedJobID: request.jobID)
    }

    private static func retryable(_ error: Error) -> Bool {
        guard let error = error as? PairingFailure else { return false }
        switch error {
        case .network: return true
        case .httpStatus(let code): return [502, 503, 504].contains(code)
        default: return false
        }
    }

    private static func describe(request: RemoteAgentJobRequest, snapshot: RemoteAgentJobSnapshot?, note: String? = nil) -> String {
        var text = "Remote agent job: " + request.jobID.uuidString.lowercased()
        if let snapshot {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(snapshot), let json = String(data: data, encoding: .utf8) { text += "\n" + json }
        } else { text += "\nNo confirmed server status is available." }
        if let note { text += "\n" + note }
        return text
    }
}

private final class JobCancellation: @unchecked Sendable {
    struct Outcome: Sendable { let snapshot: RemoteAgentJobSnapshot?; let note: String }
    private let request: RemoteAgentJobRequest
    private let transport: RemoteAgentJobRunner.Transport
    private let lock = NSLock()
    private var task: Task<Outcome, Never>?
    init(request: RemoteAgentJobRequest, transport: @escaping RemoteAgentJobRunner.Transport) { self.request = request; self.transport = transport }

    /// Called synchronously from onCancel, even when start's URLSession request is still pending.
    /// The detached task has a fresh cancellation context and addresses only this handle.
    func begin() -> Task<Outcome, Never> {
        lock.lock(); defer { lock.unlock() }
        if let task { return task }
        let request = request, transport = transport
        let task = Task.detached { () -> Outcome in
            var snapshot: RemoteAgentJobSnapshot?
            do {
                snapshot = try await RemoteAgentJobRunner.fetch(.cancel, request: request, transport: transport)
                for _ in 0..<4 where snapshot?.state == .cancelled && snapshot?.result == nil {
                    try await Task.sleep(for: .milliseconds(125))
                    snapshot = try await RemoteAgentJobRunner.fetch(.status, request: request, transport: transport)
                }
                let note: String
                if snapshot?.state == .cancelled {
                    note = "The companion confirmed cancellation of this job.\(snapshot?.result == nil ? " Captured output is still being collected; query this jobID for the final result." : "")"
                } else if snapshot?.hasFinalResult == true {
                    note = "The companion returned this job's result before cancellation took effect."
                } else {
                    note = "The phone requested cancellation, but the companion could not confirm cancellation. This job may still be running. Query or cancel this same jobID after reconnecting."
                }
                return Outcome(snapshot: snapshot, note: note)
            } catch {
                let note = snapshot?.state == .cancelled ?
                    "The companion confirmed cancellation; its final output could not be refreshed: \(error.localizedDescription) Query this jobID for the retained result." :
                    "The phone requested cancellation, but the companion could not confirm cancellation: \(error.localizedDescription) This job may still be running. Query or cancel this same jobID after reconnecting."
                return Outcome(snapshot: snapshot, note: note)
            }
        }
        self.task = task
        return task
    }
}
