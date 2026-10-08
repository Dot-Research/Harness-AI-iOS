# Harness

Build a privacy-first, open-source, self-improving AI agent for iOS inspired heavily by Nous Research Hermes Agent.

The iPhone is the user's persistent personal agent node. It provides identity, memory, permissions, local intelligence, connectors and device control. More computationally intensive or unrestricted work may be delegated to paired Mac, Windows or Linux computers.

The system must be model-provider agnostic. Recommend OpenRouter during onboarding, support direct providers and local models, and never make any particular provider structurally required.

---

## 1. GOD — General Orchestration Director

Build a permanent primary agent named **GOD — General Orchestration Director**.

GOD is the user's single conversational entry point. It understands the user's request, decides whether it can perform the task directly, delegates subtasks to specialist agents when useful, coordinates their results, and returns one coherent answer.

GOD should:
- maintain awareness of active goals and tasks;
- discover appropriate installed skills;
- spawn or invoke specialist agents;
- choose suitable models based on task complexity, privacy and cost;
- delegate work to paired computers when needed;
- request missing permissions;
- supervise long-running tasks;
- summarize what was completed, blocked or requires user input.

GOD must never bypass the Permission Kernel. It has coordination authority, not security authority.

Allow the user to rename GOD while preserving its system role.

---

## 2. Hermes-Style Agent Runtime

Implement the central runtime based heavily on Hermes Agent's architecture.

Each turn should roughly perform:

User input → assemble context → choose model → reason → invoke tools → receive results → continue until completion → persist session → launch learning review.

Support:
- tool calling;
- multiple sequential tool calls;
- subagents;
- resumable sessions;
- context compression;
- background/long-running tasks where iOS permits;
- model switching;
- cancellation;
- structured errors and recovery.

Keep the agent runtime independent from SwiftUI presentation.

---

## 3. Agent Context Files

Implement Hermes-style context files:

**SOUL.md**  
Defines persistent personality, behavioral principles and communication style.

**USER.md**  
Stores compact durable knowledge about the user: preferences, working style and expectations.

**MEMORY.md**  
Stores compact durable facts about the environment, projects, devices and tool behavior.

**AGENTS.md**  
Stores instructions specific to an agent, workspace, computer, repository or project.

Do not merge these concepts into one giant prompt.

Make all files inspectable and editable under:

Settings → Intelligence → Agent Files.

Advanced users should be able to import/export them as Markdown.

---

## 4. Skills

Implement Hermes-compatible procedural skills.

Directory concept:

skills/
  research/
    SKILL.md
  ssh-debugging/
    SKILL.md
  home-control/
    SKILL.md

A skill describes **how to perform a reusable class of tasks**, not a log of one particular task.

Implement equivalents of:

skills_list  
skill_view  
skill_manage

Only expose skill name + description initially.

Load the full SKILL.md only when GOD or another agent determines that skill is relevant.

Skills may also contain:

references/
templates/
scripts/

Support creating, patching, versioning, disabling and deleting skills.

---

## 5. Built-In Learning Loop

Implement a Hermes-style closed learning loop.

After meaningful agent turns, launch a separate **Learning Reviewer**.

Its job is to inspect what happened and determine whether the experience contains:

- a durable user preference;
- a useful environmental fact;
- a reusable multi-step workflow;
- an improvement to an existing skill;
- a mistake or dead end that should be avoided next time.

Classify findings as:

USER.md update  
MEMORY.md update  
new SKILL.md  
SKILL.md patch  
nothing worth learning

The Learning Reviewer must have a severely restricted tool set.

It can read sessions, memory and skills and propose memory/skill changes.

It cannot send messages, control Home devices, execute SSH commands, purchase anything, delete external files or inherit GOD's external action permissions.

---

## 6. Learning Approval

Create:

Settings → Intelligence → Learning

Modes:

Off  
Ask Me  
Automatic

Default to **Ask Me** for new users.

Example approval:

Harness learned something:

"You usually want technical explanations with architecture diagrams before implementation details."

Evidence: 4 similar corrections.

[Save] [Edit] [Reject]

For a skill update, show a readable diff before approval.

Automatic mode may apply low-risk learning, but every change must remain visible and reversible.

---

## 7. Journey

Create a **Journey** interface inspired by Hermes.

Journey shows how Harness has changed through use.

Display chronologically:

Learned preference  
Memory updated  
Skill created  
Skill improved  
Skill disabled  
Agent instruction changed

Example:

Today

Improved: github-research
+ Follow linked pull requests before concluding.
+ Prefer maintainer confirmation over speculation.

[View Diff]

