// The Harness Keyboard extension. All behavior lives in HarnessKeyboardKit
// (Packages/HarnessDictation); this target only names the App Group.
import HarnessKeyboardKit

final class KeyboardViewController: HarnessKeyboardViewController {
    // Must match com.apple.security.application-groups in both targets' entitlements.
    override var appGroupIdentifier: String { "group.org.harness.ios" }
}
