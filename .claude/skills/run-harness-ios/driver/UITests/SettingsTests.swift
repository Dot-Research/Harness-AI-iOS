import XCTest

/// Enables the Harness keyboard through the Settings app. Slow (~30 s) but needs nothing else;
/// `sim.sh keyboard` writes the same preferences directly. FULL_ACCESS=1 also allows Full Access.
final class SettingsTests: XCTestCase {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

    func testEnableHarnessKeyboard() {
        continueAfterFailure = false
        let fullAccess = ProcessInfo.processInfo.environment["FULL_ACCESS"] == "1"
        settings.terminate()
        settings.launch()
        open("General")
        open("Keyboard")
        open("KEYBOARDS")   // the "Keyboards, 3" row; the screen title is also "Keyboards"
        if !settings.staticTexts["Harness"].exists && !settings.buttons["Harness"].exists {
            open("Add New Keyboard…", alternatives: ["Add New Keyboard...", "Add New Keyboard"])
            open("Harness")
        }
        attach("settings-01-keyboards")
        // The Harness row in the Keyboards list.
        open("Harness")
        let toggle = settings.switches["Allow Full Access"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Allow Full Access switch")
        let isOn = (toggle.value as? String) == "1"
        if isOn != fullAccess {
            tapSwitch(toggle)
            if fullAccess {
                let allow = settings.alerts.buttons["Allow"].firstMatch
                if allow.waitForExistence(timeout: 5) { allow.tap() }
            }
        }
        attach("settings-02-full-access-\(fullAccess ? "on" : "off")")
        XCTAssertEqual(toggle.value as? String, fullAccess ? "1" : "0")
        settings.terminate()
    }

    /// Taps the Settings row whose label is `label` (or starts with "label,") or whose identifier is `label`.
    /// Cells and buttons only: navigation titles are StaticTexts with the same words.
    private func open(_ label: String, alternatives: [String] = []) {
        for candidate in [label] + alternatives {
            let predicate = NSPredicate(format: "(label == %@ OR label BEGINSWITH %@ OR identifier == %@) AND (elementType == %d OR elementType == %d)",
                                        candidate, candidate + ",", candidate, XCUIElement.ElementType.cell.rawValue, XCUIElement.ElementType.button.rawValue)
            let element = settings.descendants(matching: .any).matching(predicate).firstMatch
            for _ in 0..<6 {
                if element.waitForExistence(timeout: 1) && element.isHittable { break }
                settings.swipeUp()
            }
            if element.exists && element.isHittable { element.tap(); return }
        }
        let tree = XCTAttachment(string: tree())
        tree.name = "settings-tree-\(label.prefix(12)).txt"
        tree.lifetime = .keepAlways
        add(tree)
        attach("settings-missing")
        XCTFail("Settings: no \(label) (see settings-tree attachment)")
    }

    private func tapSwitch(_ toggle: XCUIElement) {
        // Tap the knob side; tapping the cell's center doesn't flip it on iOS 26.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func tree() -> String { settings.debugDescription }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
