import Foundation
import XCTest
@testable import DictationCore

final class InstructionSanitizerTests: XCTestCase {
    func testPreservesGenuineHeading() throws {
        XCTAssertEqual(try RewriteOutputSanitizer.clean("Shopping list:\nMilk\nBread", original: "Shopping list:\nMilk\nBread"), "Shopping list:\nMilk\nBread")
        XCTAssertEqual(try RewriteOutputSanitizer.clean("Sure things to bring:\nA coat", original: "Sure things to bring:\nA coat"), "Sure things to bring:\nA coat")
    }

    func testStripsOnlyRecognizedPreamble() throws {
        XCTAssertEqual(try RewriteOutputSanitizer.clean("Sure! Here's the edited text:\nMeet at five.", original: "meet at five"), "Meet at five.")
        XCTAssertEqual(try RewriteOutputSanitizer.clean("Edited text: Meet at five.", original: "meet at five"), "Meet at five.")
        XCTAssertEqual(try RewriteOutputSanitizer.clean("Sure:\nI'll bring milk.", original: "Sure:\nI'll bring milk."), "Sure:\nI'll bring milk.")
    }

    func testCancelRewriteBridgePreservesTheJobID() throws {
        let jobID = UUID()
        var queue = CommandQueue()
        queue.append(.cancelRewrite(jobID: jobID), now: Date(timeIntervalSince1970: 1800000000))
        let decoded = try BridgeCodec.decode(CommandQueue.self, from: BridgeCodec.encode(queue))
        XCTAssertEqual(decoded.commands.first?.kind, .cancelRewrite(jobID: jobID))
    }
}

final class DictationInstructionTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("instructions-\(UUID().uuidString)", isDirectory: true)
    }

    func testMissingFileUsesDefaultsAndDoesNotOverwriteUserFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationInstructionFile(directory: directory)
        XCTAssertEqual(store.fileURL.lastPathComponent, "instruction.md")
        XCTAssertTrue(try store.load().contains("natural voice"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.save("Keep my Chinese wording.\n保留原文。\n")
        XCTAssertEqual(try store.load(), "Keep my Chinese wording.\n保留原文。\n")
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("Keep my Chinese wording.\n保留原文。\n".utf8))
    }

    func testUTF8ByteLimitAndFailedSavePreserveLastGoodFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationInstructionFile(directory: directory)
        try store.save("My existing instructions")
        XCTAssertThrowsError(try store.save(String(repeating: "界", count: 2731)))
        XCTAssertEqual(try store.load(), "My existing instructions")
        try store.save(String(repeating: "a", count: 8192))
        XCTAssertEqual(try store.load().utf8.count, 8192)
        XCTAssertThrowsError(try store.save(String(repeating: "a", count: 8193)))
        XCTAssertEqual(try store.load().utf8.count, 8192)
    }

    func testInvalidExternalFilesFailInsteadOfTruncatingOrFallingBack() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationInstructionFile(directory: directory)
        try store.save("valid")
        try Data([0xFF, 0xFE]).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        try Data(repeating: 65, count: 8193).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }

    func testInstructionImportKeepsPortableFileAndRejectsInvalidInput() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationInstructionFile(directory: directory)
        try store.save(DictationInstructions.decode(Data("# My voice\nUse short paragraphs.\n".utf8)))
        XCTAssertEqual(try store.load(), "# My voice\nUse short paragraphs.\n")
        XCTAssertThrowsError(try DictationInstructions.decode(Data([0xFF])))
    }

    func testAllRewriteActionsAndPolishIncludeUserInstructions() {
        let custom = "Use my natural voice. Preserve Chinese punctuation."
        for action in [RewriteAction.fix, .rewrite(modeID: "message"), .instruct("Make it shorter.")] {
            let prompt = RewritePromptBuilder.instructions(for: action, modes: [.message], userInstructions: custom)
            XCTAssertTrue(prompt.contains(custom))
            XCTAssertTrue(prompt.contains("Never add information"))
        }
        let polish = RewritePromptBuilder.polishInstructions(for: .message, userInstructions: custom)
        XCTAssertTrue(polish.contains(custom))
        XCTAssertTrue(polish.contains("do not summarize or add anything"))
    }

    func testLegacyPromptCallsKeepSafeDefaultsAndModeInstruction() {
        let mode = DictationMode(id: "mine", name: "Mine", style: .custom, instruction: "Keep code snippets intact.", aiPolish: true)
        let prompt = RewritePromptBuilder.instructions(for: .rewrite(modeID: "mine"), modes: [mode])
        XCTAssertTrue(prompt.contains("natural voice"))
        XCTAssertTrue(prompt.contains("Keep code snippets intact."))
        XCTAssertTrue(RewritePromptBuilder.polishInstructions(for: mode).contains("natural voice"))
    }
}
