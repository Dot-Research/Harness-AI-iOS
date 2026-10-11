// A type-checking stand-in for SwiftUI (iOS 26 SDK shapes) covering what the Harness dictation UI uses.
// Bodies are never run. Signatures follow Apple's declarations closely enough that wrong member names,
// argument labels, binding types, result-builder misuse and actor-isolation errors are caught.
@_exported import Foundation
@_exported import Combine
import UIKit

// MARK: - Core protocols

@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

/// A leaf view with no body.
public protocol _Leaf: View where Body == Never {}
extension _Leaf { public var body: Never { fatalError() } }

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

public protocol DynamicProperty {}

@resultBuilder
public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<(repeat each Content)> { TupleView() }
    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { _ConditionalContent() }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

public struct TupleView<T>: _Leaf { init() {} }
public struct _ConditionalContent<T: View, F: View>: _Leaf { init() {} }
public struct EmptyView: _Leaf { public init() {} }
public struct AnyView: _Leaf { public init<V: View>(_ view: V) {} }
extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

/// What every modifier returns.
public struct _Modified<Content>: _Leaf { init() {} }

// MARK: - App and scenes

@MainActor @preconcurrency
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
    init()
}
extension App { public static func main() {} }

@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder var body: Body { get }
}

@resultBuilder
public struct SceneBuilder {
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content { content }
}

public struct WindowGroup<Content: View>: Scene {
    public var body: WindowGroup<Content> { self }
    public init(@ViewBuilder content: () -> Content) {}
}

// MARK: - Property wrappers

@propertyWrapper
public struct State<Value>: DynamicProperty {
    public init(wrappedValue value: Value) {}
    public init(initialValue value: Value) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
}
extension State where Value: ExpressibleByNilLiteral {
    public init() {}
}

@propertyWrapper @dynamicMemberLookup
public struct Binding<Value> {
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {}
    public static func constant(_ value: Value) -> Binding<Value> { fatalError() }
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { self }
    public subscript<Subject>(dynamicMember keyPath: WritableKeyPath<Value, Subject>) -> Binding<Subject> { fatalError() }
}

@propertyWrapper
public struct ObservedObject<ObjectType: ObservableObject>: DynamicProperty {
    @dynamicMemberLookup
    public struct Wrapper {
        public subscript<Subject>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, Subject>) -> Binding<Subject> { fatalError() }
    }
    public init(wrappedValue: ObjectType) {}
    public init(initialValue: ObjectType) {}
    public var wrappedValue: ObjectType { get { fatalError() } set {} }
    public var projectedValue: ObservedObject<ObjectType>.Wrapper { fatalError() }
}

@propertyWrapper
public struct StateObject<ObjectType: ObservableObject>: DynamicProperty {
    public init(wrappedValue thunk: @autoclosure @escaping () -> ObjectType) {}
    @MainActor public var wrappedValue: ObjectType { fatalError() }
    @MainActor public var projectedValue: ObservedObject<ObjectType>.Wrapper { fatalError() }
}

@propertyWrapper
public struct Environment<Value>: DynamicProperty {
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    @MainActor public var wrappedValue: Value { fatalError() }
}

@propertyWrapper
public struct GestureState<Value>: DynamicProperty {
    public init(wrappedValue: Value) {}
    public init(initialValue: Value) {}
    public var wrappedValue: Value { fatalError() }
    public var projectedValue: GestureState<Value> { self }
}

public struct EnvironmentValues {
    public var colorScheme: ColorScheme { fatalError() }
    public var isEnabled: Bool { fatalError() }
    public var scenePhase: ScenePhase { fatalError() }
    public var dismiss: DismissAction { fatalError() }
    public var openURL: OpenURLAction { fatalError() }
}

public struct DismissAction { @MainActor public func callAsFunction() {} }
public struct OpenURLAction { @MainActor public func callAsFunction(_ url: URL) {} }
public enum ColorScheme: Hashable, Sendable { case light, dark }
public enum ScenePhase: Hashable, Sendable { case background, inactive, active }

