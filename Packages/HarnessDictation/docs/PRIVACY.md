# Dictation privacy

What happens to your voice and text, stated so it can be checked in the code.

## Audio

- **Never written to disk.** `AudioCapture` delivers buffers in memory. `AudioGate.route` drops every
  buffer when no dictation is active; while one is active it passes them to exactly one transcriber.
  There is no audio file sink in the package. Bridge JSON, settings, `Speak/instruction.md` and opt-in text history are separate disk-backed text/configuration data.
- **On device (default).** `OnDeviceTranscriber` feeds Apple's SpeechAnalyzer. Nothing leaves the iPhone.
  The first use of a language downloads Apple's model once; no audio is involved in that download.
- **My Computer.** A paired-computer adapter is defined, but the host has no connected companion speech endpoint yet. The UI configuration does not prove a working speech route.
- **Cloud.** `RemoteTranscriber` keeps bounded 16 kHz mono audio in memory, encodes WAV in memory and sends it to the endpoint you configured, with your key. Only used when you pick
  Cloud or turn on "Allow cloud when nothing else works" (off by default). Requests use an ephemeral
  `URLSession` (no cache, no cookies). Plain HTTP is refused except for local-network addresses.
- **Warm microphone.** While the mic is ready, iOS shows the orange indicator. The keyboard's
  "Mic on" chip and the Dictation tab's "Turn off" end it immediately; it also ends on its own after
  the configured time (default 5 minutes).

## Text

- **Between the app and the keyboard** text passes through `dictation-status.json` in the App Group
  container. It is cleared when the keyboard confirms insertion, and expires after 60 seconds
  regardless (`HostStatus.expireResults`). The directory is excluded from backups and uses
  `completeUntilFirstUserAuthentication` file protection.
- **History** is off by default. When on, it lives in the app's own container (not shared with the
  keyboard), uses complete file protection, and entries expire after 1, 7 or 30 days.
- **Polish, Fix and Rewrite** use shared `Speak/instruction.md`. Local Apple text rewriting is the default. An explicitly selected PCC or local/PCC fallback route sends rewriting text through Apple's PCC model only after developer provisioning and availability/quota checks. PCC is disabled in the repository configuration. Dot's provider-router fallback is not wired to Speak.
- **The keyboard** reads only the text around the cursor that iOS shares with keyboards, and only when
  you tap Fix, Rewrite or Ask Harness, or to fit dictated text into the sentence.

## Secrets

Cloud keys are stored in the Keychain (`AfterFirstUnlockThisDeviceOnly`, never synced), read only by
the app at the moment of a request, never by the keyboard, and never placed in any model context.

## Analytics

Harness includes no analytics or crash-reporting pipeline. The selected remote speech route and optional PCC text route can make network requests. The host also uses StoreKit to verify subscription access. Provider retention is separate from Harness's own storage behavior.
