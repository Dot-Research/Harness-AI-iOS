@_exported import Foundation


public struct NWPath {
    public enum Status { case satisfied, unsatisfied, requiresConnection }
    public var status: Status
}

public final class NWPathMonitor: @unchecked Sendable {
    public init() {}
    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public func start(queue: DispatchQueue) {}
    public func cancel() {}
}

