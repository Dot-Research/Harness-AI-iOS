# Harness Speak

Speak is the native dictation space and Harness Keyboard. It separates speech recognition, text cleanup, model rewriting and insertion. The app owns the microphone; the keyboard communicates through the shared App Group.

## Current behavior

- On-device Apple SpeechAnalyzer transcription, live partial text, personal vocabulary and deterministic cleanup.
- Optional user-configured cloud speech endpoint. Paired-computer transcription has an adapter boundary but no connected companion speech endpoint yet.
- Fix, Rewrite, selection handoff to Dot and insertion/undo. Late results are checked against the original field and selection.
- A full typing layer under the control bar: QWERTY letters, shift and caps lock, numbers and symbols, field-aware automatic capitals, double-space period, email/URL keys and a return key titled for the field. It works without Full Access; the waveform and keyboard keys switch between typing and the dictation panel.
- Shared `Speak/instruction.md` for automatic Polish, Fix and Rewrite. UTF-8 instructions have an 8 KB limit, atomic saving and Markdown import/export.
- Local Apple text rewriting by default. Explicit PCC-only or local/PCC fallback routes require iOS 27, developer approval/provisioning and runtime availability/quota. PCC is disabled in the checked-in configuration. Text models edit transcripts; they do not transcribe audio.
- Verified StoreKit subscription access gates recording and keyboard starts. Real product IDs must be configured in the host app. Empty product configuration grants no Speak access.

Audio buffers stay in memory. History is optional and stores text only. A selected remote transcription provider receives audio; an explicitly selected PCC text route receives the text needed for rewriting. See [privacy details](docs/PRIVACY.md).

## iOS handoff

Start Speak in Harness or through its **Start Speak** shortcut, allow the microphone and return manually to the destination app. While iOS keeps the session warm, the keyboard can start and stop dictation through App Group commands. The orange microphone indicator remains visible until the session stops or expires; the default warm period is five minutes.

The cold keyboard opener includes an experimental responder-chain URL path. It is not a supported keyboard-extension API or proof of App Review acceptance. Use manual/shortcut activation for acceptance testing and verify cold/warm recording, interruptions and insertion on a physical iPhone. Full Access does not grant microphone access. Secure fields and apps that reject custom keyboards use Apple's keyboard.

```text
Keyboard controls → App Group commands → DictationHost
                                            ↓
                          AudioCapture → AudioGate → Transcriber
                                            ↓
                           Cleanup → instruction.md → Text rewriter
                                            ↓
Keyboard field/selection check ← App Group result ← Final text
```

## Functional layers

| Target | Responsibility |
|---|---|
| `DictationCore` | Portable cleanup, vocabulary, prompts, routing, bridge messages, insertion rules, subscriptions and session state |
| `DictationEngine` | iOS microphone/Speech adapters, Apple text models, instructions/settings storage, App Group bridge and Keychain |
| `DictationAppKit` | App microphone lifecycle, Speak screens, instructions editor and handoff |
| `HarnessKeyboardKit` | Keyboard controls, typing layer, field/selection validation, insertion and undo |

The host integration lives in `iOS/Harness/HarnessApp.swift`. It passes verified subscription access and optional PCC enablement to the dictation host. Ask Harness prefills the Dot composer. Dot's provider/router is separate; its fallback rewriter and a paired-computer speech service are not connected to Speak yet.

## Build and setup

Requires Xcode 26+ and iOS 26+. Optional PCC code requires the Xcode 27 SDK. Open the root `iOS/Harness.xcodeproj`, configure signing and register `group.org.harness.ios` for both app and keyboard. If changing the group, update both entitlements and the app/keyboard configuration.

Run `python3 scripts/generate-project.py` from the repository root after adding app files. Set real `HarnessSubscriptionProductIDs` in the host Info.plist before testing StoreKit access. Enabling `HarnessPrivateCloudEnabled` alone does not grant Apple's PCC entitlement.

## Verification

From this package directory:

```sh
swift test
Tools/LinuxTypeCheck/check.sh
Tools/LinuxTypeCheck/check.sh strict
```

The portable suite currently passes 109 tests. The stub checker includes SwiftUI/UIKit sources and the repository keyboard extension; it checks API shapes and concurrency on Linux, or with separately named stand-ins on macOS. It does not verify layout, framework runtime behavior or microphone-to-field handoff.

Use the [physical-device QA checklist](docs/QA_CHECKLIST.md) and [draft App Review notes](docs/APP_REVIEW.md) before release. Compilation and local model checks do not prove subscription transactions, PCC eligibility or real keyboard insertion.
