---
name: run-harness-ios
description: Build, install, run and drive the Harness iOS app and the Harness Keyboard extension on an iOS 26 simulator, and take screenshots. Use when asked to run/launch/start the app, test or screenshot the keyboard (typing layer, shift/caps lock, 123/#+=, double-space, return key titles, waveform toggle, Full Access, Fix/Rewrite/Ask, rewrite timeout), enable the keyboard in Settings, check Speak subscription states, or verify an iOS change in the real app. Also covers driving it from a Linux container through the macOS CI workflow.
---

# Run Harness (iOS app + Harness Keyboard)

Paths are relative to the repo root. The driver is
`.claude/skills/run-harness-ios/sim.sh` (macOS + Xcode 26). It builds the
app ad-hoc signed for a dedicated iOS 26 simulator, enables the keyboard, and
runs **XCUITest flows** from `driver/`. That's a tiny **FieldLab** fixture app
(text fields with known traits: `plain`, `notes`, `email`, `send`, `search`,
`url`) plus `KeyboardDriverUITests`. Screenshots are XCTest attachments,
exported to `.build/harness-sim/shots/<name>.png`.

**On Linux (cloud agents): there is no Xcode, and swift.org is blocked by the
proxy.** Drive it through `.github/workflows/simulator-drive.yml` (see "Run from
a Linux container" below). That workflow is how everything here was verified
(Xcode 26.6, iOS 26.5 runtime, iPhone 17 Pro, `macos-26` runner).

## Run (agent path, on a Mac)

```sh
S=.claude/skills/run-harness-ios/sim.sh
$S boot                                   # creates + boots "Harness iPhone" (newest iOS 26 runtime), ~2 min first time
$S build --product-ids org.harness.ios.speak.monthly   # ~4 min; omit --product-ids for "unconfigured" subscriptions
$S install
$S entitlements                           # both binaries list group.org.harness.ios + the group container path
$S driver                                 # generates + builds FieldLab and the UI tests, installs FieldLab
$S keyboard-prefs                         # Harness in Settings > General > Keyboard > Keyboards (no UI), reboots the sim
$S test TypingLayerTests                  # typing-layer flows, works without Full Access
$S test FullAccessTests/testDictationPanelReflectsFullAccess -- EXPECT_FULL_ACCESS=0
$S keyboard --full-access                 # drives Settings: Harness > Allow Full Access > Allow
$S test FullAccessTests -- EXPECT_FULL_ACCESS=1
$S test SubscriptionTests
$S launch                                 # start Harness (sim.sh launch <url> opens a harness:// link instead)
$S shot my-name                           # simctl screenshot to .build/harness-sim/shots/my-name.png
$S ci                                     # all of the above, in order
```

`test <Class[/method]>… [-- KEY=VALUE…]` runs `xcodebuild test-without-building`.
`KEY=VALUE` reaches the test process as an environment variable (sim.sh adds the
`TEST_RUNNER_` prefix). Logs and `.xcresult` bundles go to `.build/harness-sim/`.

### What each test drives

| Test | Flow (FieldLab field) | Screenshots |
|---|---|---|
| `TypingLayerTests/testShiftCapsLockPlanesAndDoubleSpace` | `plain`: auto-shift on empty field; "Hi" + double-space gives "Hi. " and shift on; shift once; double-tap caps lock; 123 → #+= → 123 → ABC. Final text `Hi. OkXAB1#` | `typing-01…06` |
| `…/testNewlineAutoCapitalizes` | `notes` (UITextView): `a`, Return, shift is on, `b` gives `A\nB` | `typing-07-newline` |
| `…/testEmailFieldKeys` | `email`: `@` and `.` beside space, no auto-capital, types `a@b.io` | `typing-08-email` |
| `…/testReturnKeyTitles` | return key reads send / search / go / Return; URL field has `/` | `typing-10-return-*` |
| `…/testWaveformToggleIsRemembered` | waveform key shows the dictation panel; still shown after FieldLab relaunch; back again | `toggle-01/02` |
| `FullAccessTests/testDictationPanelReflectsFullAccess` | "Turn on Full Access" card iff Full Access is off (`EXPECT_FULL_ACCESS=0/1`) | `access-01-*` |
| `FullAccessTests/testTextActionsDisabledWhileDictating` | type, tap Dictate, check Fix / Rewrite / Ask Harness are disabled | `dictating-*` |
| `FullAccessTests/testRewriteGivesUpWhenAppDoesNotAnswer` | Fix with no Apple Intelligence: hand-off to the app; if Harness never answers, the keyboard shows "Harness didn't finish the rewrite" and the text is unchanged | `rewrite-*` |
| `SettingsTests/testEnableHarnessKeyboard` | Settings > General > Keyboard > Keyboards (> Add New Keyboard… > Harness) > Harness > Allow Full Access, per `FULL_ACCESS=1/0` | `settings-*` |
| `SubscriptionTests` | Harness > Me > Harness subscription; reads the status title | `subscription-*` |

Add a flow: put a test method in `driver/UITests/*.swift` (helpers in
`Support.swift`: `focus(field)`, `showTypingLayer()`, `tap(label)`,
`typeLetters("text")`, `shot(name)`, `note(text)`), then `$S driver && $S test Class/method`.
Keys are found by accessibility label: letters by their shown text ("q" or "Q"),
`Shift`/`Caps lock` (value On/Off), `Numbers`, `More symbols`, `Letters`, `space`,
`Return` or the title (`send`…), `Show dictation panel` (waveform), `Show keyboard`,
`Dictate`, `Fix`, `Rewrite`, `Ask Harness`.

## Run from a Linux container (CI drive)

1. Push a change under `.claude/skills/run-harness-ios/` (or run the workflow by
   hand). `Simulator drive` runs `sim.sh ci` on `macos-26`, in about 35–40 min.
2. Artifact downloads (`gh run download`) fail here: the proxy blocks
   `*.blob.core.windows.net`. Read the logs with the GitHub MCP tool instead:
   `get_job_logs(job_id=<drive job>, return_content=true, tail_lines=6000)`.
   Big results are saved to a file, and the tool prints the path.
3. The `shots` job prints selected screenshots as base64 JPEGs (pick them with the
   `shots` input on a manual run). Fetch that job's log the same way and decode the
   saved file directly. The script unwraps the tool's `{"logs_content": …}` JSON:
   ```sh
   python3 .claude/skills/run-harness-ios/shots-from-log.py <saved log file> /tmp/shots
   ```
   Then look at the JPEGs with Read. Wait for a run with a background
   `until gh run list … | grep -q completed; do sleep 30; done`. `gh run list`/`view` work
   through the proxy; only logs and artifacts don't.

## Run (human path)

Open `iOS/Harness.xcodeproj` in Xcode, scheme **Harness**, pick an iOS 26 simulator, Run. For
active/expired subscription states, Xcode's own StoreKit testing (scheme > Run > Options >
StoreKit Configuration = `driver/Harness.storekit`) is the remaining route. Not verified here
(no Xcode IDE in CI).

## Verification status (last CI runs, Xcode 26.6 / iOS 26.5)

Passing: build + install + App Group, `keyboard-prefs`, `keyboard --full-access`,
`testShiftCapsLockPlanesAndDoubleSpace`, `testNewlineAutoCapitalizes`,
`testWaveformToggleIsRemembered`, `testDictationPanelReflectsFullAccess` (both with and without Full Access),
`SubscriptionTests` (shows "No active subscription"; the active/expired leg skips, see Gotchas).

Not yet passing when CI stopped (the org hit its Actions spending limit; the last commit's fixes
are unrun):
- `testEmailFieldKeys`: the Harness keyboard didn't come up in the email field. The globe cycled
  through emoji. Fixed by dropping emoji from `AppleKeyboards`. Unverified.
- `testReturnKeyTitles`: `send` was right, but `search` (webSearch field, opened right after the
  send field) wasn't. Possibly the keyboard reads the previous field's return key type when it
  reappears. The test now records every title (`note`) and screenshots `typing-10-return-*`.
  Check the next run before calling it a product bug.
- `testTextActionsDisabledWhileDictating`: after tapping Dictate, Fix/Rewrite/Ask weren't found
  and Harness didn't come to the foreground. See `dictating-01-after-dictate-tap`.
- `testRewriteGivesUpWhenAppDoesNotAnswer`: failed on typing a space (fixed: `typeLetters` taps
  `space`). Unverified.

## Gotchas

- **App Group without a team**: build with `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`,
  not `CODE_SIGNING_ALLOWED=NO`. Simulator builds keep entitlements in a Mach-O section, so
  `codesign -d --entitlements -` prints `{}` even when they're present. Check with
  `strings -a Harness.app/Harness | grep group.org.harness.ios` (what `sim.sh entitlements` does),
  plus `simctl get_app_container <udid> org.harness.ios group.org.harness.ios`.
- **Product IDs** are patched into the *built* `Info.plist` (`plutil -replace HarnessSubscriptionProductIDs`)
  and the app is re-signed ad-hoc. The checked-in `Info.plist` stays empty, which means "unconfigured".
- **Enabling the keyboard without UI**: `simctl spawn <udid> defaults write -g AppleKeyboards -array
  "en_US@sw=QWERTY;hw=Automatic" org.harness.ios.keyboard`, then **reboot the simulator**. Settings
  then shows "Keyboards, 2/3" with a Harness row. `AppleKeyboards` doesn't exist on a fresh simulator.
  Leave emoji out so the globe toggles straight between English and Harness.
- **Full Access is not in any plist or TCC.db row we could find**, so it's set through the Settings UI
  (`sim.sh keyboard --full-access`, ~35 s). On iOS 26 the General > Keyboard screen is titled
  "Keyboards" and its "Keyboards, N" row has identifier `KEYBOARDS`. Tapping by label hits the title.
- **The system keyboard's mic key is also labelled "Dictate."** Detect the Harness keyboard by
  `Ask Harness`, then cycle `Next keyboard` (globe) until it appears.
- **`descendants(matching: .any)["plain"]` matches FieldLab's caption text, not the field**, so
  nothing gets focus. Use `textFields[...]` / `textViews[...]`.
- **Without Full Access the keyboard opens on the typing layer**, and with it on the dictation panel.
  The choice is remembered per keyboard process in `UserDefaults.standard` (`harness.keyboard.showsKeys`),
  so tests call `showTypingLayer()` instead of assuming either.
- **StoreKit test sessions don't reach Harness headless.** `SKTestSession` created in the UI-test
  runner loads, but `buyProduct` throws `notEntitled`. A `StoreKitConfigurationFileReference` in
  the driver scheme applies to FieldLab, not to Harness, so Harness gets no products ("The App Store
  returned no subscription plans for this build"). `xcrun simctl` has no StoreKit commands
  (Xcode 26.6). Headless you can reach **unconfigured** (build without `--product-ids`),
  **checking** (briefly, at launch) and **No active subscription**. Active and expired need Xcode's
  Run with the `.storekit` file (human path). The access logic itself is covered by
  `SubscriptionEntitlementPolicy` unit tests in `Packages/HarnessDictation`.
- XCTest's automatic attachments ("Debug description for `"Dictate" Button`…") have quotes in their
  names and make `actions/upload-artifact` fail. `sim.sh` exports only attachments whose names start
  lowercase, and sanitizes them.
- Simulator boot plus Harness build is ~6 min of every CI run. Tests take 10–90 s each (Settings ~35 s).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Harness keyboard did not appear` and the screenshot shows the Apple keyboard | Run `sim.sh keyboard-prefs` (reboots). Check `simctl spawn <udid> defaults read -g AppleKeyboards`. |
| Screenshot shows FieldLab with no keyboard at all | The tap missed the field (see the caption gotcha), or a hardware keyboard is connected: `defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false` (sim.sh boot does this). |
| `Settings: no Add New Keyboard…` | You're on the wrong screen. Read the attached `settings-tree-*.txt` (printed in the CI "Results" step). |
| `cannot assign to property: 'view' is immutable` building FieldLab | `UITextInputTraits` properties are optional requirements and can't be set through `UIView & UITextInputTraits`. Set them on the concrete `UITextField`/`UITextView`. |
| `call to main actor-isolated instance method … in a synchronous nonisolated context` | Mark XCUITest helpers and test methods that call them `@MainActor`. |
| `caught error: "notEntitled"` in SubscriptionTests | Expected: see the StoreKit gotcha. |
| `gh run download` / `gh run view --log`: `Forbidden` | The proxy blocks GitHub's blob storage. Use the MCP `get_job_logs` route above. |
| Run fails in ~15 s with no steps; annotation "recent account payments have failed or your spending limit needs to be increased" | Org billing for macOS Actions minutes. Nothing to fix in the repo; ask an org owner. |
| `get_job_logs` returns HTTP 404 for the `shots` job | That job never got a runner (no steps). Rerun, or rely on the drive job's text results. |
