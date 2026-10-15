import XCTest

/// Needs the Harness keyboard enabled WITH Allow Full Access (`sim.sh keyboard --full-access`).
final class FullAccessTests: HarnessKeyboardTestCase {

    /// Without Full Access the keyboard shows "Turn on Full Access" on the dictation panel.
    func testDictationPanelReflectsFullAccess() {
        focus("plain")
        if key("Show dictation panel").exists { tap("Show dictation panel") }
        let card = waitForText(lab, containing: "Turn on Full Access", timeout: 2)
        shot(card ? "access-01-no-full-access-card" : "access-01-dictation-panel")
        let expected = ProcessInfo.processInfo.environment["EXPECT_FULL_ACCESS"] ?? "?"
        if expected == "1" { XCTAssertFalse(card, "Full Access is on but the keyboard asks for it") }
        if expected == "0" { XCTAssertTrue(card, "Full Access is off but no card") }
        tap("Show keyboard")
    }

    /// Fix / Rewrite / Ask are disabled once Dictate is tapped (waiting for the app, listening, finishing).
    func testTextActionsDisabledWhileDictating() {
        let field = focus("plain")
        showTypingLayer()
        typeLetters("hello")
        XCTAssertTrue(key("Ask Harness").isEnabled, "Ask should be enabled at rest")
        tap("Dictate")
        // Check immediately: the keyboard may open Harness, which backgrounds FieldLab.
        let fix = key("Fix"), rewrite = key("Rewrite"), ask = key("Ask Harness")
        let states = (fix.exists ? fix.isEnabled : nil, rewrite.exists ? rewrite.isEnabled : nil, ask.exists ? ask.isEnabled : nil)
        shot("dictating-01-after-dictate-tap")
        let harness = XCUIApplication(bundleIdentifier: Self.harnessID)
        let opened = harness.wait(for: .runningForeground, timeout: 3)
        note("Harness opened from keyboard: \(opened); Fix/Rewrite/Ask enabled: \(String(describing: states))")
        if opened { shot("dictating-02-harness-opened"); dump("dictating-harness", harness) }
        XCTAssertEqual(states.0, false, "Fix enabled while dictating")
        XCTAssertEqual(states.1, false, "Rewrite enabled while dictating")
        XCTAssertEqual(states.2, false, "Ask enabled while dictating")
        lab.activate()
        _ = field.waitForExistence(timeout: 5)
        shot("dictating-03-back-in-fieldlab")
        if key("Cancel").exists { key("Cancel").tap() }
    }

    /// Fix hands the text to the app (no Apple Intelligence on the simulator). If Harness never answers,
    /// the keyboard gives up (25 s once the app's heartbeat is stale) instead of spinning forever.
    func testRewriteGivesUpWhenAppDoesNotAnswer() {
        XCUIApplication(bundleIdentifier: Self.harnessID).terminate()
        let field = focus("plain")
        showTypingLayer()
        typeLetters("helo world")
        tap("Fix")
        let harness = XCUIApplication(bundleIdentifier: Self.harnessID)
        if harness.wait(for: .runningForeground, timeout: 3) {
            note("Harness opened for the rewrite; terminating it so the rewrite cannot be answered")
            shot("rewrite-00-harness-opened")
            harness.terminate()
            lab.activate()
        }
        shot("rewrite-01-rewriting")
        let gaveUp = waitForText(lab, containing: "didn't finish the rewrite", timeout: 45)
        let other = lab.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Rewrite' OR label CONTAINS 'subscription' OR label CONTAINS 'Open the Harness'")).allElementsBoundByIndex.map(\.label)
        shot("rewrite-02-outcome")
        note("rewrite outcome gaveUp=\(gaveUp) labels=\(other) text=\(value(field))")
        XCTAssertTrue(gaveUp, "keyboard did not give up on the rewrite")
        XCTAssertEqual(value(field), "Helo world", "text must be unchanged")
    }

}
