# StudyApp

A native macOS study app that asks document-grounded questions about **one
document at a time**, grades your answers against that document, and lets you
focus on a specific subject, chapter or subtopic inside the file.

This is not a chatbot. Every question, expected answer, hint and correction is
tied to passages that exist in the imported document, inside the scope you
confirmed. If the app cannot find your topic in the file, it says so instead of
answering from general knowledge.

## What it does

- Imports text and scanned PDFs (on-device OCR with quality warnings) and DOCX
  files (headings, paragraphs, lists, tables, notes) into app-owned storage.
- Extracts verifiable passages with PDF page numbers or DOCX paragraph
  positions, and shows extraction limits instead of guessing.
- Lets you name a focus in your own words — “action potentials”, “chapter 3”,
  “the roles of voltage-gated sodium channels” — searches only the file, shows
  the matched passages, and asks you to confirm uncertain matches.
- Generates one question at a time from those passages, with a frozen rubric and
  source links, using your own OpenAI-compatible provider.
- Accepts typed or dictated answers. Speech is transcribed locally (Apple
  on-device or Parakeet models) or by a custom endpoint, inserted as editable
  text, and never submitted automatically.
- Grades as correct, partial, incorrect or not evaluable, with concise feedback,
  hints at two levels, the answer from the document, and clickable sources.
- Keeps history, per-topic progress and focused review of weak areas, with the
  original assessment preserved when you override it.
- Lets you edit the tutor instructions (`AGENT.md`), restore defaults, and see
  which version a session used.

## Requirements

- macOS 14 or later; Apple Silicon recommended (required for local Parakeet
  models).
- Xcode 16 or later with a Swift 6 toolchain to build from source.
- An OpenAI-compatible endpoint for question generation and grading, or a local
  server. API keys are stored in the macOS Keychain.

## Build and run

```bash
swift build              # build everything
swift test               # run the automated suite
./Scripts/build-app.sh   # assemble dist/StudyApp.app (release, ad-hoc signed)
open dist/StudyApp.app
```

The app needs a real app bundle for microphone and speech permissions; running
the raw binary from `swift run` is not recommended for speech features.

## First run

1. Add a provider: base URL, API style (Chat Completions or Responses), exact
   model id and API key. Press **Save and test**; the app makes real requests and
   verifies authentication, the model and JSON output.
2. Optionally choose a speech engine. Downloads are explicit and local.
3. Import a PDF or DOCX, type what you want to study (or leave it empty), confirm
   the matched passages, and start.

## Using OpenCode Go

OpenCode Go exposes OpenAI-compatible endpoints. In **Settings → AI Model** use:

- **Base URL:** `https://opencode.ai/inference/go/openai/v1`
- **API style:** `Responses` for `gpt-5.6-luna`, `gpt-6-luna`, `grok-4.7`, or `Chat Completions` for `glm-5.3`, `kimi-k3`, `deepseek-v4.1-flash` and the other chat-completions models.
- **Model ID:** the exact id from OpenCode's model table, for example `gpt-5.6-luna` or `glm-5.3`.
- **API key:** the OpenCode Go key (`oc_sk_…`).

The app sends a stable `x-opencode-session` header per study session (required
by OpenCode for routing and prompt caching) and identifies itself with an honest
`StudyApp/…` user agent. It does not impersonate the OpenCode client. If you have
your own session value, add it as an `x-opencode-session` extra header and the
app will use yours.

Models whose endpoint is `/anthropic/v1/messages` or `/google/v1beta/...`
(for example `claude-haiku-5-5`, `gemini-4-argon`, `qwen3.8-max`) are not
reachable through this app's OpenAI-compatible adapters.

**Caveat:** OpenCode Go is intended for OpenCode and similar coding agents and
monitors traffic for abuse. Check its terms for third-party clients. If your
plan or endpoint refuses non-coding clients, use OpenRouter, a local
OpenAI-compatible server, or another provider instead.

## Project layout

```text
Package.swift                  SwiftPM package (modules + app executable)
IMPLEMENTATION_PLAN.md         Product and technical plan, v1.1
Docs/TESTING.md                Test strategy, manual checks, measurements
Resources/Info.plist           App bundle metadata and privacy strings
Scripts/build-app.sh           Builds and signs the .app
Sources/
  StudyApp/                    SwiftUI app, view models, AppKit bridges
  StudyDomain/                 Entities, scopes, errors, scoring, protocols
  StudyPersistence/            GRDB schema, migrations, repository
  StudyDocuments/              PDF/DOCX import, OCR, chunking
  StudyRetrieval/              Evidence retrieval, topic catalog, scope resolver
  StudyProviders/              LLM + remote STT adapters, Keychain, transport
  StudyPrompts/                AGENT.md loading and versions
  StudyEngine/                 Scoped generation, validation, evaluation, hints
  StudySpeech/                 Recorder, Apple on-device, Parakeet, model manager
  StudyDesignSystem/           Small shared UI components
Tests/                         Six suites, no network or keys required
```

## Privacy

Documents, extracted passages, scopes, sessions and answers live in
`~/Library/Application Support/StudyApp/`. API keys live in the Keychain. When a
remote model is active, only the passages needed for the current question or
assessment, the question, the rubric and your answer are sent to that provider.
When a custom speech endpoint is active, the audio recording is sent there;
local engines stay on this Mac. There is no telemetry and no app backend.

## Honest limitations

- Whisper engines are not linked in this build. They are reported as unavailable
  instead of being offered as working; the protocol and UI are ready for a
  verified integration.
- Local Parakeet models need an explicit download (hundreds of megabytes) and
  Apple Silicon. The TDT-CTC 110M model is verified on device with synthesised
  speech; accuracy and latency on real student speech, and the larger variants,
  are not benchmarked here.
- DOCX has no stable page numbering; references use paragraph positions.
- Questions about figures and diagrams are not supported unless their content is
  extractable text.
- A model's assessment can still be wrong; the app validates structure and
  support, shows its evidence, and lets you override the verdict while keeping
  the original.
- The app is not notarized in this repository; use your own Developer ID and
  notarization for distribution.

## Third-party components and inspiration

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite toolkit (MIT).
- [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) — ZIP access (MIT).
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet Core ML
  inference (Apache-2.0), pinned to a specific revision.
- BetterWispr was studied as a design reference for native dictation; no source
  code is copied here. Its Apache-2.0 notices apply to that project, not to this
  one.

Model weights downloaded through FluidAudio are governed by their own licenses;
review them before redistribution.

## Documentation

- `IMPLEMENTATION_PLAN.md` — the full product and technical plan (v1.1).
- `Docs/TESTING.md` — automated suites, manual acceptance checks, measurement
  log.
- `Sources/StudyPrompts/Resources/AGENT.md` — the default tutor instructions,
  also editable in the app.
- `Docs/LICENSES.md` — third-party license audit and distribution checklist.
