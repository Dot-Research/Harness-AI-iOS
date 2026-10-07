# Harness interface preview

Open `harness-preview.html` in a browser. This single file contains the styles, icons, and interactions; it works without a web server or network connection. If your browser disallows local file URLs, serve this directory normally:

```sh
python3 -m http.server 4173 --directory preview
```

Then open `http://localhost:4173`.

## What to try

- Switch between iPhone 18 and iPhone Duo layouts; a draft and conversation survive the switch.
- Open GOD, Agents, Red, and Me.
- Send a demo prompt; replies are deterministic examples, not model inference.
- Review, edit, approve, or reject the sample learning proposal; inspect and revert an approval in Journey.
- Inspect skill capabilities before installing a disabled example skill.
- Edit SOUL.md, USER.md, MEMORY.md, and AGENTS.md in preview memory.
- Inspect model routing, privacy, and computer pairing explanations.

Everything resets on reload. No model API, telemetry, external assets, API-key collection, browser persistence, or computer connection is implemented. Sample social counts illustrate a future Red community. The native Red MVP is a local collection.

This is an interface study alongside the native SwiftUI implementation, not a screenshot of a running iOS app. It uses illustrative dimensions and system chrome; it does not simulate actual device hardware, Apple Intelligence availability, native keyboard behavior, Dynamic Type, or Apple's platform navigation. Use Xcode and real devices for those checks.

## Edit and rebuild

Edit `index.html`, `style.css`, and `app.js`, then regenerate the portable HTML:

```sh
python3 scripts/build-preview.py
```

`harness-interface.png` shows both layouts. `harness-duo.png`, `harness-iphone.png`, and `harness-learning.png` show individual interface states.
