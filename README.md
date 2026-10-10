# Harness

**Version 0.1.0**

A local-first personal agent for iPhone, with a portable Swift agent core and an explicitly paired computer worker. The initial interface prioritizes **iPhone 18 Pro and iPhone Duo** through compact and expanded layouts rather than hard-coded device dimensions. Device features are checked at runtime; no unconfirmed hardware capabilities are assumed.

This is an initial MVP implementation, not an App Store release. The original specification is in [the product brief](docs/PRODUCT_BRIEF.md).

Planned device support: **Fold8 Ultra 1TB: 16GB soon...**

## See the interface

Open [the self-contained interactive preview](preview/harness-preview.html) in a browser, or serve `preview/` with `python3 -m http.server 4173 --directory preview`. Switch between **iPhone 18** and **iPhone Duo** to explore compact tabs and the expanded workspace panel. Try GOD, Agents, Red, Me, learning approval, Journey, and editable agent files.

This is a browser design study using sample data and deterministic example replies, not an iOS simulator. It makes no model requests, accepts no API keys, and retains changes only in memory until reload. The native app uses actual runtime status and starts without sample learning proposals. Social counts in the preview illustrate the planned Red community; the native MVP has a curated local collection. Preview dimensions are layout test sizes, not hardware specifications.

![Harness interface preview](preview/harness-interface.png)

The native SwiftUI implementation keeps the conversation and navigation mounted when changing width; larger layouts reveal a navigation rail and contextual workspace panel. Accessibility text sizes collapse the extra panel. Screenshots and preview build instructions are in [preview/README.md](preview/README.md).

## Run the iPhone app

Requires **macOS, Xcode 26 or later, and iOS 26 or later**. Use an Xcode release that supports your physical device's installed OS (including the current iOS 27 SDK for iPhone Duo acceptance). Open `iOS/Harness.xcodeproj`, select the shared **Harness** scheme, set your signing team and a unique bundle identifier, and run on your iPhone. Apple Intelligence must be enabled and its model downloaded for on-device generation; cloud access is optional.

The checked-in project uses the local `HarnessCore` and `HarnessDictation` packages and needs no third-party Swift dependencies. It has two targets: the Harness app and the Harness Keyboard extension, sharing the App Group `group.org.harness.ios` (create it for your team, or change it in both `.entitlements` files, to run on a device). Regenerate it after adding app files:

```sh
python3 scripts/generate-project.py
```

Unsigned simulator build on a Mac:

