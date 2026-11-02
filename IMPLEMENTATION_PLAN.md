# StudyApp — Implementation Plan

**Version:** 1.1 — November 2, 2026
**Document type:** Product specification and technical implementation plan.
**Platform:** Native macOS app, Swift 6 and SwiftUI.
**Documents:** PDF and DOCX.
**Models:** user-configured OpenAI-compatible endpoints.
**Answer input:** typed, or speech transcribed locally or through a custom endpoint.

Version 1.1 adds the **study focus** feature: after importing a document the
student can name a subject, chapter, or subtopic inside that file, the app
searches only that file and shows what it matched, and every question, rubric,
hint and assessment is restricted to the confirmed passages.

## 0. Goal and fundamental rule

Build a focused active-learning app: import **one document**, start a study
session, answer questions drawn from that document, receive an assessment with
corrections or hints, review the topics that proved difficult, and — in this
version — choose the **focus** inside the document.

This is not a general-purpose chatbot. It must not add the model's general
knowledge to the material.

**Product invariant:** no question, expected answer, explanation, correction or
hint may be presented as grounded in the document unless it has verifiable
supporting passages in the active document, inside the confirmed study scope.
A prompt alone cannot guarantee that; the app enforces it through source
preparation, an explicit allowlist, local validation and the ability to refuse.

## 1. End-to-end user flow

1. **First launch:** minimal welcome; configure a provider (URL, API style,
   model, key) with a real connection test; choose speech input; microphone
   permission is requested only on first use.
2. **Empty home:** “Study a document”, drag-and-drop, “Choose PDF or DOCX”.
3. **Import:** copy into app-owned storage, parse off the main thread, identify
   sections, run OCR only where needed, show progress and extraction coverage.
4. **Ready state:** document title, length, sections, extraction warnings, and
   **“What do you want to study?”** with document-derived suggestions. Empty
   means the entire document. The app searches only this file and previews the
   matched sections/pages (PDF) or headings/paragraphs (DOCX); uncertain matches
   are confirmed by the student. Starting a session records the confirmed
   `StudyScope`. “Full study” is the default; “Review weak areas” is offered when
   there is history inside the focus.
5. **Question:** one at a time, with a persistent but discreet focus label, no
   answer before the attempt, and no detailed source references before feedback.
6. **Answer:** multiline editor and microphone; recording produces an editable
   transcript; the student explicitly submits.
7. **Feedback:** outcome, concise explanation, correct and missing elements,
   incorrect statements, clickable page/paragraph references. Offer “Hint”,
   “Try again”, “Show answer from document”, “Next question”, and flagging of a
   wrong assessment.
8. **Changing focus:** “Change topic” or “Entire document” applies to later
   questions only. Earlier questions, rubrics, answers and assessments keep
   their original scope and are never re-graded or moved.
9. **Finish and resume:** summary, persisted history, interrupted sessions
   resume with their question, draft and focus.

**UX rule:** never require categories, difficulty levels or question counts to
begin. Advanced options stay in Settings or a lightweight popover.

## 2. Interface and design system

Native macOS: SwiftUI with targeted AppKit (PDFView, NSOpenPanel). Resizable
window, readable study column capped near 820 points, semantic colors and
materials, one restrained accent, San Francisco typography, short animations
that honor Reduce Motion, explicit empty/loading/error states, and a sidebar
with Documents, History and Settings that can be hidden during focused study.

Screens:

| Screen | Essential elements |
|---|---|
| Home / Documents | Import, drag-and-drop, recent files, indexing status, resume, delete |
| Ready / Focus | document summary, extraction coverage and warnings, “What do you want to study?”, suggestions, match preview with confirmation, full study or review, resume |
| Study | focus label, question, answer, microphone, submit, feedback, hint, source reference, change topic |
| Source viewer | PDFView on a real page; DOCX read-only extracted paragraphs with references |
| History | sessions, dates, document, focus, question, answer, raw transcript, outcome, evidence, filters |
| Settings / AI Model | profiles, URL, API style, model, Keychain-backed key, connection test, removal |
| Settings / Speech | engines that actually run, language, download/remove, local engines, custom endpoint |
| Settings / AI Instructions | editable AGENT.md, save, versions, preview, restore defaults |
| Settings / Data | clear data, storage path, privacy, what leaves the Mac |