// MARK: - Values

public struct LocalizedStringKey: Equatable, ExpressibleByStringInterpolation {
    public init(_ value: String) {}
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: DefaultStringInterpolation) {}
}

public protocol ShapeStyle {}

public struct Color: ShapeStyle, _Leaf, Hashable, Sendable {
    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {}
    public init(white: Double, opacity: Double = 1) {}
    public init(_ color: UIColor) {}
    public init(uiColor: UIColor) {}
    public func opacity(_ opacity: Double) -> Color { self }
    public static let red = Color(white: 0), green = Color(white: 0), blue = Color(white: 0), orange = Color(white: 0)
    public static let black = Color(white: 0), white = Color(white: 1), gray = Color(white: 0.5), clear = Color(white: 0)
    public static let primary = Color(white: 0), secondary = Color(white: 0), accentColor = Color(white: 0)
}
extension ShapeStyle where Self == Color {
    public static var red: Color { .red }
    public static var green: Color { .green }
    public static var blue: Color { .blue }
    public static var orange: Color { .orange }
    public static var black: Color { .black }
    public static var white: Color { .white }
    public static var gray: Color { .gray }
    public static var clear: Color { .clear }
}
public struct HierarchicalShapeStyle: ShapeStyle {
    public static let primary = HierarchicalShapeStyle(), secondary = HierarchicalShapeStyle(), tertiary = HierarchicalShapeStyle()
}
extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { .primary }
    public static var secondary: HierarchicalShapeStyle { .secondary }
    public static var tertiary: HierarchicalShapeStyle { .tertiary }
}
public struct TintShapeStyle: ShapeStyle {}
extension ShapeStyle where Self == TintShapeStyle {
    public static var tint: TintShapeStyle { TintShapeStyle() }
}

public struct Font: Hashable, Sendable {
    public struct Weight: Hashable, Sendable {
        public static let ultraLight = Weight(), thin = Weight(), light = Weight(), regular = Weight(), medium = Weight()
        public static let semibold = Weight(), bold = Weight(), heavy = Weight(), black = Weight()
    }
    public enum Design: Hashable, Sendable { case `default`, serif, rounded, monospaced }
    public static let largeTitle = Font(), title = Font(), title2 = Font(), title3 = Font(), headline = Font()
    public static let subheadline = Font(), body = Font(), callout = Font(), footnote = Font(), caption = Font(), caption2 = Font()
    public static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font { Font() }
    public func weight(_ weight: Font.Weight) -> Font { self }
    public func monospacedDigit() -> Font { self }
}

