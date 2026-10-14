# Release test plan (on device)

Run on at least one supported Apple Intelligence iPhone, one supported iPhone without Apple
Intelligence, and an iPad. Cover iOS 26 and iOS 27. Browser mockups and a simulator build do not
verify physical microphone capture, background continuation or insertion into another app.

## Setup
- [ ] Fresh install: Dictation tab shows Set up with four steps; each step's button does what it says.
- [ ] Keyboard without Full Access shows the explanation card and still types punctuation, space, delete, return.
- [ ] After enabling Full Access, the Dictation tab marks the keyboard as set up (open the keyboard once).
- [ ] Microphone denied: tapping Dictate shows "Microphone access is off" in the keyboard; Settings link works.
- [ ] Microphone denied, and again during a phone call: Try it in the Dictation tab shows the error once and returns to "Dictate" (no stuck "Stop", no repeated status writes in Console).
- [ ] Speech model download completes; Set up hides once all four are done.

## Core dictation
- [ ] Start Speak from the app shortcut (Shortcuts / supported Action Button or Back Tap assignment): Harness foregrounds, checks subscription/microphone access, starts the visible warm session; return manually to the text field.
- [ ] The keyboard extension itself never requests microphone access or captures audio.
- [ ] Password/secure fields switch to the system keyboard; an app that rejects custom keyboards is explained as unsupported, not a Speak crash.
- [ ] Cold-start automatic opening is treated as experimental: invocation is not proof the app opened. Failed opening cancels its queued request and offers manual/shortcut activation.
- [ ] Cold start from Notes, Messages, Mail, Safari, WhatsApp, Slack: app opens, handoff screen shows, swipe back, dictation continues, Stop inserts text at the cursor.
- [ ] Warm start (within 5 min): no app switch; first words are not lost.
- [ ] Insertion: mid-sentence lowercase, after "." capitalized, space handling before/after existing words, no doubled period.
- [ ] Undo restores exactly the previous text (also with a selection replaced).
- [ ] Hold delete, then dismiss the keyboard (or pull down Control Center) mid-hold: deleting stops.
- [ ] Open `harness://dictation/settings?section=dictionary` from Safari with Harness not running: the app opens on Dictation > Personal dictionary.
- [ ] Cancel (x) discards; nothing inserted.
- [ ] Long dictation (5 min) completes; max utterance stops at the configured limit.
- [ ] Silence auto-stop (3 s) stops after speech, not before.
- [ ] Interruptions: incoming call, Siri, alarm, AirPods connect/disconnect, headphones unplug mid-dictation — what was heard is inserted; the keyboard returns to idle; no crash.
- [ ] Music playing: warm mic does not stop it; dictation works with music playing.
- [ ] Lock the phone while warm: session ends or continues per iOS, no stuck state when unlocking.
- [ ] Force-quit Harness while listening: keyboard shows "Dictation stopped" within a few seconds.
- [ ] iOS relaunches the keyboard while the user is in Harness: returning still inserts the result once.

## Typing layer
- [ ] Without Full Access the keyboard opens on the typing keys; letters, numbers, symbols, space, delete and return all work.
- [ ] Shift: one tap capitalizes one letter; a quick double tap locks caps (caps-lock icon); a third tap releases.
- [ ] New field, after ". " and after a new line: shift is on automatically; it stays off after "word " and in email/URL fields.
- [ ] Fields with words or all-characters capitalization (name fields, codes) follow the field.
- [ ] Double-tap space after a word inserts ". "; not after punctuation, not in email/URL fields.
- [ ] 123 / #+= / ABC switch planes; space or apostrophe on numbers returns to letters.
- [ ] Email fields show @ and . next to space; URL fields show / and .; the return key reads send/go/search/done as the field asks.
- [ ] Waveform key shows the dictation panel and the keyboard key returns to typing; the choice is remembered.
- [ ] Dictate from the typing layer: the listening panel replaces the keys and typing comes back after insertion.
- [ ] Fix, Rewrite and Ask are disabled while dictation is listening or finishing.

## Cleanup
- [ ] "um let's meet Tuesday, no wait, Thursday" -> "Let's meet Thursday".
- [ ] "first milk second eggs third bread" in Note mode -> numbered list.
- [ ] "new line", "new paragraph", "bullet point", "scratch that" work.
- [ ] Email field (keyboard type email): verbatim, no AI, no final period.
- [ ] Messages (Send key): message mode, no final period on one-liners.
- [ ] Dictionary: "OpenRouter", a client's name, "HOA" come out as written.
- [ ] Spanish, Chinese, Japanese: on-device transcription, no stray spaces (CJK), English-only rules not applied.

## Routes
- [ ] On device in airplane mode (model installed): works.
- [ ] Unsupported language, cloud fallback off: clear message, nothing sent.
- [ ] Cloud endpoint (OpenAI and Groq): works; wrong key shows the provider's error; airplane mode falls back to on device.
- [ ] My Computer (once pairing ships): works on LAN and over relay; unreachable computer falls back as configured.

## Fix / Rewrite / Ask Harness
- [ ] Import/edit/export Speak/instruction.md; all three paths (automatic polish, host rewrite, keyboard local rewrite) use the same latest saved content.
- [ ] Editing text or moving selection while a rewrite runs cannot insert the result into a different field/selection.
- [ ] Cancel a long rewrite; late model results and host outcomes do not insert anything.
- [ ] Local-only rewriting never uploads text even if the local model is unavailable.
- [ ] On iOS 27, test PCC after entitlement setup: unavailable hardware/account, no network, daily quota, successful output and opted-in fallback. No production eligibility is assumed from compilation.
- [ ] Fix and each Rewrite choice on a selection and on the current paragraph; Undo works.
- [ ] Device without Apple Intelligence: request goes to the app (or explains it needs a model).
- [ ] Ask Harness opens GOD with the text prefilled, on cold and warm launch.
- [ ] Cold launch from the keyboard while the subscription is still loading: dictation starts once access is confirmed (no "Checking your subscription" failure); a queued Ask Harness or Rewrite is not lost.
- [ ] Expired subscription: keyboard Fix/Rewrite through the app reports that a subscription is required.
- [ ] Rewrite handed to the app with Harness unable to open: the keyboard gives up after about 25 s with a message instead of spinning.

## Privacy checks
- [ ] Instruments / File Activity: no audio files created in any container during dictation.
- [ ] `dictation-status.json` contains no transcript 60 s after a dictation, or right after insertion.
- [ ] Network: on-device route makes no requests (Charles/Proxyman), cloud route makes exactly one per dictation.
- [ ] History off: nothing stored; on: entries expire after the set period.

## Accessibility and layout
- [ ] VoiceOver labels on every keyboard control; Dynamic Type up to AX3 in the Dictation tab.
- [ ] Keyboard height and layout on small/large supported iPhones and iPad, including landscape.
- [ ] Light and dark appearance in host apps.

## Performance
- [ ] Keyboard extension memory under 40 MB during dictation (Xcode memory gauge).
- [ ] Time from Stop to inserted text under 1 s for 30 s of speech on device.
- [ ] Measure battery cost for a 15-minute warm session on the actual test device; record model, OS and measured value.
