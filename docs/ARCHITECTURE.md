# Harness architecture

The phone owns the session, user context, approval UI and credentials. Models request operations; trusted host code checks them. The UI does not parse model text into permissions, and neither skill text nor model output can change capability rules.

```mermaid
flowchart TD
  UI[Adaptive iPhone interface] --> Runtime[AgentRuntime actor]
  Runtime --> Router[Provider-neutral ModelRouter]
  Router --> Local[Apple on-device text / local endpoint]
  Router --> Consent[Network permission]
  Consent --> Cloud[Optional OpenAI-compatible provider]
  Runtime --> Kernel[Deterministic PermissionKernel]
  Kernel --> LocalTools[Memory and skill tools]
  Kernel --> Node[Pinned HTTPS computer worker]
  Runtime --> Store[Local SQLite records]
  Runtime --> Review[Learning Reviewer: local, no tools]
  Review --> Proposal[Learning proposals]
  Proposal --> Learning[Learning Kernel: validate / approve / revert]
  Learning --> Store
  Keys[Apple Keychain] --> Cloud
  Keys --> Node
```

## Runtime and context

`HarnessCore` is a Swift package with no SwiftUI dependencies. Actors serialize database updates and runtime state. Each turn reserves its session before awaiting, persists user input, loads a current agent profile, assembles separately labeled context files, retrieves relevant skill metadata, chooses an available provider, and requests consent before cloud inference. Tool calls run sequentially with bounded rounds/call counts. Interrupted calls receive explicit incomplete results so a resumed context does not contain orphan tool calls.

The current router supports explicit local-only, local-first Balanced, and cloud-first preferences. There is no silent switch from a failed local inference to a cloud API. The Apple adapter reports that tools are unavailable instead of simulating actions. OpenAI-compatible endpoints handle actual structured tool calls. Anthropic/Gemini native protocols can later conform to `ModelProvider`; they are not implemented as direct native clients today.

The core includes only tools actually implemented by the client. No unrestricted browsing or Apple integration is advertised. Paired computer IDs and granted capabilities are made available to a tool-capable model without credential material.

## Permissions and credentials

Every tool has a capability and risk level. A live agent capability ceiling and saved user denials are checked before and after awaited approval. Low-risk built-in local reads may be allowed; external profiles ask. Sensitive actions always require the host's biometric flow, even if a previous broad allow rule exists. An authorization handler is an injected trusted-host boundary, never an LLM callback.

Provider and companion tokens are stored in Keychain with device-only accessibility. Model context and the SQLite state contain provider configuration and certificate fingerprints, never raw API keys or bearer credentials. Network sessions are ephemeral and refuse redirects to prevent credential forwarding. Companion connections validate the exact QR certificate fingerprint, hostname, dates and TLS policy.

Phone grants are a subset of the node's independently configured capabilities. Pairing starts with read access only where the node supports it. Revoking phone grants stops future agent requests; revoking a companion bearer credential requires the node's revoke command. Already executing authorized requests cannot be undone by changing a toggle.

## Learning

The Learning Reviewer receives bounded evidence and context, and uses only a local provider without tools. If no local model is available, the fallback proposes only explicit first-person preference statements. It cannot invoke the external executor or inherit GOD's capabilities. Model-proposed memory/skill changes remain data until the Learning Kernel validates and applies them.

Ask Me is the default. Approved changes compare the original content inside an atomic store update; stale proposals fail instead of overwriting later edits. Journey stores before/after content and guards reversions similarly. New learned skills are disabled with local-read-only requirements. Their Markdown cannot grant capabilities, and skill procedure loading remains separate from native execution.

## Storage and privacy evidence

Each store mutation commits its typed collections transactionally. A complete agent turn uses multiple mutations for session state, learning and audit entries; it is not one transaction across the entire run. Invalid data is reported and preserved; the app does not silently reset the user's store. The iOS database directory and files use data protection; credentials use Keychain independently.

Activity distinguishes context prepared for an authorized request from a successful provider response. It records selected message context, tool inputs/results, permission decisions, provider/token metadata when reported, and learning outcomes. These are application observations, not packet captures. An authorized request can fail without establishing delivery; a successful response still cannot prove remote retention practices. No model interpretation alone establishes security.

## iPhone-first presentation

The app target is iPhone on iOS 26+. Compact widths show Dot/Speak/Social/.md/Me tabs. Expanded widths place workspace left, content center and navigation right. Layout follows available geometry rather than model-name checks. Native safe areas, scrolling and Dynamic Type are used. Device eligibility is discovered through Apple APIs, and unavailable model/camera paths have explicit UI states.

Physical-device validation is necessary for recording, keyboard handoff, biometric approval and layout behavior. Director work cancels on backgrounding. The companion now implements owner-scoped start/status/cancel for up to 30-minute jobs, with idempotent retries, cancellation tombstones and bounded retained results. Jobs last only while that process runs; they are not durable across restarts. Manual ended-turn recovery controls are not exposed yet.

## Speak layers

`DictationCore` owns portable cleanup, prompts, instruction-file validation, routing, session and insertion rules. `DictationEngine` implements iOS audio/Speech adapters, shared instruction storage and Apple text models. `DictationAppKit` owns the microphone session and rewrite lifecycle. `HarnessKeyboardKit` owns controls, bridge requests, insertion and undo. Request IDs reject late outcomes; rewrite targets compare document identity and visible selection/cursor context before replacement.

Transcription and text cleanup are separate. Shared `Speak/instruction.md` is read for Polish, Fix and Rewrite. Local rewriting is the default. Optional iOS 27 PCC needs explicit routing, build configuration, entitlement and availability/quota. Failed local-only processing never silently uploads text.

The app owns the microphone; Full Access does not remove keyboard restrictions. Secure fields and apps rejecting custom keyboards remain unsupported. Manual activation and Start Speak shortcuts provide foreground entry paths. The responder-chain URL opener is experimental, not an approved extension API or proven device behavior.

## Social layers

Portable `SocialClient` and draft models live in `HarnessCore`; native `SocialModel` and views own account/presentation state. The standalone SQLite HTTP service owns sessions, posts/threads, profiles, follows, mutes and reactions. It has its own credential boundary, independent of companion trust. Native use requires a configured HTTPS origin; local HTTP is a test option. Browser Social uses explicitly local demonstration data.
