import XCTest
@testable import DictationCore

final class SubscriptionAccessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let productID = "test.subscription"

    func testEmptyConfigurationCannotGrantAccess() {
        let state = SubscriptionEntitlementPolicy.evaluate(productIDs: [], transactions: [receipt(expiration: 600)], now: now)
        XCTAssertEqual(state, .unconfigured)
        XCTAssertFalse(state.access(at: now).isAllowed)
    }

    func testOnlyConfiguredUnexpiredSubscriptionGrantsAccess() {
        let unrelated = VerifiedSubscription(productID: "other.subscription", expiration: now.addingTimeInterval(600))
        XCTAssertEqual(evaluate([unrelated]), .notSubscribed)
        let state = evaluate([receipt(expiration: 600)])
        XCTAssertTrue(state.access(at: now).isAllowed)
        XCTAssertFalse(state.access(at: now.addingTimeInterval(600)).isAllowed)
    }

    func testExpiredRevokedAndUpgradedTransactionsDoNotGrantAccess() {
        XCTAssertEqual(evaluate([receipt(expiration: -1)]), .expired(now.addingTimeInterval(-1)))
        let revoked = VerifiedSubscription(productID: productID, expiration: now.addingTimeInterval(600), revocation: now)
        XCTAssertEqual(evaluate([revoked]), .revoked)
        let upgraded = VerifiedSubscription(productID: productID, expiration: now.addingTimeInterval(600), isUpgraded: true)
        XCTAssertEqual(evaluate([upgraded]), .notSubscribed)
    }

    func testFailedVerificationNeverBecomesPaidAccess() {
        let state = SubscriptionEntitlementPolicy.evaluate(productIDs: [productID], transactions: [], hadVerificationFailure: true, now: now)
        XCTAssertEqual(state, .verificationFailed)
        XCTAssertFalse(state.access(at: now).isAllowed)
        XCTAssertFalse(SubscriptionAccessState.checking.access(at: now).isAllowed)
    }

    func testValidRenewalWinsOverExpiredHistoryAndExpiresAtBoundary() {
        let state = evaluate([receipt(expiration: -10), receipt(expiration: 500), receipt(expiration: 50)])
        XCTAssertEqual(state, .active(productID: productID, expiration: now.addingTimeInterval(500)))
        XCTAssertTrue(state.access(at: now.addingTimeInterval(499)).isAllowed)
        XCTAssertFalse(state.access(at: now.addingTimeInterval(500)).isAllowed)
    }

    func testVerifiedBillingGraceExtendsAccessOnlyUntilItsEnd() {
        let receipt = VerifiedSubscription(productID: productID, expiration: now.addingTimeInterval(-1), graceExpiration: now.addingTimeInterval(120))
        let state = evaluate([receipt])
        XCTAssertTrue(state.access(at: now).isAllowed)
        XCTAssertFalse(state.access(at: now.addingTimeInterval(120)).isAllowed)
    }

    func testDeniedActivationCannotStartMicrophone() {
        var machine = SessionMachine()
        let effects = machine.handle(.activate, now: now, access: .denied("Subscription required"))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(machine.phase, .inactive)
    }

    func testBothAppAndKeyboardStartsFailBeforeForegroundOrCapture() {
        for origin in [DictationRequest.Origin.app, .keyboard] {
            var machine = SessionMachine()
            let request = DictationRequest(modeID: "message", origin: origin)
            let effects = machine.handle(.start(request), now: now, access: .denied("Subscription required"))
            XCTAssertEqual(effects, [.fail(request.id, BridgeError(.subscriptionRequired, "Subscription required"))])
            XCTAssertEqual(machine.phase, .inactive)
        }
    }

    func testWarmKeyboardCannotBypassRevocation() {
        var machine = SessionMachine()
        _ = machine.handle(.activate, now: now)
        let request = DictationRequest(modeID: "message", origin: .keyboard)
        let effects = machine.handle(.start(request), now: now, access: .denied("Access revoked"))
        XCTAssertEqual(effects, [.stopAudio, .fail(request.id, BridgeError(.subscriptionRequired, "Access revoked"))])
        XCTAssertEqual(machine.phase, .inactive)
    }

    func testRevocationDuringRecordingFailsRequestAndStopsAudio() {
        var machine = SessionMachine()
        let request = DictationRequest(modeID: "message", origin: .app)
        _ = machine.handle(.activate, now: now)
        _ = machine.handle(.start(request), now: now)
        let effects = machine.handle(.tick, now: now, access: .denied("Access expired"))
        XCTAssertEqual(effects, [.fail(request.id, BridgeError(.subscriptionRequired, "Access expired")), .abortCapture(request.id), .stopAudio])
        XCTAssertEqual(machine.phase, .inactive)
        XCTAssertNil(machine.activeRequest)
    }

    func testInjectedAllowedDecisionPreservesDictationCycle() {
        var machine = SessionMachine()
        let request = DictationRequest(modeID: "message")
        XCTAssertEqual(machine.handle(.activate, now: now, access: .allowed), [.startAudio])
        XCTAssertEqual(machine.handle(.start(request), now: now, access: .allowed), [.beginCapture(request)])
    }

    private func receipt(expiration: TimeInterval) -> VerifiedSubscription {
        VerifiedSubscription(productID: productID, expiration: now.addingTimeInterval(expiration))
    }

    private func evaluate(_ transactions: [VerifiedSubscription]) -> SubscriptionAccessState {
        SubscriptionEntitlementPolicy.evaluate(productIDs: [productID], transactions: transactions, now: now)
    }
}