Allow users to edit, revert or remove learned information.

Self-improvement should always be observable.

---

## 8. Skill Recall

Do not equate storing skills with learning.

Implement retrieval.

For every skill store metadata such as:

name  
description  
semantic embedding  
keywords  
tools required  
task categories  
usage count  
success count  
last used  
user rating

Before GOD solves a non-trivial task, search for relevant skills and rank them.

Load only the most relevant skills.

After execution, record whether the skill actually helped.

Use that outcome to improve future skill ranking.

---

## 9. Model Router

Create a provider-neutral ModelRouter.

Support conceptually:

Apple Foundation Models  
OpenRouter  
OpenAI  
Anthropic  
Google Gemini  
OpenAI-compatible endpoints  
local models  
paired-computer models

OpenRouter should be the recommended cloud setup because one API credential gives users model choice.

Routing should consider:

privacy  
capability  
latency  
cost  
context length  
offline availability  
tool-use support

Examples:

Simple rewrite → local model

Private summarization → Apple/local

Complex research → strong OpenRouter model

Repository refactor → paired Mac + coding model

Learning review → inexpensive/local auxiliary model

Allow users to override routing.

---

## 10. Credentials

Do not implement `.env` files containing real secrets.

Create:

Settings → Providers

Store API keys, refresh tokens, SSH credentials and pairing secrets using Apple Keychain or appropriate secure storage.

The UI can conceptually resemble environment-variable configuration:

OPENROUTER_API_KEY    ••••••••••
ANTHROPIC_API_KEY     Not configured

Never expose raw credentials to LLM context.

Agents receive credential handles or authorized connector calls, not the underlying secret.

---

## 11. Permission Kernel

Build a deterministic permission layer outside the model.

Every tool declares capabilities and risk.

Examples:

home.read
home.changeLights
home.unlockDoor

messages.compose
messages.send

computer.readFile
computer.writeFile
computer.execute

ssh.execute

network.request

The Permission Kernel decides whether an operation is:

Allow  
Ask  
Require biometric authentication  
Deny

Agents cannot modify this decision themselves.

Support:

Allow once  
Always allow  
Deny once  
Always deny

External agents installed through Red receive restrictive defaults.

---

## 12. Computer Pairing

Create a Harness companion/node for macOS, Windows and Linux.

On the computer:

harness pair

Display a QR code.

On iPhone:

Settings → Devices → Add Computer → Scan QR

Perform authenticated cryptographic pairing.

Never encode reusable passwords in the QR code.

After pairing, display selectable capabilities:

Terminal  
Filesystem  
Browser  
Coding  
Local models  
Long-running tasks

Users should grant capabilities independently.

The paired computer effectively becomes a worker for GOD.

---

## 13. Connectors

Create a common connector/plugin protocol.

Connectors expose typed tools to the runtime.

Initial connector targets should include:

Apple Home  
Shortcuts/App Intents  
Calendar  
Reminders  
Contacts where permitted  
GitHub  
web/browser  
paired computer  
SSH

Architect Messages and Apple Notes conservatively around APIs Apple actually exposes rather than assuming unrestricted database access.

Each connector must expose:

name  
description  
available tools  
permissions required  
data it can access  
risk level

---

## 14. Apple Home

Implement HomeKit integration as a first-class Harness connector.

Allow GOD to reason about Home state and execute authorized actions.

Examples:

"Turn downstairs lights off."

"I'm coming home."

"Set the house for movie night."

Create separate permissions for low-risk and sensitive actions.

Unlocking doors, opening garages and security-related actions should require stronger confirmation by default.

---

## 15. Harness Keyboard

Create a system-wide custom keyboard extension optimized around dictation rather than replacing normal typing.

Add a compact top control layer similar conceptually to Diction/Typeless/Superwhisper/WhisprFlow:

🎙 Dictate | Fix | Rewrite | Ask Harness

Prefer on-device speech recognition/models when possible.

Offer selectable transcription routing:

On Device  
My Computer  
Cloud

Dictated audio should not be retained by default.

Allow selected text to be sent to GOD for rewriting or actions, subject to keyboard-extension privacy restrictions.

---

## 16. Red

Build **Red**, Harness's public social/skill discovery layer.

Red should not primarily be a generic social feed.

Its main social object is a runnable agent, skill or workflow.

Card example:

Screenshot Janitor  
Photos → Vision → Notes → Cleanup

4 tools  
Local compatible  
Privacy: Low risk

[Run] [Fork]

♡ 437   💬 52   1.8K runs

Users may:

post  
comment  
like  
share  
fork  
install  
run

Before installing anything, display requested capabilities and network access.

