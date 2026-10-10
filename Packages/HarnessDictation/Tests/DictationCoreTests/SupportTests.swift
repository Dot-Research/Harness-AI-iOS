import XCTest
@testable import DictationCore

final class DictionaryTests: XCTestCase {
    func testAutomaticForms() {
        XCTAssertEqual(Set(PersonalDictionary.automaticForms(for: "OpenRouter")), ["openrouter", "open router"])
        XCTAssertTrue(PersonalDictionary.automaticForms(for: "SwiftUI").contains("swift u i"))
        XCTAssertTrue(PersonalDictionary.automaticForms(for: "iPhone").contains("i phone"))
    }

    func testAppliesWholeWordsCaseInsensitively() {
        let dictionary = PersonalDictionary(entries: [
            DictionaryEntry(written: "OpenRouter"),
            DictionaryEntry(written: "Feili Estates", soundsLike: ["fay lee estates"]),
            DictionaryEntry(written: "iPhone"),
            DictionaryEntry(written: "HOA"),
        ])
        XCTAssertEqual(dictionary.apply(to: "Route it through open router."), "Route it through OpenRouter.")
        XCTAssertEqual(dictionary.apply(to: "Call Fay Lee Estates today"), "Call Feili Estates today")
        XCTAssertEqual(dictionary.apply(to: "Iphone and iphone."), "iPhone and iPhone.")
        XCTAssertEqual(dictionary.apply(to: "The hoa fee"), "The HOA fee")
        // Not inside other words.
        XCTAssertEqual(dictionary.apply(to: "shoal"), "shoal")
    }

    func testMultiWordFormsDoNotSpanPunctuation() {
        let dictionary = PersonalDictionary(entries: [DictionaryEntry(written: "OpenRouter")])
        XCTAssertEqual(dictionary.apply(to: "open. Router"), "open. Router")
    }

    func testContextualStringsDeduplicate() {
        let dictionary = PersonalDictionary(entries: [DictionaryEntry(written: "Harness"), DictionaryEntry(written: "harness"), DictionaryEntry(written: " ")])
        XCTAssertEqual(dictionary.contextualStrings, ["Harness"])
    }
}

final class InsertionTests: XCTestCase {
    func testStartOfField() {
        XCTAssertEqual(InsertionPlanner.fit("hello there.", into: InsertionContext(before: "", after: "")), "Hello there.")
    }

    func testContinuingASentence() {
        XCTAssertEqual(InsertionPlanner.fit("The house is ready.", into: InsertionContext(before: "I wanted to say", after: nil)), " the house is ready.")
        XCTAssertEqual(InsertionPlanner.fit("Dana is coming.", into: InsertionContext(before: "Good news,", after: nil)), " Dana is coming.")
    }

    func testAfterSentenceEnd() {
        XCTAssertEqual(InsertionPlanner.fit("see you then.", into: InsertionContext(before: "Thanks. ", after: nil)), "See you then.")
        XCTAssertEqual(InsertionPlanner.fit("see you then.", into: InsertionContext(before: "Thanks.", after: nil)), " See you then.")
    }

    func testBeforeExistingWordAndPeriod() {
        XCTAssertEqual(InsertionPlanner.fit("really", into: InsertionContext(before: "It is ", after: "good")), "really ")
        XCTAssertEqual(InsertionPlanner.fit("Done.", into: InsertionContext(before: "", after: ".")), "Done")
    }

    func testNoSpaceAfterOpener() {
        XCTAssertEqual(InsertionPlanner.fit("note", into: InsertionContext(before: "(", after: ")")), "note")
    }

    func testChinese() {
        XCTAssertEqual(InsertionPlanner.fit("北京", into: InsertionContext(before: "我想去", after: "")), "北京")
    }
}

final class RoutingTests: XCTestCase {
    private func availability(onDevice: Bool = true, installed: Bool = true, paired: Bool = false, reachable: Bool = false, cloud: Bool = false, network: Bool = true) -> RouteAvailability {
        RouteAvailability(onDeviceSupported: onDevice, onDeviceInstalled: installed, computerPaired: paired, computerReachable: reachable, cloudConfigured: cloud, networkAvailable: network)
    }

