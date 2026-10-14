import Foundation
import XCTest
@testable import DictationCore

final class TypingKeyboardTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    // MARK: Shift

    func testSingleTapCapitalizesOneLetter() {
        var shift = ShiftController()
        shift.tap(at: start)
        XCTAssertEqual(shift.state, .once)
        XCTAssertEqual(shift.apply(to: "a"), "A")
        shift.characterTyped()
        XCTAssertEqual(shift.state, .off)
        XCTAssertEqual(shift.apply(to: "a"), "a")
    }

    func testDoubleTapLocksAndThirdTapReleases() {
        var shift = ShiftController()
        shift.tap(at: start)
        shift.tap(at: start.addingTimeInterval(0.2))
        XCTAssertEqual(shift.state, .locked)
        shift.characterTyped()
        shift.characterTyped()
        XCTAssertEqual(shift.state, .locked)
        shift.tap(at: start.addingTimeInterval(5))
        XCTAssertEqual(shift.state, .off)
    }

    func testSlowSecondTapTurnsShiftOff() {
        var shift = ShiftController()
        shift.tap(at: start)
        shift.tap(at: start.addingTimeInterval(1))
        XCTAssertEqual(shift.state, .off)
    }

    func testTypingBetweenTapsDoesNotLock() {
        var shift = ShiftController()
        shift.tap(at: start)
        shift.characterTyped()
        shift.tap(at: start.addingTimeInterval(0.1))
        XCTAssertEqual(shift.state, .once)
    }

    func testAutoCapitalizationNeverOverridesCapsLock() {
        var shift = ShiftController()
        shift.tap(at: start)
        shift.tap(at: start.addingTimeInterval(0.1))
        shift.autoCapitalize(false)
        XCTAssertEqual(shift.state, .locked)

        var other = ShiftController()
        other.autoCapitalize(true)
        XCTAssertEqual(other.state, .once)
        other.autoCapitalize(false)
        XCTAssertEqual(other.state, .off)
    }

    func testAutoCapitalizedShiftIsNotADoubleTap() {
        var shift = ShiftController()
        shift.autoCapitalize(true)
        shift.tap(at: start)
        XCTAssertEqual(shift.state, .off, "Tapping an automatically raised shift lowers it")
    }

    // MARK: Capitalization

    func testSentenceCapitalization() {
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: nil, mode: .sentences))
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: "", mode: .sentences))
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: "Done. ", mode: .sentences))
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: "Really?  ", mode: .sentences))
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: "First line\n", mode: .sentences))
        XCTAssertFalse(TypingKeyboard.shouldCapitalize(before: "Done.", mode: .sentences))
        XCTAssertFalse(TypingKeyboard.shouldCapitalize(before: "hello ", mode: .sentences))
        XCTAssertFalse(TypingKeyboard.shouldCapitalize(before: "hello", mode: .sentences))
    }

    func testWordsAllAndNoneCapitalization() {
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: "Ada ", mode: .words))
        XCTAssertFalse(TypingKeyboard.shouldCapitalize(before: "Ada", mode: .words))
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: "abc", mode: .allCharacters))
        XCTAssertFalse(TypingKeyboard.shouldCapitalize(before: "", mode: .none))
    }

    func testLiteralFieldsAreNeverCapitalized() {
        XCTAssertFalse(TypingKeyboard.shouldCapitalize(before: "", mode: .sentences, keyboardType: "emailAddress"))
        XCTAssertFalse(TypingKeyboard.shouldCapitalize(before: "", mode: .sentences, keyboardType: "URL"))
        XCTAssertTrue(TypingKeyboard.shouldCapitalize(before: "", mode: .sentences, keyboardType: "default"))
    }

    // MARK: Double space

    func testDoubleSpaceAfterWordAddsPeriod() {
        XCTAssertTrue(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: "See you "))
        XCTAssertTrue(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: "at 5 "))
        XCTAssertTrue(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: "(really) "))
    }

    func testDoubleSpaceDoesNotStackPunctuationOrSpaces() {
        XCTAssertFalse(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: "Done. "))
        XCTAssertFalse(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: "Wait,  "))
        XCTAssertFalse(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: " "))
        XCTAssertFalse(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: "word"))
        XCTAssertFalse(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: nil))
        XCTAssertFalse(TypingKeyboard.shouldInsertPeriodForDoubleSpace(before: "name ", keyboardType: "emailAddress"))
    }

    // MARK: Layout

    func testLetterRowsAreQwertyWithShiftAndDelete() {
        let rows = TypingKeyboard.rows(for: .letters)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].count, 10)
        XCTAssertEqual(rows[0].first, .character("q"))
        XCTAssertEqual(rows[1].count, 9)
        XCTAssertEqual(rows[2].first, .shift)
        XCTAssertEqual(rows[2].last, .delete)
    }

    func testNumberAndSymbolPlanesLinkToEachOther() {
        XCTAssertEqual(TypingKeyboard.rows(for: .numbers)[2].first, .plane(.symbols))
        XCTAssertEqual(TypingKeyboard.rows(for: .symbols)[2].first, .plane(.numbers))
        XCTAssertEqual(TypingKeyboard.rows(for: .numbers)[0], "1234567890".map { TypingKey.character(String($0)) })
    }

    func testEveryPlaneHasDeleteAndNoDuplicateCharacters() {
        for plane in [KeyboardPlane.letters, .numbers, .symbols] {
            let keys = TypingKeyboard.rows(for: plane).flatMap { $0 }
            XCTAssertTrue(keys.contains(.delete), "\(plane)")
            let characters = keys.compactMap { key -> String? in
                if case let .character(c) = key { return c }
                return nil
            }
            XCTAssertEqual(characters.count, Set(characters).count, "\(plane)")
        }
    }

    func testFieldSpecificKeys() {
        XCTAssertEqual(TypingKeyboard.spaceBarNeighbors(keyboardType: "emailAddress"), ["@", "."])
        XCTAssertEqual(TypingKeyboard.spaceBarNeighbors(keyboardType: "URL"), ["/", "."])
        XCTAssertEqual(TypingKeyboard.spaceBarNeighbors(keyboardType: nil), [])
        XCTAssertEqual(TypingKeyboard.returnKeyTitle(for: "send"), "send")
        XCTAssertEqual(TypingKeyboard.returnKeyTitle(for: "google"), "search")
        XCTAssertNil(TypingKeyboard.returnKeyTitle(for: "default"))
        XCTAssertNil(TypingKeyboard.returnKeyTitle(for: nil))
    }

    func testSpaceAndApostropheReturnToLetters() {
        XCTAssertTrue(TypingKeyboard.returnsToLetters(after: " ", on: .numbers))
        XCTAssertTrue(TypingKeyboard.returnsToLetters(after: "'", on: .symbols))
        XCTAssertFalse(TypingKeyboard.returnsToLetters(after: "4", on: .numbers))
        XCTAssertFalse(TypingKeyboard.returnsToLetters(after: " ", on: .letters))
    }
}
