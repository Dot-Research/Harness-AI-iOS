import XCTest

/// Shared helpers. Screenshots are attached to the xcresult with `keepAlways`;
/// `sim.sh test` exports them to build/harness-sim/shots/.
class HarnessKeyboardTestCase: XCTestCase {
    let lab = XCUIApplication()   // FieldLab, the test target app
    static let harnessID = "org.harness.ios"

    override func setUp() {
        continueAfterFailure = false
    }

    func shot(_ name: String, _ app: XCUIApplication? = nil) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func dump(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name + ".tree.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Launches FieldLab showing only `field`, focuses it, and makes sure the Harness keyboard is up.
    @discardableResult
    func focus(_ field: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        lab.terminate()
        lab.launchArguments = ["-only", field]
        lab.launch()
        // Not descendants(...)[field]: that also matches the caption Text with the same label.
        let element = field == "notes" ? lab.textViews[field].firstMatch : lab.textFields[field].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), "no field \(field)", file: file, line: line)
        element.tap()
        switchToHarness(file: file, line: line)
        return element
    }

    /// "Ask Harness" exists only on the Harness keyboard (the system keyboard's mic key is also "Dictate").
    /// Cycle input modes with the globe ("Next keyboard") until it shows up.
    func switchToHarness(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 {
            if key("Ask Harness").waitForExistence(timeout: 3) { return }
            let globe = lab.buttons["Next keyboard"].firstMatch
            if globe.exists { globe.tap() } else { break }
        }
        dump("no-harness-keyboard", lab)
        shot("no-harness-keyboard")
        XCTFail("Harness keyboard did not appear (is it enabled? run sim.sh keyboard-prefs)", file: file, line: line)
    }

    func key(_ label: String) -> XCUIElement { lab.buttons[label].firstMatch }

    /// Taps a key by its label, failing with a hierarchy dump if it isn't there.
    func tap(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = key(label)
        if !element.waitForExistence(timeout: 3) {
            dump("missing-\(label)", lab)
            XCTFail("no key \(label)", file: file, line: line)
            return
        }
        element.tap()
    }

    /// Types lowercase letters; the label shown is uppercase while shift is on.
    func typeLetters(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for ch in text {
            if ch == " " { tap("space", file: file, line: line); continue }
            let lower = String(ch)
            let upper = lower.uppercased()
            if key(upper).exists { key(upper).tap() } else { tap(lower, file: file, line: line) }
        }
    }

    /// Shows the typing layer (letters) if the dictation panel is up.
    func showTypingLayer() {
        if key("Show keyboard").exists { key("Show keyboard").tap() }
        XCTAssertTrue(key("Show dictation panel").waitForExistence(timeout: 3), "typing layer not shown")
    }

    /// The return key's title: send, search, go… or "Return" for the arrow.
    var returnKeyLabel: String {
        let titles = ["Return", "go", "search", "join", "next", "route", "send", "done", "continue", "SOS"]
        return titles.first { key($0).exists } ?? "?"
    }

    func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "note"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("NOTE:", text)
    }

    func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    var shiftValue: String { lab.buttons.matching(NSPredicate(format: "label IN {'Shift','Caps lock'}")).firstMatch.value as? String ?? "?" }
    var shiftLabel: String { lab.buttons.matching(NSPredicate(format: "label IN {'Shift','Caps lock'}")).firstMatch.label }

    /// Text inside any element of `app` (banner messages, status titles).
    func waitForText(_ app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return app.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }
}