public struct HorizontalAlignment: Equatable, Sendable {
    public static let leading = HorizontalAlignment(), center = HorizontalAlignment(), trailing = HorizontalAlignment()
}
public struct VerticalAlignment: Equatable, Sendable {
    public static let top = VerticalAlignment(), center = VerticalAlignment(), bottom = VerticalAlignment()
    public static let firstTextBaseline = VerticalAlignment(), lastTextBaseline = VerticalAlignment()
}
public struct Alignment: Equatable, Sendable {
    public static let center = Alignment(), leading = Alignment(), trailing = Alignment(), top = Alignment(), bottom = Alignment()
    public static let topLeading = Alignment(), topTrailing = Alignment(), bottomLeading = Alignment(), bottomTrailing = Alignment()
}
public enum TextAlignment: Hashable, Sendable { case leading, center, trailing }
public enum Edge: Int8, Hashable, Sendable {
    case top, leading, bottom, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), leading = Set(rawValue: 2), bottom = Set(rawValue: 4), trailing = Set(rawValue: 8)
        public static let horizontal: Set = [.leading, .trailing], vertical: Set = [.top, .bottom], all: Set = [.top, .leading, .bottom, .trailing]
    }
}
public enum Axis: Int8, Hashable, Sendable {
    case horizontal, vertical
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1), vertical = Set(rawValue: 2)
    }
}
public enum Visibility: Hashable, Sendable { case automatic, visible, hidden }
public struct ButtonRole: Equatable, Sendable {
    public static let destructive = ButtonRole(), cancel = ButtonRole()
}
public struct AccessibilityTraits: SetAlgebra, Sendable {
    public init() {}
    public static let isButton = AccessibilityTraits(), isHeader = AccessibilityTraits(), updatesFrequently = AccessibilityTraits(), isSelected = AccessibilityTraits()
    public func contains(_ member: AccessibilityTraits) -> Bool { false }
    public func union(_ other: AccessibilityTraits) -> AccessibilityTraits { self }
    public func intersection(_ other: AccessibilityTraits) -> AccessibilityTraits { self }
    public func symmetricDifference(_ other: AccessibilityTraits) -> AccessibilityTraits { self }
    public mutating func insert(_ newMember: AccessibilityTraits) -> (inserted: Bool, memberAfterInsert: AccessibilityTraits) { (false, self) }
    public mutating func remove(_ member: AccessibilityTraits) -> AccessibilityTraits? { nil }
    public mutating func update(with newMember: AccessibilityTraits) -> AccessibilityTraits? { nil }
    public mutating func formUnion(_ other: AccessibilityTraits) {}
    public mutating func formIntersection(_ other: AccessibilityTraits) {}
    public mutating func formSymmetricDifference(_ other: AccessibilityTraits) {}
    public static func == (a: AccessibilityTraits, b: AccessibilityTraits) -> Bool { true }
}
public struct Animation: Equatable, Sendable {
    public static let `default` = Animation()
    public static func easeOut(duration: TimeInterval) -> Animation { Animation() }
    public static func easeInOut(duration: TimeInterval) -> Animation { Animation() }
}
public struct AnyTransition: Sendable {
    public static let opacity = AnyTransition()
}
public struct Transaction {}
public struct TextInputAutocapitalization: Sendable {
    public static let never = TextInputAutocapitalization(), words = TextInputAutocapitalization()
    public static let sentences = TextInputAutocapitalization(), characters = TextInputAutocapitalization()
}
public protocol TextSelectability {}
public struct EnabledTextSelectability: TextSelectability {}
extension TextSelectability where Self == EnabledTextSelectability {
    public static var enabled: EnabledTextSelectability { EnabledTextSelectability() }
}

// MARK: - Views

public struct Text: _Leaf, Equatable {
    public enum TruncationMode: Hashable, Sendable { case head, tail, middle }
    public init(_ key: LocalizedStringKey) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) {}
    public init(verbatim content: String) {}
}

public struct Image: _Leaf, Equatable {
    public init(systemName: String) {}
    public init(_ name: String) {}
}

public struct Label<Title: View, Icon: View>: _Leaf {
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {}
}
extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, systemImage name: String) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String) {}
}

public struct Button<Label: View>: _Leaf {
    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
    public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {}
}
extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {}
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void) {}
}

public struct EditButton: _Leaf { public init() {} }

public struct VStack<Content: View>: _Leaf {
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}
public struct HStack<Content: View>: _Leaf {
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}
public struct ZStack<Content: View>: _Leaf {
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {}
}
public struct Group<Content: View>: _Leaf {
    public init(@ViewBuilder content: () -> Content) {}
}
public struct Spacer: _Leaf { public init(minLength: CGFloat? = nil) {} }
public struct Divider: _Leaf { public init() {} }

public struct ScrollView<Content: View>: _Leaf {
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {}
}

public struct GridItem: Sendable {
    public enum Size: Sendable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
    public init(_ size: GridItem.Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {}
}
public struct LazyVGrid<Content: View>: _Leaf {
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {}
}

public struct List<Content: View>: _Leaf {
    public init(@ViewBuilder content: () -> Content) {}
}
public struct Form<Content: View>: _Leaf {
    public init(@ViewBuilder content: () -> Content) {}
}

public struct Section<Parent: View, Content: View, Footer: View>: _Leaf {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {}
}
extension Section where Parent == EmptyView, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) {}
}
extension Section where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {}
}
extension Section where Parent == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {}
}
extension Section where Parent == Text, Footer == EmptyView {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {}
}

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: _Leaf {
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
    public func onDelete(perform action: ((IndexSet) -> Void)?) -> some View { _Modified<Self>() }
}
extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {}
}

