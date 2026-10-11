# App Review notes

Paste the relevant parts into App Store Connect > App Review Information > Notes.

**Why the keyboard asks for Full Access.** iOS keyboard extensions cannot record audio. Harness
Keyboard sends a request to the Harness app through the shared App Group container, the Harness app
records and transcribes, and the keyboard inserts the text. Full Access is required for the App Group;
the keyboard makes no network requests of its own and collects nothing.

**Why the app uses the `audio` background mode.** After the user taps Dictate in the keyboard, the
Harness app starts a microphone session in the foreground and the user returns to the app they were
typing in. Recording continues in the background so they can keep dictating there. The session ends
after a user-chosen period (default 5 minutes), when the user taps "Turn off", or immediately when they
choose "Off". The system's orange indicator is visible the whole time. Audio is processed in memory and
discarded; it is never stored.

**How the keyboard opens the app.** When no microphone session is active, tapping Dictate opens
`harness://dictation/start`. The app shows a full-screen explanation with the instruction to swipe back.

**How to test.**
1. Install, open Harness, go to Dictation and follow Set up (add the keyboard, allow Full Access,
   allow the microphone, download the speech model).
2. Open Notes, switch to Harness Keyboard with the globe key, tap Dictate. Harness opens; swipe right
   along the bottom edge to return to Notes.
3. Say "um let's meet Tuesday, no wait, Thursday at 3 new line thanks". Tap Stop.
   Expected: "Let's meet Thursday at 3" on one line, "Thanks" on the next.
4. Select the text and tap Fix or Rewrite (devices with Apple Intelligence).

No account is required. No demo credentials are needed.

## Guideline checklist

- 2.5.4 (background modes): audio mode used only while actively recording for the user, with a visible
  indicator and user controls to stop.
- 4.4.1 (keyboard extensions): provides keyboard input (dictation plus punctuation, space, delete,
  return), includes the next-keyboard (globe) key when required, works without Full Access by
  explaining how to enable it, and does not use Full Access to collect data.
- 5.1.1 (data collection): no data collected; privacy manifest declares none.
- 5.1.2: audio and text are never used for training, advertising or analytics.
