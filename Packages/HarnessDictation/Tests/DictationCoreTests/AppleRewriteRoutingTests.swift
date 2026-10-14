import XCTest
@testable import DictationCore

final class AppleRewriteRoutingTests: XCTestCase {
    func testOfflineRouteNeverSelectsCloudEvenWhenLocalModelIsUnavailable() {
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .localOnly, localAvailable: false, cloudAvailable: true, networkAllowed: true), [])
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .localOnly, localAvailable: true, cloudAvailable: true, networkAllowed: true), [.onDevice])
    }
    func testCloudRequiresExplicitRouteAndNetworkPermission() {
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .privateCloudOnly, localAvailable: true, cloudAvailable: true, networkAllowed: false), [])
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .privateCloudOnly, localAvailable: true, cloudAvailable: true, networkAllowed: true), [.privateCloud])
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .privateCloudOnly, localAvailable: true, cloudAvailable: false, networkAllowed: true), [])
    }
    func testOptedInFallbackTriesLocalFirstAndRespectsCloudAvailability() {
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .localWithCloudFallback, localAvailable: true, cloudAvailable: true, networkAllowed: true), [.onDevice, .privateCloud])
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .localWithCloudFallback, localAvailable: false, cloudAvailable: true, networkAllowed: true), [.privateCloud])
        XCTAssertEqual(AppleRewriteRouting.candidates(for: .localWithCloudFallback, localAvailable: true, cloudAvailable: false, networkAllowed: true), [.onDevice])
    }
    func testOlderSettingsKeepAllPreferencesAndDefaultToLocalRewrite() throws {
        var original = DictationSettings(warmSessionMinutes: 12, historyEnabled: true, historyRetentionDays: 21)
        original.languageCode = "zh-Hans"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
        json.removeValue(forKey: "appleRewriteRoute")
        let loaded = DictationSettings.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.warmSessionMinutes, 12)
        XCTAssertTrue(loaded.historyEnabled)
        XCTAssertEqual(loaded.languageCode, "zh-Hans")
        XCTAssertEqual(loaded.historyRetentionDays, 21)
        XCTAssertEqual(loaded.effectiveAppleRewriteRoute, .localOnly)
    }
}