public struct NavigationPath: Equatable {
    public init() {}
    public var count: Int { 0 }
    public var isEmpty: Bool { true }
    public mutating func append<V: Hashable>(_ value: V) {}
    public mutating func removeLast(_ k: Int = 1) {}
}
public struct NavigationStack<Root: View>: _Leaf {
    public init(@ViewBuilder root: () -> Root) {}
    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) {}
    public init<Data: MutableCollection & RandomAccessCollection & RangeReplaceableCollection>(path: Binding<Data>, @ViewBuilder root: () -> Root) where Data.Element: Hashable {}
}
public struct NavigationLink<Label: View, Destination: View>: _Leaf {}
extension NavigationLink where Destination == Never {
    public init<P: Hashable>(value: P?, @ViewBuilder label: () -> Label) {}
}
extension NavigationLink where Label == Text, Destination == Never {
    public init<P: Hashable>(_ titleKey: LocalizedStringKey, value: P?) {}
}

public struct Toggle<Label: View>: _Leaf {
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {}
}
extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {}
}

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: _Leaf {
    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {}
}
extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {}
}

public struct TextField<Label: View>: _Leaf {}
extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis) {}
}
public struct SecureField<Label: View>: _Leaf {}
extension SecureField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}
}
public struct TextEditor: _Leaf { public init(text: Binding<String>) {} }

public struct LabeledContent<Label: View, Content: View>: _Leaf {}
extension LabeledContent where Label == Text, Content == Text {
    public init<S: StringProtocol>(_ titleKey: LocalizedStringKey, value: S) {}
}

public struct ProgressView: _Leaf { public init() {} }

public struct ContentUnavailableView<Label: View, Description: View, Actions: View>: _Leaf {}
extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    public init(_ titleKey: LocalizedStringKey, systemImage name: String, description: Text? = nil) {}
}

public struct TabView<SelectionValue: Hashable, Content: View>: _Leaf {
    public init(selection: Binding<SelectionValue>?, @ViewBuilder content: () -> Content) {}
}

// MARK: - Shapes

public protocol Shape: _Leaf {}
extension Shape {
    public func fill<S: ShapeStyle>(_ content: S) -> some View { _Modified<Self>() }
    public func stroke<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1) -> some View { _Modified<Self>() }
}
public struct Circle: Shape { public init() {} }
public struct Capsule: Shape { public init() {} }
public struct Rectangle: Shape { public init() {} }
public struct RoundedRectangle: Shape { public init(cornerRadius: CGFloat) {} }

// MARK: - Styles

@MainActor @preconcurrency
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Self.Configuration) -> Self.Body
    typealias Configuration = ButtonStyleConfiguration
}
public struct ButtonStyleConfiguration {
    public struct Label: _Leaf {}
    public let label: ButtonStyleConfiguration.Label
    public let isPressed: Bool
    public let role: ButtonRole?
}
@MainActor @preconcurrency public protocol PrimitiveButtonStyle {}
public struct PlainButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct BorderedButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle { public init() {} }
public struct BorderlessButtonStyle: PrimitiveButtonStyle { public init() {} }
extension PrimitiveButtonStyle where Self == PlainButtonStyle { public static var plain: PlainButtonStyle { PlainButtonStyle() } }
extension PrimitiveButtonStyle where Self == BorderedButtonStyle { public static var bordered: BorderedButtonStyle { BorderedButtonStyle() } }
extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { public static var borderedProminent: BorderedProminentButtonStyle { BorderedProminentButtonStyle() } }
extension PrimitiveButtonStyle where Self == BorderlessButtonStyle { public static var borderless: BorderlessButtonStyle { BorderlessButtonStyle() } }