Accessibility: VoiceOver labels, visible focus, full keyboard navigation,
system contrast, non-disruptive announcements when transcription or evaluation
finishes, and a complete session without a mouse.

Shortcuts: `⌘O` import, `⌘↩` submit, `⌘,` Settings, `Esc` cancel recording,
`⌘R` record/stop, `⌘.` end session. Space is deliberately not bound: with a text
editor focused it would be ambiguous.

## 3. Technology stack

- Swift 6 compiler, Swift Concurrency (`async`/`await`, actors), SwiftPM.
- SwiftUI; AppKit for PDFView and file panels.
- macOS 14+ deployment target; Apple Silicon primary. Local Parakeet models
  require Apple Silicon and are reported unavailable elsewhere.
- PDFKit for page-aware extraction; Vision for on-device OCR.
- DOCX: ZIPFoundation for the OOXML package, Foundation `XMLParser` for XML.
  No external converters, no macros, no remote resources.
- SQLite through GRDB with migrations; FTS5 only when the runtime SQLite
  proves support by creating a probe table.
- Keychain for credentials; URLSession for HTTP; AVFoundation recording; Speech
  framework for Apple on-device recognition; FluidAudio for Parakeet models.
- Local retrieval by topic and scope allowlist; FTS5/BM25 when available, with a
  deterministic lexical fallback.

## 4. Codebase layout

```text
StudyApp/
├── Package.swift
├── IMPLEMENTATION_PLAN.md       # this document (v1.1)
├── README.md
├── Resources/Info.plist
├── Scripts/build-app.sh
├── Docs/
│   └── TESTING.md
├── Sources/
│   ├── StudyApp/                # bootstrap, navigation, views, view models
│   ├── StudyDomain/             # entities, scopes, errors, scoring, protocols
│   ├── StudyPersistence/        # GRDB schema, migrations, repositories
│   ├── StudyDocuments/          # PDF/DOCX import, OCR, chunking, provenance
│   ├── StudyRetrieval/          # evidence retrieval, topic catalog, scope resolver
│   ├── StudyProviders/          # LLM + remote STT adapters, Keychain, transport
│   ├── StudyPrompts/            # AGENT.md loading, versions
│   ├── StudyEngine/             # scoped question generation, evaluation, hints
│   ├── StudySpeech/             # recorder, Apple on-device, Parakeet, model manager
│   └── StudyDesignSystem/       # narrow shared UI components
└── Tests/
    ├── DocumentParsingTests/
    ├── GroundingTests/
    ├── ProviderTests/
    ├── EvaluationTests/
    ├── PersistenceTests/
    └── UIBasicsTests/
```

Essential protocols: `DocumentImporter`, `EvidenceRetriever`, `LLMProvider`,
`SpeechTranscriber`, `StudyRepository`, `PromptRepository`. Scope resolution is
a plain, testable `StudyScopeResolver`.

Responsibility boundaries:

- `DocumentImporter` produces `DocumentSnapshot`, sections and provenance-aware
  `SourceChunk` records; never calls a model.
- `EvidenceRetriever` returns only usable passages from one snapshot and an
  authorized set.
- `StudyScopeResolver` maps free text to real chunk ids and persists confirmed
  scopes. Deterministic, local, no model.
- `StudyEngine` selects topics inside the scope, assembles prompts, validates
  output, handles sessions, hints and review; no HTTP.
- `LLMProvider` handles transport, authentication, timeouts, retries, decoding.
- `SpeechTranscriber` converts audio to text; never grades.
- `StudyRepository` owns records and migrations.
- `PromptRepository` loads AGENT.md, records versions.

## 5. Document import and preparation

### PDF

1. Read pages with PDFKit off the main thread.
2. Extract text with real page numbers and offsets.
3. Assess quantity and quality; where text is missing or clearly unreliable,
   render the page and run Vision OCR on-device.
4. Mark OCR origin and recognition confidence; exclude low-confidence material
   from evidence.
5. Figures and diagrams are not interpreted; anything without extractable text
   is uncovered and cannot become a question.

### DOCX

1. Validate the ZIP package; enforce size, entry count, expansion and ratio
   limits against ZIP bombs and malformed archives.
2. Read `word/document.xml`, styles and relationships; extract headings,
   paragraphs, lists, tables and notes in order.
3. Preserve paragraph indices and table cell order; never concatenate XML in a
   way that destroys meaning.
