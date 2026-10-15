import StoreKitTest
import XCTest

/// Speak subscription states, read from Harness → Me → Harness subscription.
/// Harness must be built with HarnessSubscriptionProductIDs = org.harness.ios.speak.monthly
/// (`sim.sh build --product-ids org.harness.ios.speak.monthly`), else it shows "Subscription setup unavailable".
final class SubscriptionTests: XCTestCase {
    let harness = XCUIApplication(bundleIdentifier: "org.harness.ios")
    let productID = "org.harness.ios.speak.monthly"

    /// What the app shows right now, with no StoreKit test session.
    @MainActor func testShowState() {
        launchToSubscription()
        attach("subscription-\(statusTitle())")
    }

    /// Drives checking → active → expired with an SKTestSession from Harness.storekit.
    /// The purchase goes through Harness's own Subscribe button (buyProduct from the test runner
    /// throws notEntitled); the session then expires it.
    func testCheckingActiveExpired() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Harness", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()

        await MainActor.run { launchToSubscription() }
        await MainActor.run { attach("subscription-1-\(statusTitle())") }

        let bought: Bool = await MainActor.run {
            let subscribe = harness.buttons["Subscribe"].firstMatch
            guard subscribe.waitForExistence(timeout: 10) else {
                note("no Subscribe button: Harness got no products from StoreKit")
                return false
            }
            subscribe.tap()
            // With dialogs enabled StoreKit shows a sheet; confirm whatever it offers.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["Subscribe", "Confirm", "Purchase", "OK"] {
                let button = springboard.buttons[label].firstMatch
                if button.waitForExistence(timeout: 3) { button.tap() }
            }
            waitForTitle(["Subscription active"], timeout: 30)
            attach("subscription-2-\(statusTitle())")
            return true
        }
        guard bought else { return }

        do { try session.expireSubscription(productIdentifier: productID) }
        catch { await MainActor.run { note("expireSubscription: \(error)") } }
        await MainActor.run {
            harness.terminate()
            launchToSubscription()
            waitForTitle(["Subscription expired"], timeout: 30)
            attach("subscription-3-\(statusTitle())")
        }
    }

    @MainActor func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "note"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("NOTE:", text)
    }

    // MARK: Helpers

    static let titles = ["Subscription setup unavailable", "Checking your subscription", "No active subscription",
                         "Subscription active", "Subscription expired", "Subscription access revoked", "Subscription not verified"]

    @MainActor func launchToSubscription() {
        harness.launch()
        // Opening "Checking your subscription" is the state between launch and StoreKit's answer.
        let me = harness.tabBars.buttons["Me"].firstMatch
        XCTAssertTrue(me.waitForExistence(timeout: 15), harness.debugDescription)
        me.tap()
        let row = harness.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Harness subscription'")).firstMatch
        for _ in 0..<5 where !row.isHittable { harness.swipeUp() }
        row.tap()
        attach("subscription-0-\(statusTitle())")
    }

    @MainActor func statusTitle() -> String {
        for title in Self.titles where harness.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists {
            return title.replacingOccurrences(of: " ", with: "-")
        }
        return "unknown"
    }

    @MainActor func waitForTitle(_ titles: [String], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if titles.contains(where: { harness.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", $0)).firstMatch.exists }) { return }
            let check = harness.buttons["Check access again"].firstMatch
            if check.exists && check.isEnabled { check.tap() }
            sleep(2)
        }
        XCTFail("never showed \(titles); showing \(statusTitle())\n\(harness.debugDescription)")
    }

    @MainActor func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
