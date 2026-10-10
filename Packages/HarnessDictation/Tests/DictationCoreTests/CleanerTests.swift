import XCTest
@testable import DictationCore

final class CleanerTests: XCTestCase {
    private func clean(_ text: String, _ configure: (inout CleanupOptions) -> Void = { _ in }) -> String {
        var options = CleanupOptions(dropFinalPeriodForShortMessages: false)
        configure(&options)
        return TranscriptCleaner(options: options).clean(text)
    }

    // MARK: Fillers

    func testRemovesFillersAndTheirPauseCommas() {
        XCTAssertEqual(clean("Um, so I think, uh, we should go."), "So I think we should go.")
        XCTAssertEqual(clean("I um think we uh should go"), "I think we should go")
        XCTAssertEqual(clean("I think, um."), "I think.")
    }

    func testKeepsInterjectionCommaBeforeFiller() {
        XCTAssertEqual(clean("Well, um, I think it works."), "Well, I think it works.")
    }

    func testRemovesPhraseFillersOnlyWhenSetOffByCommas() {
        XCTAssertEqual(clean("It was, you know, a long day."), "It was a long day.")
        XCTAssertEqual(clean("Do you know the address?"), "Do you know the address?")
        XCTAssertEqual(clean("I like the blue one."), "I like the blue one.")
        XCTAssertEqual(clean("It was, like, huge."), "It was huge.")
    }

    // MARK: Repetitions

    func testRemovesStutters() {
        XCTAssertEqual(clean("Send the the contract today."), "Send the contract today.")
        XCTAssertEqual(clean("I think I think we're ready."), "I think we're ready.")
        XCTAssertEqual(clean("We need to, we need to move fast."), "We need to move fast.")
    }

    func testKeepsLegitimateDoubles() {
        XCTAssertEqual(clean("It was very very good."), "It was very very good.")
        XCTAssertEqual(clean("What it is is complicated."), "What it is is complicated.")
        XCTAssertEqual(clean("Bye bye."), "Bye bye.")
    }

    // MARK: Self-corrections

    func testAnchoredCorrection() {
        XCTAssertEqual(clean("Let's meet on Tuesday, no wait, on Thursday."), "Let's meet on Thursday.")
    }

    func testCategoryCorrections() {
        XCTAssertEqual(clean("Let's meet at 3, sorry, 4 pm."), "Let's meet at 4 pm.")
        XCTAssertEqual(clean("Send it to John, I mean, Jane."), "Send it to Jane.")
        XCTAssertEqual(clean("Book the flight for Monday no wait Tuesday."), "Book the flight for Tuesday.")
    }

    func testCorrectionOfPreviousSentence() {
        XCTAssertEqual(clean("Meet on Tuesday. No wait, Thursday."), "Meet on Thursday.")
    }

    func testDoesNotTouchOrdinarySorryOrIMean() {
        XCTAssertEqual(clean("I'm sorry, I can't make it."), "I'm sorry, I can't make it.")
        XCTAssertEqual(clean("Sorry for the delay."), "Sorry for the delay.")
    }

    func testAmbiguousCorrectionLeftAlone() {
        // No anchor and no matching kind: better to leave it than to guess.
        XCTAssertEqual(clean("The house is big, no wait, it is huge."), "The house is big, no wait, it is huge.")
    }

    // MARK: Spoken commands

    func testNewLineAndParagraph() {
        XCTAssertEqual(clean("Hi Dana new line thanks for today"), "Hi Dana\nThanks for today")
        XCTAssertEqual(clean("First point. New paragraph. Second point."), "First point.\n\nSecond point.")
        XCTAssertEqual(clean("Hello, new line, how are you"), "Hello\nHow are you")
    }

    func testBulletPoints() {
        XCTAssertEqual(clean("Groceries bullet point milk bullet point eggs"), "Groceries\n- Milk\n- Eggs")
    }

    func testScratchThat() {
        XCTAssertEqual(clean("Send it tomorrow. Scratch that. Send it today."), "Send it today.")
        XCTAssertEqual(clean("Call me at noon, scratch that"), "")
    }