4. Do not invent page numbers; cite paragraph positions.
5. Warn about drawings, embedded objects, macros and ignored headers/footers.

### Normalization, chunking, provenance

A `DocumentSnapshot` holds file hash, type, import time, language, sections,
quality and the normalized text. Chunks are contiguous ranges of that text with
`chunk_id`, `snapshot_id`, `section_id`, offsets, page or paragraph reference,
extraction method and quality. Targets are roughly 400–900 tokens with a small
sentence overlap, always splitting at natural boundaries. Imports report, for
example, “54 pages processed; 3 required OCR; 2 contain unreadable material.”
Insufficient reliable text blocks study with an explanation.

## 6. Strict grounding and the study scope

### Scope resolution (new in v1.1)

`StudyScopeResolver` is deterministic and local:

1. Normalizes the student's wording (case, diacritics, punctuation) and keeps
   content words plus chapter/section numbers.
2. Scores every usable chunk in the snapshot with token containment, section
   title containment and an exact-phrase bonus; chapter references
   (“chapter 3”, “capitolo 3”, “section 2.1”) match heading numbering.
3. Sections are scored by their best chunk. The best sections are selected, all
   their usable chunks are included up to a cap, and the result is either
   `found`, `ambiguous` (near-tied sections), `notFound` or `fullDocument`.
4. `notFound` always displays **“This topic was not found in the uploaded
   document.”** and offers rewording or the entire document. The app never asks
   the model for a topic it could not locate.

Confirmation persists a `StudyScope`:

```json
{
  "id": "scope_…",
  "snapshotId": "snapshot_…",
  "query": "action potentials",
  "title": "Action potential",
  "matchedChunkIds": ["chunk_12", "chunk_13"],
  "isFullDocument": false,
  "version": 1,
  "confirmedByUser": true
}
```

The scope is an immutable snapshot reference plus an **allowlist** of chunk ids.
`EvidenceRetriever`, question generation, rubric validation, evaluation, hints,
review and the source viewer all check that allowlist. A citation outside it is
rejected.

### Topic cataloging and question generation

Topics are built locally from recognized headings and passages, grouped
conservatively; every topic has a non-empty set of real chunk ids. Inside a
scope, only topics that intersect the allowlist are eligible, and their
authorized chunk ids are the intersection. One question at a time is generated
from those excerpts with an expected answer and essential points, each tied to
supplied chunk ids.

Validation before display checks:

- schema and required fields;
- the topic id is the requested one;
- every cited id exists in the supplied evidence (and therefore in scope);
- each expected point shares real content with the passage it cites;
- the question is not a duplicate of earlier questions on the document;
- `answerability` is `supported`, otherwise the topic is skipped and another is
  tried.

If validation cannot establish support, the engine regenerates from different
chunks or refuses with an explanation. A syntactically valid id is not proof of
support; the local overlap check is the necessary second step.

## 7. Assessment and hints

1. Typed or dictated answers become an editable `AnswerAttempt`; speech is never
   graded differently and never auto-submitted.
2. The evaluator receives the question, its frozen rubric, the answer, the
   authorized excerpts and AGENT.md. No web, no other documents.
3. It judges meaning, not wording; negations, reversed causality, changed
   conditions and unsupported additions are errors.
4. Structured JSON is required and then validated in Swift: status, point ids,
   missing ids, incorrect statements, feedback, evidence ids, clarification.
5. Inconsistent or invalid output becomes `not_evaluable` with a retry; a
   transport failure leaves history unchanged and the draft intact.
6. Results are stored with provider, model, document version, prompt version and
   timestamp. The student's override is stored separately from the original.

Outcomes: `correct` (all essential points, no material contradiction),
`partial` (some points or imprecision), `incorrect` (key concepts wrong,
reversed or off-topic), `not_evaluable` (insufficient material, faulty question,
ambiguous answer, or unverifiable assessment). Internal scoring uses
`correct = 2`, `partial = 1`, `incorrect = 0`; `not_evaluable` is excluded.

Hints are generated only on request, at two levels, from authorized excerpts
only. “Show answer from document” presents the frozen expected points and the
stored passages; no new model call.

## 8. Configurable LLM providers