```sh
xcodebuild -project iOS/Harness.xcodeproj -scheme Harness \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

The app starts with local-only routing and learning set to **Ask Me**. In **Me → Providers**, OpenRouter is the recommended optional cloud route: enter an API key and a model identifier supported by your account, then select Balanced or Cloud preferred. Direct OpenAI-compatible endpoints and loopback local model servers are also supported. Keys go into Apple Keychain and are never stored in context files or session records. Remote endpoints require HTTPS; redirects are refused.

The Apple adapter calls `FoundationModels.SystemLanguageModel` and `LanguageModelSession` for real on-device text generation. It handles model availability, cancellation, context limits, unsupported languages, refusals, and temporary busy states. It does **not** execute tools in this build. Select a tool-capable OpenAI-compatible local or cloud model to use the full agent loop. Routing currently follows your local/balanced/cloud preference; cost, latency and capability-based automatic model selection remains future work.

## What is implemented

- Five adaptive native tabs: GOD, Dictation, Agents, Red, and Me; expanded widths use a navigation rail and live workspace panel. The director can be renamed without changing its role.
- **Harness Keyboard** and the Dictation tab ([Packages/HarnessDictation](Packages/HarnessDictation/README.md)): a system-wide dictation keyboard with Dictate | Fix | Rewrite | Ask Harness, on-device transcription by default (Apple SpeechAnalyzer), optional cloud endpoint, on-device cleanup of fillers and self-corrections, and no audio retention. Ask Harness opens GOD with the text in the composer.
- A presentation-independent, bounded agent loop with sequential tool calls, scoped specialist delegation, cancellation, saved sessions, and context windows that retain complete tool-call/result groups.
- Local SQLite records for sessions, separate SOUL/USER/MEMORY/AGENTS files, skills, learning proposals, Journey, settings, and an inspectable activity trail. Agent files support Markdown import/export.
- Metadata-first skill recall using keyword relevance and recorded outcomes; lazy procedure loading; versioned editing, disabling and deletion. Learned skills start disabled and never gain native privileges automatically. Embeddings and bundled skill scripts are not implemented.
- A restricted local Learning Reviewer with no external tools; deterministic explicit-preference fallback, approval/edit/rejection, stale-write protection, and reversible Journey entries. Automatic mode applies only tightly validated, explicitly evidenced preference updates; skill changes still require review.
- A deterministic permission kernel outside the model. Agent profiles impose capability ceilings; saved rules cannot remove biometric approval for sensitive actions. Specialists do not inherit GOD's permissions. Denials and approvals are audited.
- Optional HTTPS computer pairing with expiring single-use QR codes, exact certificate pinning, independently selected phone/node capabilities, confined file access, and biometric-approved command execution. See [companion setup](companion/README.md).
- A local curated **Red prototype**, with capability disclosures and restricted install/fork flows. It is not connected to a public social service.
- Privacy settings with an editable audit prompt, deterministic client observations and optional model interpretation through normal consent. Authorized request context is inspectable locally; an audit does not certify security or a provider's retention behavior.

## Test the core and companion

Swift 6.2, SQLite development headers, Python 3.11+, and OpenSSL are sufficient. On macOS, Xcode supplies the Swift/SQLite prerequisites. On Linux, install the SQLite development package for your distribution.

```sh
swift test -j 4
PYTHONPATH=companion python3 -m unittest discover -s companion/tests -v
swift test --package-path Packages/HarnessDictation
Packages/HarnessDictation/Tools/LinuxTypeCheck/check.sh   # SwiftUI/UIKit type-check without an Apple SDK
```

In the prepared Codex cloud environment:

```sh
source /workspace/toolchains/env.sh
bash scripts/check.sh
```

The cloud machine has a signature-verified Swift 6.2 toolchain and authenticated SQLite packages outside the checkout. It can build and test `HarnessCore` and the companion; it cannot compile SwiftUI, access an iOS simulator, exercise Keychain/Face ID/camera, or run Apple Foundation Models. CI runs the core, companion and dictation checks on Linux, and builds the app and keyboard with Xcode on macOS (`.github/workflows/macos.yml`, when app, package or companion code changes). Device acceptance remains required.

## Device acceptance on a Mac

Use available simulator identifiers from `xcrun simctl list devices available`; do not substitute invented device profiles. Validate compact and expanded widths, rotation, Dynamic Type, keyboard clearance and permission sheets. On physical target devices, verify Apple model availability, Keychain persistence, cloud denial with no request, exact TLS pin mismatch rejection, QR expiry/replay, capability revocation and cancellation. iPhone Duo layout behavior needs verification on the actual available hardware/SDK.

## Current boundaries

HomeKit, SSH, Shortcuts, Calendar, Reminders, Contacts, Messages/Notes, a public Red backend, account sync and persistent background execution are not part of this first build. Conversations and skills work locally, but offline tool orchestration needs a configured tool-capable local endpoint. The app cancels active work when entering the background; it does not promise a permanently running iOS process.

macOS/Linux companion filesystem isolation uses descriptor-based path checks and has been tested on Linux. Windows filesystem tools fail closed; experimental Windows pairing/command execution requires owner-only credential ACLs and still needs native verification. Command execution is a powerful, separately granted capability and is not confined to the selected file root.

No analytics SDK, telemetry endpoint or embedded credential is included. User-selected providers and explicitly paired computers receive only authorized requests. Locally retained sessions and audit records may contain sensitive user content; they remain in the protected application sandbox. There is no custom database encryption beyond iOS data protection.

Architecture and security boundaries are documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Licensed under Apache 2.0.

Platform references: [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models) and [Apple's iPhone Duo announcement](https://www.apple.com/newsroom/2026/09/apple-unveils-iphone-duo/). Device-specific acceptance remains unverified until tested with the appropriate Apple SDK and hardware.
