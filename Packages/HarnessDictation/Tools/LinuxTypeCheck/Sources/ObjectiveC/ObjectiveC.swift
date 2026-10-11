// Interfaces of the Objective-C runtime that Linux lacks. Shapes follow the Apple SDK.
public struct Selector: Hashable, Sendable {
    public init(_ name: String) {}
}
public func NSSelectorFromString(_ name: String) -> Selector { Selector(name) }
public typealias Method = OpaquePointer
public typealias IMP = OpaquePointer
public func class_getInstanceMethod(_ cls: AnyClass?, _ name: Selector) -> Method? { nil }
public func method_getImplementation(_ m: Method) -> IMP { fatalError() }
/// Stands in for `#selector(...)`: the argument is a real method reference, so its name is still checked.
public func _selector<T>(_ method: T) -> Selector { Selector("") }
