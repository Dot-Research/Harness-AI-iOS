import Foundation

/// The key planes of the Harness Keyboard's typing layer.
public enum KeyboardPlane: String, Codable, Hashable, Sendable {
    case letters, numbers, symbols
}

/// How the host field wants text capitalized. Mirrors UITextAutocapitalizationType; the core is UIKit-free.
public enum KeyboardAutocapitalization: String, Codable, Hashable, Sendable {
    case none, words, sentences, allCharacters
}

public enum ShiftState: Equatable, Sendable {
    case off
    /// Capitalizes the next letter, then turns off.
    case once
    /// Caps lock: stays on until shift is tapped again.
    case locked
}

/// Shift key behavior: tap for one capital, double-tap for caps lock, tap again to release.
/// Automatic capitalization only ever turns shift on for one letter and never overrides caps lock.
public struct ShiftController: Equatable, Sendable {
    public static let doubleTapWindow: TimeInterval = 0.35

    public private(set) var state: ShiftState = .off
    private var lastTap: Date?

    public init() {}

    public var isActive: Bool { state != .off }

    public mutating func tap(at now: Date) {
        defer { lastTap = now }
        switch state {
        case .off:
            state = .once
        case .once:
            if let lastTap, now.timeIntervalSince(lastTap) <= Self.doubleTapWindow {
                state = .locked
            } else {
                state = .off
            }
        case .locked:
            state = .off
        }
    }

    /// Call after a character is typed; a one-shot shift is used up by it.
    public mutating func characterTyped() {
        if state == .once { state = .off }
        lastTap = nil
    }

    /// Applies the field's automatic capitalization for the text now before the cursor.
    public mutating func autoCapitalize(_ shouldCapitalize: Bool) {
        guard state != .locked else { return }
        state = shouldCapitalize ? .once : .off
        lastTap = nil
    }

    public func apply(to character: String) -> String {
        state == .off ? character : character.uppercased()
    }
}

/// What a key on the typing layer does.
public enum TypingKey: Hashable, Sendable {
    case character(String)
    case shift
    case delete
    case plane(KeyboardPlane)
}

/// Layout and text rules for the typing layer. Pure functions so they can be tested off-device.
public enum TypingKeyboard {
    /// The three rows above the bottom row (globe, plane switch, space, return).
    public static func rows(for plane: KeyboardPlane) -> [[TypingKey]] {
        func chars(_ s: String) -> [TypingKey] { s.map { .character(String($0)) } }
        switch plane {
        case .letters:
            return [
                chars("qwertyuiop"),
                chars("asdfghjkl"),
                [TypingKey.shift] + chars("zxcvbnm") + [TypingKey.delete],
            ]
        case .numbers:
            return [
                chars("1234567890"),
                chars("-/:;()$&@\""),
                [TypingKey.plane(.symbols)] + chars(".,?!'") + [TypingKey.delete],
            ]
        case .symbols:
            return [
                chars("[]{}#%^*+="),
                chars("_\\|~<>€£¥•"),
                [TypingKey.plane(.numbers)] + chars(".,?!'") + [TypingKey.delete],
            ]
        }
    }

    /// Extra keys beside the space bar for fields that need them.
    public static func spaceBarNeighbors(keyboardType: String?) -> [String] {
        switch keyboardType {
        case "emailAddress": return ["@", "."]
        case "URL": return ["/", "."]
        case "webSearch": return ["."]
        default: return []
        }
    }

    /// The return key's title for the field's return key type; nil shows the return arrow.
    public static func returnKeyTitle(for returnKeyType: String?) -> String? {
        switch returnKeyType {
        case "go": return "go"
        case "google", "yahoo", "search": return "search"
        case "join": return "join"
        case "next": return "next"
        case "route": return "route"
        case "send": return "send"
        case "done": return "done"
        case "continue": return "continue"
        case "emergencyCall": return "SOS"
        default: return nil
        }
    }

    /// Fields where capitalizing or adding periods would corrupt what the user types.
    public static func isLiteralField(keyboardType: String?) -> Bool {
        switch keyboardType {
        case "emailAddress", "URL", "numberPad", "phonePad", "decimalPad", "asciiCapableNumberPad": return true
        default: return false
        }
    }

    /// Whether the next letter should be a capital, given the text before the cursor.
    public static func shouldCapitalize(before: String?, mode: KeyboardAutocapitalization, keyboardType: String? = nil) -> Bool {
        if isLiteralField(keyboardType: keyboardType) { return false }
        let before = before ?? ""
        switch mode {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let last = before.last else { return true }
            return last.isWhitespace || last.isNewline
        case .sentences:
            guard let last = before.last(where: { $0 != " " && $0 != "\t" }) else { return true }
            if last.isNewline { return true }
            // Capitalize only once a space follows the sentence ender ("Hi." no, "Hi. " yes).
            guard before.last == " " || before.last == "\t" else { return false }
            return TextToken.sentenceEnders.contains(last)
        }
    }

    /// The space bar was tapped twice quickly: replace "word␠" with "word.␠"?
    /// Returns true when the text before the cursor ends in a word followed by exactly one space.
    public static func shouldInsertPeriodForDoubleSpace(before: String?, keyboardType: String? = nil) -> Bool {
        if isLiteralField(keyboardType: keyboardType) { return false }
        guard let before, before.hasSuffix(" ") else { return false }
        let withoutSpace = before.dropLast()
        guard let previous = withoutSpace.last else { return false }
        return previous.isLetter || previous.isNumber || previous == ")" || previous == "\"" || previous == "”" || previous == "'"
    }

    /// After space or an apostrophe on the numbers/symbols plane, iOS returns to letters.
    public static func returnsToLetters(after character: String, on plane: KeyboardPlane) -> Bool {
        plane != .letters && (character == " " || character == "'")
    }
}