Profiles store display name, base URL, API style (`chat_completions` or
`responses`), exact model id, Keychain reference, non-secret extra headers,
timeout and bounded retries. Keyless local servers are supported. “Test
connection” makes real requests and verifies authentication, endpoint, model
and parseable output, then probes structured JSON. Errors 401/403/404/429,
timeouts and malformed JSON are translated into plain messages. Response-format
fallback is allowed (json_schema → json_object → text, validated locally);
changing the provider is never allowed silently.

OpenCode Go additionally requires a stable per-conversation `x-opencode-session`
header, which the app sends automatically for `opencode.ai` hosts, along with an
honest `StudyApp/…` user agent. The app never impersonates a coding agent.

HTTPS is required for remote hosts; plain HTTP is accepted only for loopback.
Credentials never appear in logs or the database. Redirects to another host drop
the Authorization header; redirects to plain HTTP outside loopback are refused.
The app discloses that remote providers receive the relevant excerpts, the
question, the rubric and the answer.

Example configurations (each must pass the real capability test):

| Provider | Example | Caveat |
|---|---|---|
| OpenRouter | `https://openrouter.ai/api/v1` | Verify the model supports the chosen operation and output format |
| Local server | `http://localhost:8000/v1` | Key optional; test the exact model and format |
| Other compatible | user URL | “OpenAI-compatible” does not imply every endpoint or JSON feature |
| OpenCode Go | `https://opencode.ai/inference/go/openai/v1` | Requires a stable `x-opencode-session` header (sent automatically); use an OpenAI-style model such as `gpt-5.6-luna` (Responses) or `glm-5.3` (Chat Completions); intended for coding agents, check their terms |

The app does not promise that any subscription grants API access, and does not
impersonate a coding agent to bypass provider restrictions.

## 9. Speech transcription

Speech is an input method, not a second grading system. Supported engines in
this build:

| Engine | Intended use | Requirements |
|---|---|---|
| Apple on-device | System-managed recognition | Language assets; `requiresOnDeviceRecognition = true` |
| Parakeet Ultra | Preferred local multilingual (25 European languages) | FluidAudio, explicit download, Apple Silicon |
| Parakeet TDT v3 | Local multilingual alternative | FluidAudio, explicit download |
| Parakeet TDT v2 | English-oriented | Never labelled as Italian-capable |
| Parakeet TDT-CTC 110M | Smaller English model | FluidAudio |
| Parakeet Japanese | Japanese | FluidAudio |
| Whisper models | Broad multilingual | Not linked in this build; listed as unavailable rather than promised |
| Custom endpoint | Remote transcription | Separate URL, model and key; multipart `/audio/transcriptions` |

Only engines that genuinely run are selectable. Downloads are explicit with
progress and removal; local engines never fall back to cloud transcription.

Recording uses AVAudioRecorder with permission requested at first use, timer and
cancel via `Esc`. Audio is converted off the main thread, transcribed by the
selected engine, inserted as editable text, and deleted afterwards. History keeps
the transcript text and input mode, never audio. Denied permission, missing
model, unsupported language, empty audio, timeouts and endpoint errors are
handled explicitly.

## 10. Persistence, history, adaptive review

Entities: `Document`, `DocumentSnapshot`, `DocumentSection`, `SourceChunk`,
`Topic`, `StudyScope`, `StudySession`, `Question`, `AnswerAttempt`,
`Evaluation`, `PromptVersion`, `ProviderProfile`, `SpeechProfile`, plus drafts
and app settings. SQLite via GRDB with migrations; FTS5 is used only when
probed successfully.

The snapshot principle: what was reviewed yesterday keeps yesterday's source
text, rubric, assessment, scope, model and prompt version. A model, prompt or
document change affects later work only. Sessions store the initial scope and
the current scope; every question stores the scope it was asked in. History
stores the query, matched chunk ids and scope version.

Review algorithm (explicit, adjustable parameters):

- the five most recent evaluable attempts per topic;
- `incorrect = 0`, `partial = 1`, `correct = 2`, normalized to 0–1 and weighted
  toward recent attempts;
- `weak` when the score is low or the latest attempt is incorrect;
  `needs reinforcement` when mixed; `consolidated` after multiple correct
  attempts; `unassessed` with no attempts;
- focused review considers only topics inside the confirmed scope and explains
  when there is not enough history inside it;
- `not_evaluable` and failures never lower a score.