    func testAutomaticPrefersOnDevice() {
        let d = RouteSelector.select(preference: .automatic, allowCloudFallback: true, availability: availability(paired: true, reachable: true, cloud: true))
        XCTAssertEqual(d.route, .onDevice)
        XCTAssertFalse(d.fellBack)
    }

    func testAutomaticNeverUsesCloudWithoutPermission() {
        let d = RouteSelector.select(preference: .automatic, allowCloudFallback: false, availability: availability(onDevice: false, cloud: true))
        XCTAssertNil(d.route)
        let allowed = RouteSelector.select(preference: .automatic, allowCloudFallback: true, availability: availability(onDevice: false, cloud: true))
        XCTAssertEqual(allowed.route, .cloud)
        XCTAssertTrue(allowed.fellBack)
    }

    func testFallsBackToComputerBeforeCloud() {
        let d = RouteSelector.select(preference: .onDevice, allowCloudFallback: true, availability: availability(onDevice: false, paired: true, reachable: true, cloud: true))
        XCTAssertEqual(d.route, .myComputer)
        XCTAssertTrue(d.fellBack)
    }

    func testModelDownloadNeedsNetwork() {
        let online = RouteSelector.select(preference: .onDevice, allowCloudFallback: false, availability: availability(installed: false))
        XCTAssertEqual(online.route, .onDevice)
        XCTAssertTrue(online.needsModelDownload)
        let offline = RouteSelector.select(preference: .onDevice, allowCloudFallback: false, availability: availability(installed: false, network: false))
        XCTAssertNil(offline.route)
        XCTAssertTrue(offline.explanation.contains("offline"))
    }

    func testExplicitCloudFallsBackToMorePrivateRoutesWhenOffline() {
        let d = RouteSelector.select(preference: .cloud, allowCloudFallback: false, availability: availability(cloud: true, network: false))
        XCTAssertEqual(d.route, .onDevice)
        XCTAssertTrue(d.fellBack)
    }
}

