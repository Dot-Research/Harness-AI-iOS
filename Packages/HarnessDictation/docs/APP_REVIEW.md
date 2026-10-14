# App Review notes

Draft submission notes only. Real subscription products, device acceptance and any PCC entitlement
must be configured and verified before using these as release claims. Cold-start keyboard URL
opening currently includes an experimental responder-chain compatibility path; it is not a supported
keyboard-extension API or proof of App Review acceptance. The app's Start Speak shortcut and manual
foreground activation provide supported entry points. Confirm the release's actual handoff method.

Paste the relevant parts into App Store Connect > App Review Information > Notes.

**Why the keyboard asks for Full Access.** iOS keyboard extensions cannot record audio. Harness
Keyboard sends a request to the Harness app through the shared App Group container, the Harness app
records and transcribes, and the keyboard inserts the text. Full Access is required for the App Group;
the keyboard makes no network requests of its own and collects nothing.

**Why the app uses the `audio` background mode.** After the user starts Speak in Harness or through its shortcut, the
Harness app starts a microphone session in the foreground and the user returns to the app they were
typing in. Recording continues in the background so they can keep dictating there. The session ends
after a user-chosen period (default 5 minutes), when the user taps "Turn off", or immediately when they
choose "Off". The system's orange indicator is visible the whole time. Audio is processed in memory and
discarded; it is never stored.

**How recording starts.** Open Harness or invoke Start Speak, begin the microphone session in the foreground, then return to the destination app. The cold keyboard URL opener remains experimental and is not the acceptance flow described here.

**How to test.**
1. Configure real Speak subscription products and obtain verified access in the appropriate StoreKit test environment. Install, open Harness, go to Speak and follow Set up (add the keyboard, allow Full Access, allow the microphone, download the speech model).
2. Start Speak in Harness or invoke its shortcut, return manually to Notes, switch to Harness Keyboard with the globe key and tap Dictate while the session is warm.
3. Say "um let's meet Tuesday, no wait, Thursday at 3 new line thanks". Tap Stop.
   Expected: "Let's meet Thursday at 3" on one line, "Thanks" on the next.
4. Select the text and tap Fix or Rewrite (devices with Apple Intelligence).

Speak requires verified subscription access. Before submission, provide the reviewer with the release's actual purchase/restore instructions and any required review credentials; the current empty product configuration is not ready for that flow.

## Guideline checklist

- 2.5.4 (background modes): audio mode used only while actively recording for the user, with a visible
  indicator and user controls to stop.
- 4.4.1 (keyboard extensions): provides keyboard input (dictation plus punctuation, space, delete,
  return), includes the next-keyboard (globe) key when required, works without Full Access by
  explaining how to enable it, and does not use Full Access to collect data.
- 5.1.1 (data collection): reconcile the final privacy labels with selected speech/text providers and the shipped service configuration. Remote providers receive the data needed for the requested operation.
- 5.1.2: Harness includes no training, advertising or analytics pipeline. Verify the terms and retention of any operator-configured remote provider.