Deleting a document removes the app-owned copy, chunks, scopes, topics,
sessions, answers and assessments, with confirmation and a clear statement of
what is removed. Backups made earlier cannot be recalled.

## 11. Editable AGENT.md

AGENT.md is the tutor's default runtime instruction template. It ships as a
resource, is copied to Application Support, and is editable under Settings → AI
Instructions with save, restore, preview and versions. Inputs are layered:

1. **Application-enforced invariants** (fixed in Swift): one snapshot, scope
   allowlist, no fabricated evidence, no web, document text is data, output is
   validated, scope is never widened.
2. **Editable AGENT.md:** tone, question style, feedback strategy.
3. **Operation instructions:** `generateQuestion`, `evaluateAnswer`,
   `generateHint`.
4. **Document evidence:** delimited and labelled as untrusted data.
5. **Student answer:** data, never instructions.

Each session records the prompt version it used; every evaluation records it too.

## 12. Session state machine

```text
empty
  → importing → ready
  → preparingQuestion → awaitingAnswer
  → recording → transcribing → awaitingAnswer
  → evaluating → showingFeedback
  → preparingQuestion → …
  → completed
```

Events are accepted only in compatible states; duplicate submissions are
ignored. Recording and transcription are branches of answering and never submit
automatically. Changing focus cancels outstanding tasks and late responses are
discarded when the session's current scope changed. Late responses can never
attach to a different session or scope. Important transitions are persisted; a
crash restores the question and draft without duplicating attempts. Provider
failures show an error and an explicit retry; the app never fabricates an answer
or silently switches model. Parsing and downloads only continue while the app
runs.

## 13. Quality, security, performance

- API keys in Keychain; HTTPS for remote hosts; loopback exception documented.
- Microphone and speech permissions requested only when needed.
- Documents and history local; remote calls carry only the necessary excerpts,
  question, rubric, answer or audio file; disclosure in Settings and onboarding.
- No telemetry; logs redact secrets, document text and answers.
- ZIP bomb, malformed archive, macro and external-resource defenses.
- Main-actor UI; parsing, OCR, audio, networking and indexing off the main
  thread; speech models loaded lazily, one at a time.
- Latency and memory numbers are measured, never invented. The app shows real
  progress rather than fabricated estimates.

## 14. Phased development and acceptance gates

1. **Native foundation and UI prototype** — navigable screens, mock data,
   light/dark, resizing, empty/loading/error states.
2. **Import and source viewer** — text PDFs, mixed/scanned PDFs with OCR, DOCX
   with headings/tables/notes, provenance, migrations; every chunk resolves to a
   real page or paragraph; dubious material flagged and excluded.
3. **Provider and first session** — adapters, Keychain, real connection test,
   topics, local retrieval, scoped question generation and validation; provider
   changes never contaminate a running session.
4. **Grading, citations, AGENT.md** — frozen rubrics, four outcomes, hints,
   solutions, source references, prompt versions; golden tests for paraphrase,
   omission, negation, unsupported additions and prompt injection.
5. **Study focus (v1.1)** — free-text focus, document suggestions, match preview
   with confirmation, “not found” behavior, allowlisted retrieval and grading,
   persistent focus label, change of focus without moving history, scoped review.
6. **Spoken answers** — recording, permissions, verified local Parakeet, Apple
   on-device, custom endpoint, downloads, editable transcripts.
7. **History and adaptive review** — durable sessions, resume, filters, scoped
   progress and review, deletion, overrides, older-version flags.
8. **Polish and distribution** — accessibility, shortcuts, signing,
   notarization, dependency/model license audit, README and privacy docs.

Required sequencing: parsing and evidence references first, then scoped question
generation, then grading, then speech, then history-based review.

## 15. Test strategy

A controlled corpus of small PDFs and DOCX files with known facts, plus real
study documents for manual checks. Unit tests for parsers, chunking, scope
matching, validators and scoring; mock HTTP for provider integration; opt-in
real-provider tests with keys from the environment or Keychain, never in public
CI.

Required cases include:

