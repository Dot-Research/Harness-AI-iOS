# Harness Dictation

The Dictation tab and the Harness Keyboard: a private, on-device alternative to Diction, Typeless,
Superwhisper and Wispr Flow, built to section 15 of the Harness spec.

> Dictate | Fix | Rewrite | Ask Harness. On-device first, then your own computer, then (only if you
> allow it) a cloud endpoint you choose. Audio is never saved.

## What it does

Compared with the iPhone dictation keyboards named in the spec. Competitor cells come from each
product's own docs or App Store page (see Sources); "—" means the page doesn't say. Checked 8 Oct 2026.

| | Harness | Typeless | Wispr Flow | Superwhisper | Diction |
|---|---|---|---|---|---|
| Where speech is transcribed | On the iPhone (Apple SpeechAnalyzer); or your paired computer; or a cloud endpoint you choose | Typeless cloud | Wispr servers | On-device or cloud models | On device, a self-hosted server, or Diction One cloud |
| Works offline | Yes, after a one-time model download | No (cloud only) | No (needs Wi-Fi or cellular) | With on-device models | In on-device mode |
| Audio | Never stored | Not stored | Discarded under Privacy Mode (enterprise; Android for individuals) | Stays on the phone with on-device models | Never leaves the device in on-device mode |
| Text history | Off by default, text only, expires after 1/7/30 days | On device; optional cloud sync | On device | In the app's History | — |
| Cleanup: fillers, self-corrections, lists | On device: rules, plus optional Apple on-device model | Yes | — | Through modes | AI Companion polish |
| Edit existing text | Fix / Rewrite with Apple's on-device model | Speak to edit | — | — | Edit or rewrite by voice |
| Personal vocabulary | Yes; also biases the recognizer | Yes | — | Yes (per device) | My Words |
| Style per app or field | Mode picked from the text field (email field: verbatim; Send key: message) | Tone adapts to the app | — | Modes (e.g. casual for iMessage) | — |
| Typing keys | Punctuation, space, delete, return; globe for the system keyboard | — | Switches to the system keyboard in number pads | — | Built-in QWERTY |
| Hand text to an agent | Ask Harness → GOD | — | — | — | — |

Where Harness is behind: Diction has a built-in QWERTY layout, and Typeless and Diction translate
while you speak. Both are reasonable follow-ups; neither is in section 15 of the spec.

## How it works

iOS keyboards cannot use the microphone, so the keyboard hands recording to the app. Wispr Flow's
keyboard does the same ("In other apps, the keyboard opens Flow to record") and tells users to swipe
right across the bottom edge to return; Superwhisper's docs say to swipe back on iOS 26.4 and later.
Harness:

```
 Keyboard extension                    Harness app (owns the mic)
 ──────────────────                    ──────────────────────────
 tap Dictate ──► commands.json ──────► DictationHost
   (cold: opens harness://dictation)    ├─ SessionMachine: inactive → warm → listening → finishing
                                        ├─ AudioCapture (AVAudioEngine, background audio mode)
                                        ├─ AudioGate: drops audio unless a dictation is active
                                        ├─ Transcriber: on device | my computer | cloud
                                        ├─ TranscriptCleaner + PersonalDictionary (+ AI polish)
 insert text ◄── status.json ◄─────────┘
           (Darwin notifications ring the doorbell; App Group files carry the data)
```

1. The first tap opens Harness, which starts a **warm microphone session** in the foreground. The user
   swipes back (iOS 26.4+ no longer returns automatically, so the app shows how).
2. While warm (5 minutes by default), the keyboard starts and stops dictation in place. Audio between
   dictations is dropped in `AudioGate` and never leaves that function.
3. Text is cleaned on device, fitted to the cursor (spacing, capitals) and inserted. One tap undoes it.