final class SessionMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testStartRequiresForegroundWhenInactive() {
        var machine = SessionMachine()
        let request = DictationRequest(modeID: "message")
        XCTAssertEqual(machine.handle(.start(request), now: t0), [.requireForeground(request)])
    }

    func testFullDictationCycle() {
        var machine = SessionMachine(config: .init(warmDuration: 300))
        let request = DictationRequest(modeID: "message")
        XCTAssertEqual(machine.handle(.activate, now: t0), [.startAudio])
        XCTAssertEqual(machine.phase, .warm)
        XCTAssertEqual(machine.handle(.start(request), now: at(1)), [.beginCapture(request)])
        XCTAssertEqual(machine.phase, .listening)
        XCTAssertEqual(machine.handle(.stop(request.id), now: at(5)), [.finishCapture(request.id)])
        XCTAssertEqual(machine.phase, .finishing)
        XCTAssertEqual(machine.handle(.finished(request.id), now: at(6)), [])
        XCTAssertEqual(machine.phase, .warm)
        XCTAssertEqual(machine.warmUntil, at(306))
    }

    func testWarmSessionExpires() {
        var machine = SessionMachine(config: .init(warmDuration: 120))
        _ = machine.handle(.activate, now: t0)
        XCTAssertEqual(machine.handle(.tick, now: at(119)), [])
        XCTAssertEqual(machine.handle(.tick, now: at(121)), [.stopAudio])
        XCTAssertEqual(machine.phase, .inactive)
    }

    func testZeroWarmDurationStopsAfterEachDictation() {
        var machine = SessionMachine(config: .init(warmDuration: 0))
        let request = DictationRequest(modeID: "note")
        _ = machine.handle(.activate, now: t0)
        _ = machine.handle(.start(request), now: at(1))
        _ = machine.handle(.stop(request.id), now: at(2))
        XCTAssertEqual(machine.handle(.finished(request.id), now: at(3)), [.stopAudio])
        XCTAssertEqual(machine.phase, .inactive)
    }

    func testCancelDiscards() {
        var machine = SessionMachine()
        let request = DictationRequest(modeID: "message")
        _ = machine.handle(.activate, now: t0)
        _ = machine.handle(.start(request), now: at(1))
        XCTAssertEqual(machine.handle(.cancel(request.id), now: at(2)), [.abortCapture(request.id)])
        XCTAssertEqual(machine.phase, .warm)
        XCTAssertNil(machine.activeRequest)
    }

    func testNewRequestSupersedesStaleOne() {
        var machine = SessionMachine()
        let old = DictationRequest(modeID: "message")
        let new = DictationRequest(modeID: "message")
        _ = machine.handle(.activate, now: t0)
        _ = machine.handle(.start(old), now: at(1))
        XCTAssertEqual(machine.handle(.start(new), now: at(2)), [.abortCapture(old.id), .beginCapture(new)])
        XCTAssertEqual(machine.activeRequest, new)
    }

    func testBusyWhileFinishing() {
        var machine = SessionMachine()
        let first = DictationRequest(modeID: "message")
        let second = DictationRequest(modeID: "message")
        _ = machine.handle(.activate, now: t0)
        _ = machine.handle(.start(first), now: at(1))
        _ = machine.handle(.stop(first.id), now: at(2))
        let effects = machine.handle(.start(second), now: at(2.1))
        guard case let .fail(id, error)? = effects.first else { return XCTFail("expected busy") }
        XCTAssertEqual(id, second.id)
        XCTAssertEqual(error.code, .busy)
    }

    func testInterruptionFinishesWhatWasHeardThenStops() {
        var machine = SessionMachine()
        let request = DictationRequest(modeID: "message")
        _ = machine.handle(.activate, now: t0)
        _ = machine.handle(.start(request), now: at(1))
        XCTAssertEqual(machine.handle(.audioInterrupted, now: at(3)), [.finishCapture(request.id)])
        XCTAssertEqual(machine.handle(.finished(request.id), now: at(4)), [.stopAudio])
        XCTAssertEqual(machine.phase, .inactive)
    }

    func testMaxUtteranceAndFinishTimeout() {
        var machine = SessionMachine(config: .init(warmDuration: 300, maxUtterance: 60, finishTimeout: 10))
        let request = DictationRequest(modeID: "message")
        _ = machine.handle(.activate, now: t0)
        _ = machine.handle(.start(request), now: at(1))
        XCTAssertEqual(machine.handle(.tick, now: at(61)), [.finishCapture(request.id)])
        let effects = machine.handle(.tick, now: at(72))
        XCTAssertEqual(effects.first, .abortCapture(request.id))
        XCTAssertEqual(machine.phase, .warm)
    }

    func testEndSessionWhileFinishingWaitsForResult() {
        var machine = SessionMachine()
        let request = DictationRequest(modeID: "message")
        _ = machine.handle(.activate, now: t0)
        _ = machine.handle(.start(request), now: at(1))
        _ = machine.handle(.stop(request.id), now: at(2))
        XCTAssertEqual(machine.handle(.endSession, now: at(2.5)), [])
        XCTAssertEqual(machine.handle(.finished(request.id), now: at(3)), [.stopAudio])
    }

    func testAccumulator() {
        var acc = TranscriptAccumulator()
        acc.apply("Hello", isFinal: false)
        XCTAssertEqual(acc.current, "Hello")
        acc.apply("Hello there", isFinal: true)
        acc.apply("how are", isFinal: false)
        XCTAssertEqual(acc.current, "Hello there how are")
        acc.apply("how are you", isFinal: true)
        XCTAssertEqual(acc.current, "Hello there how are you")
        XCTAssertEqual(acc.volatile, "")
    }
}

final class BridgeTests: XCTestCase {
    func testQueueSequencingAndPruning() {
        var queue = CommandQueue()
        let request = DictationRequest(modeID: "message")
        let a = queue.append(.start(request))
        let b = queue.append(.stop(requestID: request.id))
        XCTAssertEqual(a.seq, 1)
        XCTAssertEqual(b.seq, 2)
        XCTAssertEqual(queue.pending(after: 1).map(\.seq), [2])
        queue.prune(processedThrough: 1)
        XCTAssertEqual(queue.commands.map(\.seq), [2])
        queue.append(.keepWarm)
        XCTAssertEqual(queue.commands.last?.seq, 3)
    }