| Case | Expected |
|---|---|
| Document states only A and B | No question or answer introduces C |
| Correct answer in different words | `correct` |
| Answer includes A but omits B | `partial` with missing point |
| Reversed causality or negation | `incorrect` despite keywords |
| Irrelevant answer | `incorrect`, or `not_evaluable` if the question is faulty |
| Nonexistent chunk id | Reject question or feedback; no fake source |
| Topic absent from the file | “This topic was not found…”, no model-generated question |
| Ambiguous topic wording | Student confirms passages before studying |
| Focus changed mid-session | Old answers keep their scope; new questions use the new one |
| Prompt injection inside a document | Treated as data |
| Ambiguous OCR | Warned and excluded from evidence |
| DOCX table | Cell order and row association preserved |
| Document switched with a request pending | Old response discarded |
| Interrupted recording or failed STT | Never submits an answer |
| API 401/403/429/timeout | Clear error, intentional retry, unchanged history |
| Crash and reopen | Draft, attempt and evidence preserved |
| Delete document | App-owned file, chunks, scopes, history removed as disclosed |
| Keyboard-only session | Complete without a mouse |

Measure rather than invent: validated-evidence rate, fabricated citations
(target zero), grading agreement on an annotated set, false positives and
negatives, crash frequency, import time, provider latency, transcription
latency, memory and model cache size.

## 16. MVP release criteria

1. Configure a provider and pass a real connection test.
2. Import PDF/DOCX, preserve verifiable structure, see OCR limitations.
3. Enter a focus (or choose the whole document), confirm matches, and receive
   one scoped question at a time with real supporting passages.
4. Answer by typing and by microphone using at least one verified local
   Parakeet model.
5. Receive correct/partial/incorrect/not evaluable with readable feedback and a
   real source reference inside the focus.
6. Request a hint, change focus deliberately, and continue without leaking
   context across questions, scopes or documents.
7. Reopen the app without losing history, drafts or progress.
8. Choose “Review weak areas” inside a focus and receive grounded questions.
9. Edit AGENT.md, restore defaults, and inspect the version used by a session.
10. Use the app without an embedded web browser or proprietary backend.

Not release criteria: “the AI is always right”, “every provider works without
adaptation”, “every scanned page is understood”.

## 17. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Questions drift outside the requested topic | Immutable scope allowlist, deterministic resolver, local validation, refusal |
| Model rejects a valid paraphrase | Semantic evaluation tests, explainable feedback, student override |
| Complex figures | Coverage warnings; never interpret unextracted images |
| Partial provider API | Separate adapters, capability tests, explicit errors |
| Incompatible speech model or Mac | Runtime availability, hardware gating, honest catalogue |
| Misheard speech | Editable transcript; identical grading path |
| AGENT.md breaks JSON | Fixed invariants plus local schema validation |
| Cloud cost or disclosure | Minimal excerpts, explicit provider choice, disclosure |
| Unnecessary complexity | Single native app, internal modules, no services |

## 18. Implementation status (this repository)

Implemented and covered by tests:

- SwiftPM modules, GRDB schema and migrations, FTS5 probe, repository.
- PDF text extraction, page-aware OCR with confidence and exclusion, DOCX OOXML
  parsing with limits, chunking with provenance.
- Provider profiles, Keychain, URL policy, redirect guard, chat/responses
  adapters, retries, format fallback, connection test, remote STT.
- Topic cataloging, scope resolver and allowlist, scoped question generation and
  validation, evaluation and hint validation, four outcomes, overrides, review
  scoring, sessions and resume, drafts.
- SwiftUI screens: library, ready/focus, study, feedback, source viewer, history,
  settings, onboarding; keyboard shortcuts and accessibility labels.
- Apple on-device speech, recorder, model manager, Parakeet engines through
  FluidAudio (download and runtime availability handled explicitly).
- AGENT.md editing, versions, restore; this plan and TESTING.md.

Verified during development:

- The full automated suite (78 tests) passes, including a real on-device OCR
  run over a rendered scanned page.
- Parakeet TDT-CTC 110M was downloaded and used to transcribe synthesised
  speech on device (opt-in test); the other Parakeet variants share the same
  code path but were not each downloaded in this build.
- The release bundle launches and creates its library with the scope table,
  FTS5 index, AGENT.md and a prompt version.

Requires real-world verification, and is documented as such:

- A genuine provider connection test with the user's own key and model; the
  automated tests use a mock transport.
- Accuracy and latency of Parakeet models on real student speech, and the
  larger Parakeet variants not downloaded here.
- Whisper engines, which are not linked in this build and are reported as
  unavailable instead of being offered as working.
- Notarized distribution and the final dependency/model license audit.
