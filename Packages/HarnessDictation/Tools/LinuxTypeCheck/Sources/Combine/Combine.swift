@_exported import Foundation


public protocol ObservableObject: AnyObject {}

public final class AnyCancellable: Hashable {
    public init() {}
    public static func == (a: AnyCancellable, b: AnyCancellable) -> Bool { a === b }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }
}

public final class PublishedBox<Value> {
    public var value: Value
    init(_ value: Value) { self.value = value }
}

public struct PublishedPublisher<Value> {
    let box: PublishedBox<Value>
    public func sink(receiveValue: @escaping (Value) -> Void) -> AnyCancellable { AnyCancellable() }
}

@propertyWrapper
public struct Published<Value> {
    private let box: PublishedBox<Value>
    public init(wrappedValue: Value) { box = PublishedBox(wrappedValue) }
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: PublishedPublisher<Value> { PublishedPublisher(box: box) }
}


public protocol Publisher {
    associatedtype Output
    associatedtype Failure: Error
}

extension NotificationCenter {
    public struct Publisher: Combine.Publisher {
        public typealias Output = Notification
        public typealias Failure = Never
    }
    public func publisher(for name: Notification.Name, object: AnyObject? = nil) -> NotificationCenter.Publisher { Publisher() }
}