Downloaded skills must never silently gain native execution privileges.

---

## 17. Agents

Create an **Agents** section containing specialist agents.

Each agent has:

Name  
Purpose  
AGENTS.md  
Allowed skills  
Preferred model  
Allowed connectors  
Permission profile  
Memory scope

Examples:

Researcher  
Coder  
Home Manager  
Travel Agent  
Real Estate Analyst

GOD may delegate to these agents.

Users may also talk directly to one.

No subagent automatically inherits GOD's complete permission set.

---

## 18. Privacy Dashboard

Create:

Settings → Privacy

Make privacy observable rather than policy-only.

Show:

current app permissions  
connected providers  
network destinations  
recent data transmissions  
local versus cloud model usage  
credential-storage status  
installed connectors  
recent sensitive actions  
learning activity

Include a visible user-editable audit prompt:

"Act as a security and CTF researcher. Inspect Harness for vulnerabilities and determine whether my data is transmitted, retained, logged or exposed. Show evidence for every finding and distinguish verified findings from assumptions."

[Run Privacy Audit]

The audit must combine deterministic application/network inspection with LLM interpretation.

Never claim an LLM audit alone proves security.

---

## 19. Activity / Audit Trail

Record agent actions in an understandable local audit trail.

Example:

10:42 GOD asked Researcher to investigate X.

10:43 Researcher loaded web-research.

10:44 OpenRouter received this selected context.

10:45 GOD requested computer filesystem access.

10:45 User approved once.

10:46 MacBook read ~/Projects/Harness/package.json.

Every important external action should be reconstructable.

Allow users to inspect what data was sent to a model/provider.

---

## 20. SSH

Add SSH as an optional advanced connector.

Store private keys securely.

Support terminal sessions and agent-assisted diagnosis.

Classify commands into risk levels.

Read-only diagnostic commands may be auto-approved based on user settings.

Potentially destructive commands require confirmation.

GOD should be able to delegate SSH work to a specialist agent without giving that agent unrelated device permissions.

---

## 21. Sessions

Persist conversations and agent execution state locally.

Use a structured local store such as SQLite for sessions, task state, tool calls and learning metadata.

Preserve:

conversation messages  
agent delegation  
tool calls/results  
model/provider used  
token/cost information where available  
permissions granted  
learning outcomes

Support resume and search.

Implement context compression inspired by Hermes: preserve recent turns and critical tool-call/result pairs while summarizing older context.

---

## 22. Offline Mode

Harness must remain useful without a network connection.

Offline mode should support whatever the device can handle, such as:

basic GOD conversations  
local memory search  
skill retrieval  
local dictation  
Home control on local network where available  
local utility tools

Clearly identify actions unavailable because they require cloud APIs.

Do not pretend connectivity exists.

---

## 23. Privacy Philosophy

Harness should collect no unnecessary analytics or behavioral data.

Prefer local-first storage.

Do not monetize user prompts, memory or agent activity.

Do not use conversations for advertising.

Expose exactly which provider receives information before or after a request.

Cloud usage should be optional wherever technically reasonable.

Open-source the client and core agent architecture so technically sophisticated users can inspect behavior.

---

## 24. Initial Navigation

Use four primary tabs:

**GOD**  
Main conversation, active goals and primary orchestration.

**Agents**  
Installed specialist agents, skills and active work.

**Red**  
Discover, share and fork agents/skills/workflows.

**Me**  
Settings, models, devices, connectors, memory, Journey, privacy and account.

The keyboard operates system-wide and is therefore not a primary tab.

---

## 25. Security Principle

Treat every LLM as untrusted decision-making software operating inside a trusted deterministic security shell.

The LLM may decide:

"I want to call home.unlockDoor."

The Permission Kernel decides whether that call can occur.

The LLM may decide:

"I should remember this."

The Learning Kernel determines whether the proposed write requires approval.

The LLM may decide:

"I need this credential."

The Credential Store provides the authorized operation without revealing the secret.

No prompt, skill, downloaded agent, Red post or model response may override these boundaries.

---

## 26. MVP Priority

For the first usable build, prioritize:

GOD chat orchestration  
OpenRouter + local model routing  
Keychain credentials  
SOUL.md / USER.md / MEMORY.md / AGENTS.md  
Hermes-style skills  
Learning Reviewer  
Journey  
Permission Kernel  
computer QR pairing  
basic paired-computer tools  
Red prototype  
Privacy dashboard

Do not begin by supporting every Apple integration.

First prove the core loop:

Ask → Reason → Use skill/tool → Act → Evaluate → Learn → Reuse learning.