    func testQueueDropsStaleCommands() {
        var queue = CommandQueue()
        let old = Date(timeIntervalSince1970: 0)
        queue.append(.keepWarm, now: old)
        queue.prune(processedThrough: 0, now: old.addingTimeInterval(500))
        XCTAssertTrue(queue.commands.isEmpty)
    }

    func testQueueIsBounded() {
        var queue = CommandQueue()
        for _ in 0..<100 { queue.append(.keepWarm) }
        XCTAssertEqual(queue.commands.count, 64)
        XCTAssertEqual(queue.commands.last?.seq, 100)
    }

    func testRoundTripCodable() throws {
        var queue = CommandQueue()
        // Whole-second dates round-trip exactly through the seconds-since-1970 encoding.
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let request = DictationRequest(modeID: "email", languageCode: "en-US", field: FieldTraits(keyboardType: "default", returnKeyType: "send", textContentType: nil), createdAt: fixed)
        queue.append(.start(request), now: fixed)
        queue.append(.rewrite(RewriteJob(action: .instruct("friendlier"), text: "hi")), now: fixed)
        queue.append(.askGOD(GODHandoff(text: "summarize this", createdAt: fixed)), now: fixed)
        let decoded = try BridgeCodec.decode(CommandQueue.self, from: BridgeCodec.encode(queue))
        XCTAssertEqual(decoded, queue)

        let status = HostStatus(heartbeat: Date(), phase: .listening, warmUntil: Date().addingTimeInterval(60), lastProcessedSeq: 3, activeRequestID: request.id, level: 0.4, partialText: "hel", route: .onDevice)
        let decodedStatus = try BridgeCodec.decode(HostStatus.self, from: BridgeCodec.encode(status))
        XCTAssertEqual(decodedStatus.phase, .listening)
        XCTAssertEqual(decodedStatus.activeRequestID, request.id)
        XCTAssertEqual(decodedStatus.heartbeat.timeIntervalSince1970, status.heartbeat.timeIntervalSince1970, accuracy: 0.001)
    }

    func testWarmDetection() {
        let now = Date()
        var status = HostStatus(heartbeat: now.addingTimeInterval(-1), phase: .warm, warmUntil: now.addingTimeInterval(30))
        XCTAssertTrue(status.canStartInPlace(at: now))
        status.heartbeat = now.addingTimeInterval(-10)
        XCTAssertFalse(status.canStartInPlace(at: now), "a stale heartbeat means the app was suspended")
        status.heartbeat = now
        status.warmUntil = now.addingTimeInterval(-1)
        XCTAssertFalse(status.canStartInPlace(at: now))
        status.phase = .inactive
        XCTAssertFalse(status.isAlive(at: now))
    }

    func testResultsExpire() {
        let now = Date()
        var status = HostStatus()
        status.outcome = DictationOutcome(requestID: UUID(), text: "secret", route: .onDevice, duration: 2, completedAt: now.addingTimeInterval(-61), error: nil)
        status.expireResults(now: now)
        XCTAssertNil(status.outcome)
    }

    func testDeepLinks() {
        let id = UUID()
        XCTAssertEqual(HarnessLink.parse(HarnessLink.url(for: .dictate(requestID: id))), .dictate(requestID: id))
        XCTAssertEqual(HarnessLink.parse(HarnessLink.url(for: .askGOD(handoffID: id))), .askGOD(handoffID: id))
        XCTAssertEqual(HarnessLink.parse(HarnessLink.url(for: .dictationTab(section: "setup"))), .dictationTab(section: "setup"))
        XCTAssertNil(HarnessLink.parse(URL(string: "https://example.com")!))
        XCTAssertNil(HarnessLink.parse(URL(string: "harness://god/ask")!))
    }
}

