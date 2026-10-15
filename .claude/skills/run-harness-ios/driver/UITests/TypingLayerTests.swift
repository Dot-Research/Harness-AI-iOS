import XCTest

/// Typing layer flows. Work with or without Full Access.
final class TypingLayerTests: HarnessKeyboardTestCase {

    func testShiftCapsLockPlanesAndDoubleSpace() {
        let field = focus("plain")
        showTypingLayer()
        shot("typing-01-empty-autoshift")
        XCTAssertEqual(shiftValue, "On", "empty sentence field should auto-capitalize")

        typeLetters("hi")
        XCTAssertEqual(value(field), "Hi")
        XCTAssertEqual(shiftValue, "Off")

        // Double-space period: two taps inside 0.6 s.
        key("space").doubleTap()
        XCTAssertEqual(value(field), "Hi. ")
        XCTAssertEqual(shiftValue, "On", "auto-capital after \". \"")
        shot("typing-02-after-double-space")
        typeLetters("ok")
        XCTAssertEqual(value(field), "Hi. Ok")

        // Shift once: one capital, then off.
        tap("Shift")
        XCTAssertEqual(shiftValue, "On")
        typeLetters("x")
        XCTAssertEqual(shiftValue, "Off")

        // Double-tap: caps lock until tapped again.
        key("Shift").doubleTap()
        XCTAssertEqual(shiftLabel, "Caps lock")
        shot("typing-03-caps-lock")
        typeLetters("ab")
        XCTAssertEqual(shiftLabel, "Caps lock")
        tap("Caps lock")
        XCTAssertEqual(shiftValue, "Off")
        XCTAssertEqual(value(field), "Hi. OkXAB")

        // 123 -> #+= -> 123 -> ABC.
        tap("Numbers")
        XCTAssertTrue(key("1").waitForExistence(timeout: 2))
        shot("typing-04-numbers")
        tap("1")
        tap("More symbols")
        XCTAssertTrue(key("#").waitForExistence(timeout: 2))
        shot("typing-05-symbols")
        tap("#")
        tap("Numbers")
        XCTAssertTrue(key("1").waitForExistence(timeout: 2))
        tap("Letters")
        XCTAssertTrue(key("q").waitForExistence(timeout: 2) || key("Q").exists)
        XCTAssertEqual(value(field), "Hi. OkXAB1#")
        shot("typing-06-back-to-letters")
    }

    func testNewlineAutoCapitalizes() {
        let field = focus("notes")
        showTypingLayer()
        typeLetters("a")
        tap("Return")
        XCTAssertEqual(shiftValue, "On", "auto-capital after newline")
        typeLetters("b")
        XCTAssertEqual(value(field), "A\nB")
        shot("typing-07-newline")
    }

    func testEmailFieldKeys() {
        let field = focus("email")
        showTypingLayer()
        XCTAssertTrue(key("@").exists, "email field shows @")
        XCTAssertTrue(key(".").exists, "email field shows .")
        XCTAssertEqual(shiftValue, "Off", "no auto-capital in email fields")
        typeLetters("a")
        tap("@")
        typeLetters("b")
        tap(".")
        typeLetters("io")
        XCTAssertEqual(value(field), "a@b.io")
        shot("typing-08-email")
    }

    func testReturnKeyTitles() {
        var seen: [String: String] = [:]
        for (field, expected) in [("send", "send"), ("search", "search"), ("url", "go"), ("plain", "Return")] {
            focus(field)
            showTypingLayer()
            seen[field] = returnKeyLabel
            shot("typing-10-return-\(field)")
        }
        note("return key titles: \(seen)")
        XCTAssertEqual(seen["send"], "send")
        XCTAssertEqual(seen["search"], "search")
        XCTAssertEqual(seen["url"], "go")
        XCTAssertEqual(seen["plain"], "Return")
        focus("url")
        showTypingLayer()
        XCTAssertTrue(key("/").exists, "URL field shows /")
    }

    /// The waveform key switches to the dictation panel and the choice survives a relaunch.
    func testWaveformToggleIsRemembered() {
        focus("plain")
        showTypingLayer()
        tap("Show dictation panel")
        XCTAssertTrue(key("Show keyboard").waitForExistence(timeout: 3))
        shot("toggle-01-dictation-panel")

        focus("plain")   // terminates and relaunches FieldLab; the keyboard comes up fresh
        XCTAssertTrue(key("Show keyboard").waitForExistence(timeout: 3), "dictation panel choice not remembered")
        shot("toggle-02-after-relaunch")

        tap("Show keyboard")
        XCTAssertTrue(key("Show dictation panel").waitForExistence(timeout: 3))
        focus("plain")
        XCTAssertTrue(key("Show dictation panel").waitForExistence(timeout: 3), "typing layer choice not remembered")
    }
}