Fix and Rewrite run Apple's on-device model inside the keyboard when available, otherwise in the app
(optionally through GOD's model router). Ask Harness hands the selection to GOD.

## Package layout

| Target | Platform | Contents |
|---|---|---|
| `DictationCore` | Any (tested on Linux) | Cleanup, dictionary, insertion, routing, bridge protocol, session state machine, audio math, transcription API, settings, history |
| `DictationEngine` | iOS (app + keyboard) | Mic capture, SpeechAnalyzer transcriber, remote transcriber, Foundation Models rewriter, App Group bridge, Keychain, network monitor |
| `HarnessKeyboardKit` | iOS keyboard | `HarnessKeyboardViewController`, view model, SwiftUI keyboard |
| `DictationAppKit` | iOS app | `DictationHost`, Dictation tab, settings screens, handoff screen |

## How it is wired into Harness

Requirements: Xcode 26+, iOS 26+ (SpeechAnalyzer and Foundation Models).

`scripts/generate-project.py` (repo root) generates both targets; run it after adding files.

| Piece | Where |
|---|---|
| App links `DictationAppKit` and `DictationEngine` | generated project, local package `../Packages/HarnessDictation` |
| One `DictationHost` for the app's lifetime, `harness://` links, scene phase, handoff screen, Ask Harness → GOD | `iOS/Harness/HarnessApp.swift` |
| Dictation tab | `iOS/Harness/RootView.swift` |
| Composer prefill from Ask Harness | `AppModel.prefillComposer(_:)`, `ConversationView` |
| Microphone string, `audio` background mode, `harness` URL scheme | `iOS/Harness/Info.plist` |
| Keyboard extension (`org.harness.ios.keyboard`), Full Access on | `iOS/HarnessKeyboard/` |
| App Group `group.org.harness.ios` on both targets | `iOS/Harness/Harness.entitlements`, `iOS/HarnessKeyboard/HarnessKeyboard.entitlements` |
| Privacy manifests (App Group defaults, system uptime) | `PrivacyInfo.xcprivacy` in both targets |

To sign for a device, create the App Group `group.org.harness.ios` (or change it in the two entitlements
files and in `KeyboardViewController.appGroupIdentifier` / `HarnessApp`) and enable it on both App IDs.

Not wired yet: the paired-computer transcription service (`PairedComputerTranscription`, needs a
companion endpoint) and GOD's model router as `fallbackRewriter` for devices without Apple Intelligence.

## Test

```bash
swift test                              # 76 tests: cleanup, dictionary, insertion, routing, bridge, session machine, audio, API
Tools/LinuxTypeCheck/check.sh           # type-checks every file, SwiftUI and UIKit included, without an Apple SDK
Tools/LinuxTypeCheck/check.sh strict    # same, with strict concurrency on the engine and logic modules
```

`Tools/LinuxTypeCheck` compiles the real sources (plus the repo's keyboard extension file) against interface
stubs of SwiftUI, UIKit, AVFoundation, Speech and Foundation Models, so CI can run it on Linux. It
catches wrong names, types, bindings, closure shapes, access levels and actor isolation. It can't catch
layout or runtime behavior: build in Xcode and work through `docs/QA_CHECKLIST.md` on a device for that.
`docs/PRIVACY.md` has the data-flow guarantees and `docs/APP_REVIEW.md` the review notes.

## Sources

- Apple: [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer),
  [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber),
  [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- Typeless: [App Store](https://apps.apple.com/app/id6749257650), [Data controls](https://typeless.com/data-controls)
- Wispr Flow: [Set up the Flow keyboard on iPhone](https://docs.wisprflow.ai/articles/7453988911-Set-up-the-Flow-keyboard-on-iPhone),
  [Privacy Mode & Data Retention](https://docs.wisprflow.ai/articles/6274675613-privacy-mode-data-retention)
- Superwhisper: [iOS getting started](https://superwhisper.com/docs/get-started/ios), [Superwhisper for iOS](https://superwhisper.com/ios)
- Diction: [App Store](https://apps.apple.com/app/id6759807364)
