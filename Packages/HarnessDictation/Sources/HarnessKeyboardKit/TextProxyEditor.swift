#if os(iOS)
import UIKit
import DictationCore

/// All edits to the host app's text go through here so the last change can be undone.
@MainActor
final class TextProxyEditor {
    private let proxy: @MainActor () -> UITextDocumentProxy?

    struct RewriteTarget {
        let text: String
        let isSelection: Bool
        let snapshot: RewriteTargetSnapshot
    }

    /// The last change: what was removed and what was inserted in its place.
    private(set) var lastEdit: (removed: String, inserted: String)?

    init(proxy: @escaping @MainActor () -> UITextDocumentProxy?) {
        self.proxy = proxy
    }

    var context: InsertionContext {
        guard let p = proxy() else { return InsertionContext() }
        return InsertionContext(before: p.documentContextBeforeInput, after: p.documentContextAfterInput, selectedText: p.selectedText)
    }

    var fieldTraits: FieldTraits {
        guard let p = proxy() else { return FieldTraits() }
        let contentType: UITextContentType? = p.textContentType ?? nil
        return FieldTraits(
            keyboardType: p.keyboardType.map(Self.name(for:)),
            returnKeyType: p.returnKeyType.map(Self.name(for:)),
            textContentType: contentType?.rawValue
        )
    }

    /// The text before the cursor that the host lets the keyboard see.
    var textBeforeInput: String? { proxy()?.documentContextBeforeInput }

    var autocapitalization: KeyboardAutocapitalization {
        switch proxy()?.autocapitalizationType ?? .sentences {
        case .none: return .none
        case .words: return .words
        case .allCharacters: return .allCharacters
        default: return .sentences
        }
    }

    /// Inserts dictated text, fitted to what's around the cursor.
    func insertDictation(_ text: String, languageCode: String?) {
        guard let p = proxy() else { return }
        let selected = p.selectedText ?? ""
        let fitted = InsertionPlanner.fit(text, into: context, languageCode: languageCode)
        guard !fitted.isEmpty else { return }
        p.insertText(fitted) // replaces the selection, if any
        lastEdit = (removed: selected, inserted: fitted)
    }

    /// The text Fix/Rewrite/Ask should work on: the selection, else the current paragraph before
    /// the cursor (as much of it as the host app lets a keyboard see).
    func rewriteTarget() -> RewriteTarget? {
        guard let p = proxy() else { return nil }
        let snapshot = Self.snapshot(for: p)
        if let selected = snapshot.selectedText, !selected.isEmpty {
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return RewriteTarget(text: selected, isSelection: true, snapshot: snapshot)
        }
        guard let before = snapshot.before, !before.isEmpty else { return nil }
        let paragraph = before.components(separatedBy: "\n").last ?? before
        guard !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RewriteTarget(text: paragraph, isSelection: false, snapshot: snapshot)
    }

    /// Used to discard a pending rewrite when the host changes its document or cursor context.
    func targetMatches(_ target: RewriteTarget) -> Bool {
        guard let p = proxy() else { return false }
        return target.snapshot.matches(Self.snapshot(for: p))
    }

    /// Replaces only the original rewrite target. A stale result leaves the host text untouched.
    @discardableResult
    func replaceTarget(_ target: RewriteTarget, with replacement: String) -> Bool {
        guard let p = proxy() else { return false }
        let current = Self.snapshot(for: p)
        guard target.snapshot.matches(current) else { return false }
        if target.isSelection {
            guard current.selectedText == target.text else { return false }
            p.insertText(replacement)
        } else {
            guard let before = current.before, before.hasSuffix(target.text) else { return false }
            for _ in 0..<target.text.count { p.deleteBackward() }
            p.insertText(replacement)
        }
        lastEdit = (removed: target.text, inserted: replacement)
        return true
    }

    private static func snapshot(for proxy: UITextDocumentProxy) -> RewriteTargetSnapshot {
        RewriteTargetSnapshot(
            documentIdentifier: proxy.documentIdentifier,
            before: proxy.documentContextBeforeInput,
            after: proxy.documentContextAfterInput,
            selectedText: proxy.selectedText
        )
    }

    var canUndo: Bool {
        guard let lastEdit, let before = proxy()?.documentContextBeforeInput else { return false }
        return before.hasSuffix(lastEdit.inserted)
    }

    func undo() {
        guard canUndo, let lastEdit, let p = proxy() else { return }
        for _ in 0..<lastEdit.inserted.count { p.deleteBackward() }
        if !lastEdit.removed.isEmpty { p.insertText(lastEdit.removed) }
        self.lastEdit = nil
    }

    // MARK: Basic keys

    func insert(_ s: String) {
        proxy()?.insertText(s)
        lastEdit = nil
    }

    func deleteBackward() {
        proxy()?.deleteBackward()
        lastEdit = nil
    }

    // MARK: UIKit enum names (the core is UIKit-free)

    nonisolated static func name(for type: UIKeyboardType) -> String {
        switch type {
        case .asciiCapable: return "asciiCapable"
        case .numbersAndPunctuation: return "numbersAndPunctuation"
        case .URL: return "URL"
        case .numberPad: return "numberPad"
        case .phonePad: return "phonePad"
        case .namePhonePad: return "namePhonePad"
        case .emailAddress: return "emailAddress"
        case .decimalPad: return "decimalPad"
        case .twitter: return "twitter"
        case .webSearch: return "webSearch"
        case .asciiCapableNumberPad: return "asciiCapableNumberPad"
        default: return "default"
        }
    }

    nonisolated static func name(for type: UIReturnKeyType) -> String {
        switch type {
        case .go: return "go"
        case .google: return "google"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .search: return "search"
        case .send: return "send"
        case .yahoo: return "yahoo"
        case .done: return "done"
        case .emergencyCall: return "emergencyCall"
        case .continue: return "continue"
        default: return "default"
        }
    }
}
#endif