public protocol LabelStyle {}
public struct TitleAndIconLabelStyle: LabelStyle {}
public struct IconOnlyLabelStyle: LabelStyle {}
extension LabelStyle where Self == TitleAndIconLabelStyle { public static var titleAndIcon: TitleAndIconLabelStyle { TitleAndIconLabelStyle() } }
extension LabelStyle where Self == IconOnlyLabelStyle { public static var iconOnly: IconOnlyLabelStyle { IconOnlyLabelStyle() } }

public protocol SymbolEffect {}
public struct VariableColorSymbolEffect: SymbolEffect {
    public var iterative: VariableColorSymbolEffect { self }
    public var cumulative: VariableColorSymbolEffect { self }
}
public struct PulseSymbolEffect: SymbolEffect {}
extension SymbolEffect where Self == VariableColorSymbolEffect { public static var variableColor: VariableColorSymbolEffect { VariableColorSymbolEffect() } }
extension SymbolEffect where Self == PulseSymbolEffect { public static var pulse: PulseSymbolEffect { PulseSymbolEffect() } }

// MARK: - Gestures

@MainActor @preconcurrency public protocol Gesture {
    associatedtype Value
}
public struct DragGesture: Gesture {
    public struct Value: Equatable, Sendable {
        public var translation: CGSize { .zero }
    }
    public init(minimumDistance: CGFloat = 10) {}
}
public struct _ChangedGesture<G: Gesture>: Gesture { public typealias Value = G.Value }
public struct _EndedGesture<G: Gesture>: Gesture { public typealias Value = G.Value }
public struct GestureStateGesture<G: Gesture, State>: Gesture { public typealias Value = G.Value }
extension Gesture {
    public func onEnded(_ action: @escaping (Self.Value) -> Void) -> _EndedGesture<Self> { _EndedGesture() }
    public func updating<State>(_ state: GestureState<State>, body: @escaping (Self.Value, inout State, inout Transaction) -> Void) -> GestureStateGesture<Self, State> { GestureStateGesture() }
}
extension Gesture where Value: Equatable {
    public func onChanged(_ action: @escaping (Self.Value) -> Void) -> _ChangedGesture<Self> { _ChangedGesture() }
}

// MARK: - Modifiers

