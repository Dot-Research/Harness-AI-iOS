# Dictation privacy

What happens to your voice and text, stated so it can be checked in the code.

## Audio

- **Never written to disk.** `AudioCapture` delivers buffers in memory. `AudioGate.route` drops every
  buffer when no dictation is active; while one is active it passes them to exactly one transcriber.
  There is no file sink anywhere in the package (search for `write(to:` — only the bridge JSON, the
  settings and the opt-in text history are written).
- **On device (default).** `OnDeviceTranscriber` feeds Apple's SpeechAnalyzer. Nothing leaves the iPhone.
  The first use of a language downloads Apple's model once; no audio is involved in that download.
- **My Computer.** `RemoteTranscriber` keeps up to `maxUtteranceSeconds` of 16 kHz mono audio in memory,
  encodes it as WAV in memory and sends it once to the paired computer over the pairing channel.
- **Cloud.** Same as My Computer, to the endpoint you configured, with your key. Only used when you pick
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
- **Fix and Rewrite** use Apple's on-device model. If the app is given a fallback rewriter (GOD's model
  router), that path follows the router's provider and permission rules and appears in Activity.
- **The keyboard** reads only the text around the cursor that iOS shares with keyboards, and only when
  you tap Fix, Rewrite or Ask Harness, or to fit dictated text into the sentence.

## Secrets

Cloud keys are stored in the Keychain (`AfterFirstUnlockThisDeviceOnly`, never synced), read only by
the app at the moment of a request, never by the keyboard, and never placed in any model context.

## Analytics

None. The package contains no analytics, crash reporting or network calls other than the transcription
request you chose.