    func testSpokenPunctuationIsOptIn() {
        XCTAssertEqual(clean("The trial period ends Friday"), "The trial period ends Friday")
        XCTAssertEqual(clean("Are you coming question mark", { $0.spokenPunctuation = true }), "Are you coming?")
        XCTAssertEqual(clean("yes comma I am period", { $0.spokenPunctuation = true }), "Yes, I am.")
    }

    // MARK: Lists

    func testOrdinalList() {
        XCTAssertEqual(
            clean("I need three things, first, milk, second, eggs, and third, bread."),
            "I need three things:\n1. Milk\n2. Eggs\n3. Bread"
        )
    }

    func testListFollowedByMoreText() {
        XCTAssertEqual(
            clean("Agenda: first, budget, second, timeline, finally, owners. Thanks everyone."),
            "Agenda:\n1. Budget\n2. Timeline\n3. Owners\n\nThanks everyone."
        )
    }

    func testTwoOrdinalsAreNotAList() {
        XCTAssertEqual(clean("First, we eat. Second, we sleep."), "First, we eat. Second, we sleep.")
    }

    func testWaitASecondIsNotAList() {
        XCTAssertEqual(clean("Wait a second, I'm coming."), "Wait a second, I'm coming.")
    }

    // MARK: Capitalization and punctuation

    func testCapitalization() {
        XCTAssertEqual(clean("i think i'm ready. are you? yes i am"), "I think I'm ready. Are you? Yes I am")
        XCTAssertEqual(clean("4 pm works. bring snacks, e.g. chips and dip."), "4 pm works. Bring snacks, e.g. chips and dip.")
        XCTAssertEqual(clean("Well, you know, it's fine."), "Well, it's fine.")
    }

    func testPreservesEmailsTimesNumbersAndUrls() {
        let text = "Email jane@example.com at 3:30 for 3.5 hours about harness.ai/docs."
        XCTAssertEqual(clean(text), "Email jane@example.com at 3:30 for 3.5 hours about harness.ai/docs.")
    }

    func testRepairsPunctuation() {
        XCTAssertEqual(clean("Hello , world ."), "Hello, world.")
        XCTAssertEqual(clean(", hello"), "Hello")
        XCTAssertEqual(clean("Done,."), "Done.")
    }

    func testQuotesAndBrackets() {
        XCTAssertEqual(clean("He said \"call me\" (later) today"), "He said \"call me\" (later) today")
    }

    // MARK: Modes and languages

    func testMessageModeDropsFinalPeriodOfOneSentence() {
        let options = DictationMode.message.cleanupOptions(base: CleanupOptions(), languageCode: "en")
        XCTAssertEqual(TranscriptCleaner(options: options).clean("See you at 5."), "See you at 5")
        XCTAssertEqual(TranscriptCleaner(options: options).clean("See you at 5. Bring the keys."), "See you at 5. Bring the keys.")
        XCTAssertEqual(TranscriptCleaner(options: options).clean("It costs $3.50."), "It costs $3.50")
    }

    func testVerbatimKeepsFillersButStillHonoursCommands() {
        let options = DictationMode.verbatim.cleanupOptions(base: CleanupOptions(), languageCode: "en")
        XCTAssertEqual(TranscriptCleaner(options: options).clean("um the the code new line 1234"), "Um the the code\n1234")
    }

    func testNonEnglishSkipsEnglishRules() {
        let cleaned = clean("Um, er sagte, no wait, nein.", { $0.languageCode = "de" })
        XCTAssertEqual(cleaned, "Er sagte, no wait, nein.")
    }

    func testChineseHasNoSpacesBetweenWords() {
        XCTAssertEqual(clean("我想 去 北京。", { $0.languageCode = "zh" }), "我想去北京。")
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(clean(""), "")
        XCTAssertEqual(clean("   \n  "), "")
        XCTAssertEqual(clean("um uh"), "")
    }
}