extension View {
    public func font(_ font: Font?) -> some View { _Modified<Self>() }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { _Modified<Self>() }
    public func tint(_ tint: Color?) -> some View { _Modified<Self>() }
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View { _Modified<Self>() }
    public func padding(_ length: CGFloat) -> some View { _Modified<Self>() }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View { _Modified<Self>() }
    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View { _Modified<Self>() }
    public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func background<V: View>(_ background: V, alignment: Alignment = .center) -> some View { _Modified<Self>() }
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _Modified<Self>() }
    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View { _Modified<Self>() }
    public func opacity(_ opacity: Double) -> some View { _Modified<Self>() }
    public func shadow(color: Color = .black, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View { _Modified<Self>() }
    public func disabled(_ disabled: Bool) -> some View { _Modified<Self>() }
    public func lineLimit(_ number: Int?) -> some View { _Modified<Self>() }
    public func lineLimit(_ limit: ClosedRange<Int>) -> some View { _Modified<Self>() }
    public func truncationMode(_ mode: Text.TruncationMode) -> some View { _Modified<Self>() }
    public func multilineTextAlignment(_ alignment: TextAlignment) -> some View { _Modified<Self>() }
    public func minimumScaleFactor(_ factor: CGFloat) -> some View { _Modified<Self>() }
    public func labelStyle<S: LabelStyle>(_ style: S) -> some View { _Modified<Self>() }
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> some View { _Modified<Self>() }
    public func buttonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View { _Modified<Self>() }
    public func symbolEffect<T: SymbolEffect>(_ effect: T, isActive: Bool = true) -> some View { _Modified<Self>() }
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { _Modified<Self>() }
    public func transition(_ t: AnyTransition) -> some View { _Modified<Self>() }
    public func simultaneousGesture<G: Gesture>(_ gesture: G) -> some View { _Modified<Self>() }
    public func gesture<G: Gesture>(_ gesture: G) -> some View { _Modified<Self>() }
    public func tag<V: Hashable>(_ tag: V) -> some View { _Modified<Self>() }
    public func allowsHitTesting(_ enabled: Bool) -> some View { _Modified<Self>() }
    public func textSelection<S: TextSelectability>(_ selectability: S) -> some View { _Modified<Self>() }

    public func accessibilityLabel(_ label: Text) -> some View { _Modified<Self>() }
    public func accessibilityLabel(_ labelKey: LocalizedStringKey) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { _Modified<Self>() }
    public func accessibilityHint(_ hintKey: LocalizedStringKey) -> some View { _Modified<Self>() }
    public func accessibilityValue(_ valueKey: LocalizedStringKey) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func accessibilityValue<S: StringProtocol>(_ value: S) -> some View { _Modified<Self>() }
    public func accessibilityHidden(_ hidden: Bool) -> some View { _Modified<Self>() }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { _Modified<Self>() }

    public func onAppear(perform action: (() -> Void)? = nil) -> some View { _Modified<Self>() }
    public func onDisappear(perform action: (() -> Void)? = nil) -> some View { _Modified<Self>() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View { _Modified<Self>() }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View { _Modified<Self>() }
    public func task(priority: TaskPriority = .userInitiated, @_inheritActorContext _ action: @escaping @Sendable () async -> Void) -> some View { _Modified<Self>() }
    public func refreshable(@_inheritActorContext action: @escaping @Sendable () async -> Void) -> some View { _Modified<Self>() }
    public func onReceive<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View where P.Failure == Never { _Modified<Self>() }
    public func onOpenURL(perform action: @escaping (URL) -> Void) -> some View { _Modified<Self>() }

    public func navigationTitle(_ titleKey: LocalizedStringKey) -> some View { _Modified<Self>() }
    @_disfavoredOverload public func navigationTitle<S: StringProtocol>(_ title: S) -> some View { _Modified<Self>() }
    public func navigationDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View { _Modified<Self>() }
    public func toolbar<Content: View>(@ViewBuilder content: () -> Content) -> some View { _Modified<Self>() }
    public func searchable(text: Binding<String>) -> some View { _Modified<Self>() }
    public func swipeActions<T: View>(@ViewBuilder content: () -> T) -> some View { _Modified<Self>() }
    public func contextMenu<MenuItems: View>(@ViewBuilder menuItems: () -> MenuItems) -> some View { _Modified<Self>() }
    public func confirmationDialog<A: View>(_ titleKey: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A) -> some View { _Modified<Self>() }
    public func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View { _Modified<Self>() }
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View { _Modified<Self>() }

    public func keyboardType(_ type: UIKeyboardType) -> some View { _Modified<Self>() }
    public func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { _Modified<Self>() }
    public func autocorrectionDisabled(_ disable: Bool = true) -> some View { _Modified<Self>() }
}

// MARK: - UIKit bridging

@MainActor @preconcurrency
public protocol UIViewRepresentable: View where Body == Never {
    associatedtype UIViewType: UIView
    func makeUIView(context: Self.Context) -> Self.UIViewType
    func updateUIView(_ uiView: Self.UIViewType, context: Self.Context)
    typealias Context = UIViewRepresentableContext<Self>
}
extension UIViewRepresentable { public var body: Never { fatalError() } }
public struct UIViewRepresentableContext<Representable: UIViewRepresentable> {}

@preconcurrency @MainActor open class UIHostingController<Content: View>: UIViewController {
    public init(rootView: Content) { self.rootView = rootView }
    public var rootView: Content
}

// MARK: - Collection helpers SwiftUI adds

extension RangeReplaceableCollection where Self: MutableCollection {
    public mutating func remove(atOffsets offsets: IndexSet) {}
}
extension MutableCollection {
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {}
}
