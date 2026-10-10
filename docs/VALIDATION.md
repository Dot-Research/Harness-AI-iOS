# Validation and remaining device checks

Validated in the Linux workspace on October 6, 2026 (America/Los_Angeles):

- 55 portable Swift core tests pass.
- 23 Python companion tests pass, including local TLS and pairing checks.
- All native Swift sources pass syntax parsing with Swift 6.2. This does not typecheck Apple's frameworks.
- Native source references, shared Xcode scheme, Info.plist, and privacy manifest were inspected for project consistency.
- JavaScript syntax and the portable single-file interface preview render successfully.
- Browser interaction checks cover tabs, compact/expanded switching without losing drafts or messages, deterministic chat examples, learning save/edit/reject, Journey revert, agent file editing, skill installation/fork edits, dialog keyboard controls, and narrow layouts down to 320 CSS pixels.
- Browser inspection found no external requests or uncaught JavaScript errors. Preview changes stay in memory and reset on reload.

Run core and companion checks with `bash scripts/check.sh`. Build the portable preview with `python3 scripts/build-preview.py`.

## Required on a Mac and supported devices

No native iOS binary was built or installed in this workspace. Linux has no Apple SDK, SwiftUI typechecker, iOS simulator, or Foundation Models runtime. Xcode build success, actual Apple model generation, Keychain/biometric/camera behavior, and physical iPhone 18/Duo behavior remain unverified.

1. Open `iOS/Harness.xcodeproj` in an Xcode version supporting the device OS. Set a signing team and unique bundle ID, then build the shared Harness scheme.
2. Exercise compact and expanded widths, rotation, keyboard clearance, accessibility text sizes, and VoiceOver. Preserve a draft while changing width.
3. Test Apple Intelligence enabled/disabled/model-not-ready states. Generate a real local response, cancel it, and try a context-limit failure. Confirm no cloud fallback in local-only mode.
4. Verify separate Apple availability in Providers even when a cloud route is selected.
5. Review and revert learned preferences; validate scoped permissions and denied requests without transmission.
6. Pair a computer and verify expiry, replay rejection, certificate mismatch, capability revocation, and device authentication.

The current Apple adapter offers text generation and local learning review. It does not execute Harness tools; tool orchestration needs a compatible local or cloud endpoint. HomeKit, Notes/Messages integrations, public Red service, and App Store release work remain outside this MVP. The dictation keyboard's device checks are in [Packages/HarnessDictation/docs/QA_CHECKLIST.md](../Packages/HarnessDictation/docs/QA_CHECKLIST.md). An app icon and release/device verification are still required.