final class AudioAndAPITests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(AudioLevel.rms([0, 0, 0]), 0)
        XCTAssertEqual(AudioLevel.rms([1, -1, 1, -1]), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.normalized(rms: 0.0001), 0)
        XCTAssertEqual(AudioLevel.normalized(rms: 1), 1)
        var smoother = LevelSmoother()
        XCTAssertGreaterThan(smoother.push(1), 0.5)
    }

    func testSilenceDetector() {
        var detector = SilenceDetector(threshold: 0.2, requiredDuration: 1.5)
        XCTAssertFalse(detector.push(level: 0.0, at: 0), "silence before speech doesn't count")
        XCTAssertFalse(detector.push(level: 0.0, at: 5))
        XCTAssertFalse(detector.push(level: 0.6, at: 6))
        XCTAssertFalse(detector.push(level: 0.05, at: 6.5))
        XCTAssertFalse(detector.push(level: 0.05, at: 7.0))
        XCTAssertTrue(detector.push(level: 0.05, at: 8.1))
    }

    func testWAVHeader() {
        let wav = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
    }

    func testEndpointURLs() {
        func url(_ s: String) -> String {
            TranscriptionEndpoint(name: "x", baseURL: URL(string: s)!, model: "m", credentialID: nil).transcriptionsURL.absoluteString
        }
        XCTAssertEqual(url("https://api.openai.com"), "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(url("https://api.groq.com/openai/v1"), "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(url("http://192.168.1.20:8080/v1/audio/transcriptions"), "http://192.168.1.20:8080/v1/audio/transcriptions")
    }

    func testMultipartRequest() throws {
        let endpoint = TranscriptionEndpoint(name: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!, model: "whisper-large-v3-turbo", credentialID: "groq")
        let request = try TranscriptionAPI.makeRequest(endpoint: endpoint, wav: Data([1, 2, 3]), languageCode: "en-US", vocabularyPrompt: "Vocabulary: OpenRouter.", bearerToken: "sk-test", boundary: "B")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen\r\n"))
        XCTAssertTrue(body.contains("filename=\"dictation.wav\""))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    func testRejectsPlainHTTPToPublicHosts() {
        let endpoint = TranscriptionEndpoint(name: "bad", baseURL: URL(string: "http://example.com")!, model: "m", credentialID: nil)
        XCTAssertThrowsError(try TranscriptionAPI.makeRequest(endpoint: endpoint, wav: Data(), languageCode: nil, vocabularyPrompt: nil, bearerToken: nil)) { error in
            XCTAssertEqual(error as? TranscriptionAPIError, .insecureEndpoint)
        }
        let lan = TranscriptionEndpoint(name: "mac", baseURL: URL(string: "http://10.0.0.5:9000")!, model: "m", credentialID: nil)
        XCTAssertNoThrow(try TranscriptionAPI.makeRequest(endpoint: lan, wav: Data(), languageCode: nil, vocabularyPrompt: nil, bearerToken: nil))
    }

    func testParsesResponses() throws {
        XCTAssertEqual(try TranscriptionAPI.parse(data: Data(#"{"text":"hello"}"#.utf8), statusCode: 200), "hello")
        XCTAssertEqual(try TranscriptionAPI.parse(data: Data("plain text".utf8), statusCode: 200), "plain text")
        XCTAssertThrowsError(try TranscriptionAPI.parse(data: Data(#"{"error":{"message":"bad key"}}"#.utf8), statusCode: 401)) { error in
            XCTAssertEqual(error as? TranscriptionAPIError, .http(status: 401, message: "bad key"))
        }
    }

    func testTooLargeAudio() {
        let endpoint = TranscriptionEndpoint(name: "x", baseURL: URL(string: "https://x.ai")!, model: "m", credentialID: nil)
        let big = Data(count: TranscriptionAPI.maxUploadBytes + 1)
        XCTAssertThrowsError(try TranscriptionAPI.makeRequest(endpoint: endpoint, wav: big, languageCode: nil, vocabularyPrompt: nil, bearerToken: nil))
    }
}

final class RewriteAndSettingsTests: XCTestCase {
    func testSanitizerStripsWrappers() throws {
        XCTAssertEqual(try RewriteOutputSanitizer.clean("Sure! Here's the edited text:\nSee you at 5.", original: "see you at 5"), "See you at 5.")
        XCTAssertEqual(try RewriteOutputSanitizer.clean("\"See you at 5.\"", original: "see you at 5"), "See you at 5.")
        XCTAssertEqual(try RewriteOutputSanitizer.clean("```\nfixed\n```", original: "fixd"), "fixed")
        XCTAssertEqual(try RewriteOutputSanitizer.clean("\"quoted\"", original: "\"quoted\""), "\"quoted\"")
    }

    func testSanitizerRejectsBadOutput() {
        XCTAssertThrowsError(try RewriteOutputSanitizer.clean("   ", original: "hi"))
        XCTAssertThrowsError(try RewriteOutputSanitizer.clean("I can't help with that.", original: "hi"))
        XCTAssertThrowsError(try RewriteOutputSanitizer.clean(String(repeating: "word ", count: 200), original: "hi"))
    }

    func testInstructionsMentionMode() {
        let mode = DictationMode(id: "agent", name: "Agent", style: .custom, instruction: "Warm, brief, no emoji", aiPolish: true)
        let text = RewritePromptBuilder.instructions(for: .rewrite(modeID: "agent"), modes: [mode])
        XCTAssertTrue(text.contains("Warm, brief, no emoji"))
        XCTAssertTrue(RewritePromptBuilder.instructions(for: .fix, modes: []).contains("change as little as possible"))
    }

    func testSettingsRoundTripAndDefaults() {
        let settings = DictationSettings()
        XCTAssertFalse(settings.allowCloudFallback, "cloud must be opt-in")
        XCTAssertFalse(settings.historyEnabled, "history must be opt-in")
        XCTAssertEqual(DictationSettings.decode(settings.encoded()), settings)
        XCTAssertEqual(DictationSettings.decode(nil), DictationSettings())
    }

    func testSettingsSalvageKeepsDictionary() throws {
        let json = #"{"dictionary":{"entries":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","written":"HOA","soundsLike":[]}]},"routePreference":"bogus"}"#
        let settings = DictationSettings.decode(Data(json.utf8))
        XCTAssertEqual(settings.dictionary.entries.first?.written, "HOA")
        XCTAssertEqual(settings.routePreference, .automatic)
    }

    func testSettingsMigrationRestoresBuiltIns() throws {
        var settings = DictationSettings()
        settings.modes = [DictationMode.message]
        settings.warmSessionMinutes = 999
        let migrated = DictationSettings.decode(settings.encoded())
        XCTAssertEqual(Set(migrated.modes.map(\.id)), Set(DictationMode.builtIns.map(\.id)))
        XCTAssertEqual(migrated.warmSessionMinutes, 60)
    }

    func testModeSuggester() {
        XCTAssertEqual(ModeSuggester.suggest(for: FieldTraits(keyboardType: "emailAddress"), userDefaultModeID: "note").modeID, "verbatim")
        XCTAssertEqual(ModeSuggester.suggest(for: FieldTraits(returnKeyType: "send"), userDefaultModeID: "note").modeID, "message")
        XCTAssertEqual(ModeSuggester.suggest(for: FieldTraits(textContentType: "oneTimeCode"), userDefaultModeID: "note").allowsAIPolish, false)
        XCTAssertEqual(ModeSuggester.suggest(for: nil, userDefaultModeID: "note").modeID, "note")
    }

    func testHistoryRetention() {
        let now = Date()
        var history = TranscriptHistory()
        history.add(.init(text: "old", modeID: "message", route: .onDevice, createdAt: now.addingTimeInterval(-9 * 86_400)), retentionDays: 7, now: now)
        history.add(.init(text: "new", modeID: "message", route: .onDevice, createdAt: now), retentionDays: 7, now: now)
        history.add(.init(text: "  ", modeID: "message", route: .onDevice, createdAt: now), retentionDays: 7, now: now)
        XCTAssertEqual(history.entries.map(\.text), ["new"])
        XCTAssertEqual(history.search("NEW").count, 1)
    }
}
