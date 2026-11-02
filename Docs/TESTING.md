# Testing

## Automated suites

Run everything:

```bash
swift test
```

The suite is split by responsibility:

| Suite | Covers |
|---|---|
| `DocumentParsingTests` | chunk offsets against the snapshot text, unusable/OCR provenance, DOCX headings/paragraphs/tables/notes, DOCX archive limits and malformed packages, text-PDF page numbers, empty-PDF refusal, quality heuristics, and a real on-device OCR run over a rendered scanned page |
| `GroundingTests` | scope matching (found, not found, ambiguous, chapter numbers, whole document), question contract validation, scope allowlist in generation and grading, focus changes preserving old questions, scope persistence |
| `ProviderTests` | URL/HTTPS policy, endpoint resolution, Chat Completions and Responses parsing, 401/403/404/429/timeout mapping, bounded retry, response-format fallback without changing model/provider, OpenCode Go endpoint resolution and `x-opencode-session` header scoping, honest user agent, connection test, remote STT multipart, Keychain reference handling |
| `EvaluationTests` | evaluation schema and rubric consistency, paraphrase/omission/negation handling, unknown citations, `not_evaluable` fallback and retry, transport failure leaving no history, grounded hints, review scoring, overrides preserved separately, prompt injection treated as data |
| `PersistenceTests` | migrations and reopen, entity round-trips, provenance, scopes and question scope, drafts, history filters, effective status, cascade deletion, data clearing, FTS5 probe honesty, prompt versioning |
| `UIBasicsTests` | session state machine, duplicate submissions, recording branches, outcome labels and scoring, quality summary, scope/focus labels, review ordering, human-readable errors, AGENT.md invariants |

All parsing tests build their own fixtures in temporary directories: small DOCX
packages written with ZIPFoundation and PDFs drawn with Core Graphics. No test
depends on the user's files.

HTTP is mocked through `HTTPTransport`; no automated test needs a network
connection or an API key.

## Real-provider verification (opt-in, manual)

The automated suite cannot validate a provider you have not configured. To check
one:

1. Open Settings → AI Model, add the base URL, API style, exact model id and key.
2. Press **Save and test**. The app makes a real text request and a JSON request.
   Success means authentication, endpoint, model and parseable output all work.
3. Import a real document, choose a focus, and answer one question.
4. Confirm the provider's dashboard shows the request and that only the expected
   excerpts were sent.

Never commit keys. The app stores them in the macOS Keychain; tests use
`InMemorySecretStore`.

## Local speech verification (opt-in, manual)

- Apple on-device: choose the engine, record a sentence, check that the
  transcript appears in the editable answer field and that nothing was sent
  anywhere (the app sets `requiresOnDeviceRecognition`).
- Parakeet: download the model from Settings (hundreds of MB), then record an
  answer. Check the progress indicator, that the model is cached under
  Application Support, and that removing it works. On Intel Macs the engine must
  report itself unavailable instead of attempting to run.
- Custom endpoint: configure the URL and key, record, and confirm the transcript
  arrives and the temporary audio file is deleted.
- Deny microphone permission once and confirm the recording fails with an
  explanation instead of silently doing nothing.

## Manual acceptance checklist

UI and flow:

- [ ] First launch shows the welcome and provider setup; “Set up later” leaves the app usable.
- [ ] Import a PDF and a DOCX by drag-and-drop and by the file panel; progress is visible; the window stays responsive.
- [ ] Extraction coverage and warnings are shown; an unreadable document blocks study with a message.
- [ ] “What do you want to study?” suggests real sections; a matched request previews pages/paragraphs before studying.
- [ ] A topic absent from the file shows “This topic was not found in the uploaded document.” and never generates a question.
- [ ] Ambiguous wording asks for confirmation; deselecting passages narrows the focus.
- [ ] The focus label stays visible during the session; “Change topic” and “Entire document” work.
- [ ] A question answered in the old focus keeps its scope in History after changing focus.
- [ ] Feedback shows outcome, explanation, present/missing points, incorrect statements and clickable references.
- [ ] Hints are available at two levels; the first does not state the answer.
- [ ] “Show answer from document” shows stored points and passages only.
- [ ] Flagging an assessment changes what is displayed but the original verdict remains in History.
- [ ] Finishing shows a summary; reopening the app resumes an interrupted session with its draft and focus.
- [ ] Review weak areas inside a focus explains when there is not enough history.
- [ ] Deleting a document removes its copy, passages, scopes and history after confirmation.
- [ ] Clearing data keeps provider, speech and AGENT.md versions and explains what was removed.
- [ ] Light and dark appearance both look native; Reduce Motion is respected.

Keyboard and accessibility:

- [ ] `⌘O` import, `⌘,` Settings, `⌘↩` submit, `⌘R` record/stop, `Esc` cancel recording, `⌘.` end session.
- [ ] A complete session is possible without a mouse.
- [ ] VoiceOver announces question changes, transcription completion and assessment results.
- [ ] Focus rings are visible on every control.

Error handling:

- [ ] Wrong API key shows a 401 message, keeps history unchanged and offers an explicit retry.
- [ ] 429 shows the wait hint; timeout is retryable; 404 names the endpoint/model problem.
- [ ] Switching document while a request is pending discards the old response.
- [ ] Killing the app during evaluation keeps the draft and does not duplicate the attempt.

## Measurements

Recorded so far on the development Mac (Apple Silicon, macOS 26.6, debug build):

- The automated suite runs **78 tests across six bundles in about 4 seconds**.
  One of them (Parakeet model verification) is skipped unless explicitly enabled.
- On-device OCR of a rendered scanned page: **about 0.7 seconds**.
- Parakeet TDT-CTC 110M, opt-in verification: downloaded the model and
  transcribed a synthesised sentence on device in **about 41 seconds including
  the download**. The test asserts the transcript contains the expected words.
  This is a correctness check, not a latency benchmark: the download dominates
  the time, and real student speech is not measured here.
- Release bundle smoke test: the app launched, created
  `Application Support/StudyApp/study.sqlite` with the `scopes` table and FTS5
  tables present, seeded `AGENT.md` and one prompt version, and stayed running
  until terminated. The window was not exercised interactively in this
  environment.

Run the opt-in model check with:

```bash
STUDYAPP_VERIFY_PARAKEET=1 swift test \
  --filter UIBasicsTests/testParakeetModelTranscribesGeneratedSpeech
```

It downloads about 120 MB into a temporary directory.

Latency, memory and accuracy figures for real documents and providers must be
measured on the target Mac rather than estimated. The repository does not claim
benchmark numbers it has not observed. Record them here when measured:

| Measurement | Machine | Result |
|---|---|---|
| App launch to interactive window | | not yet measured |
| Import, 50-page text PDF | | not yet measured |
| Import, 50-page scanned PDF (OCR) | | not yet measured |
| DOCX import, 100 paragraphs | | not yet measured |
| Question generation round trip | | not yet measured |
| Evaluation round trip | | not yet measured |
| Apple on-device transcription, 10 s audio | | not yet measured |
| Parakeet transcription, 10 s audio | | not yet measured |
| Peak memory during study | | not yet measured |
| Speech model cache size | | not yet measured |
