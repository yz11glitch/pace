# Local reference engine

The Python package retains its original codename, `noted`.
It predates the native app and runs separately on an Apple Silicon Mac.
The native iOS application does not connect to this engine.
Native voice capture is not implemented.

## Pipeline

The browser client in `public/` can record audio.
FastAPI in `noted/api.py` exposes the local capture API.
`noted/asr.py` selects an ASR adapter from `bench/asr/adapters`.
The default transcription model is mlx-whisper large-v3-turbo.
Transcription runs on the Mac, not on the phone.

A local Qwen3.5-4B Q4_K_M model is served by llama.cpp's `llama-server`.
`noted/llm.py` constrains proposals with a JSON schema.
The schema represents financial intents and verbatim evidence spans.
Model output is a proposal; it is not SQL and contains no ledger row IDs.

`_validate_verbatim_spans` requires cited expressions to appear in the transcript.
Hallucinated merchant, amount or date spans are rejected.
Intent coherence is checked separately from JSON structure.
Amount and date resolution use deterministic code.
Ambiguous required values return `needs_clarification`.
Nothing is saved while that clarification is outstanding.

## Local operation

The launcher binds the API to the loopback interface.
The model server also binds to loopback.
Models and personal runtime data are excluded from the snapshot.
For phone access, the Mac must be reachable over a private network.
The repository does not supply a remote hosting deployment.

```sh
uv sync
npm run start:llm
npm run start
```

Install llama.cpp separately and provide the model file expected by
`scripts/start-llm.sh`, or set `NOTED_LLM_MODEL_PATH` yourself.
No model weights are bundled.
The ASR adapter can download its configured model when first used.
Use fictional transcripts and recordings when evaluating the engine.

## Persistence

The Python engine has its own SQLite database.
It does not share the native App Group database.
`noted/db.py` applies SQL migrations in filename order.
Eight migrations are included under `noted/migrations`.

| Migration | Responsibility |
|---|---|
| 001 | Merchants, aliases, context rules and initial transactions |
| 002 | Conversation sessions, utterances, turns, proposals and action log |
| 003 | Separate expense, income, refund and contribution semantics |
| 004 | Durable request idempotency |
| 005 | Planning profile |
| 006 | Manual-entry idempotency |
| 007 | Dynamic savings settings |
| 008 | Merchant alias seed expansion |

Mutations are audited and undoable.
Request fingerprints prevent replaying a request ID with different content.
Backup tests check WAL-safe SQLite backup and restore.
The default runtime directory is excluded from version control.
No real ledger or runtime backup is included here.

## Benchmark method

ASR benchmarking separates transcript accuracy from financial preservation.
`bench/asr/normalize.py` normalizes transcript variants for scoring.
Adapters allow controlled comparisons under common corpus inputs.
The scripted corpus retains confirmed spoken text and audio hashes.
The audio files themselves are unpublished and absent.
You need your own synthetic recordings to repeat audio measurements.

Understanding benchmarking uses explicit expected intents and field spans.
`bench/understanding/score.py` reports schema and semantic validity separately.
Latency is recorded for individual cases and summarized by percentile.
The selected historical result files are included for inspection.
They are measurements of local reference-engine experiments.
They are not native iOS performance numbers.

## Curated understanding results

The result files contain `summary` objects and per-case details.
The earlier one-pass 4B result uses a different corpus and contract.
It should not be directly ranked against the compact-contract runs.
The two compact-contract runs cover the same recorded case count.
Hardware/runtime details affect latency and are not universal promises.
See the metadata JSON for the 2B run's configuration and selection decision.

- `qwen3.5-4b-q4_k_m-one-pass-final.json`: earlier structured understanding run.
- `qwen3.5-2b-q4_k_m-v2-quality.json`: compact smaller-model quality comparison.
- `qwen3.5-2b-q4_k_m-v2-quality.metadata.json`: runtime and decision context.
- `b2-v2-none-sustained-final.json`: sustained compact-contract comparison.

All four live in `bench/understanding/results/`.
Only these curated results are included; recording rigs and bulk logs are omitted.

## Golden data and tests

The Python engine serves as the oracle for the Swift port.
`export_golden_fixtures.py` exports money, date, category and planning behavior.
`export_ui_fixtures.mjs` exports browser-domain keypad behavior.
Swift tests read the shared JSONL files from `fixtures/golden`.
Regeneration must leave the tracked fixtures unchanged.

```sh
uv run pytest -q
npm run check
uv run python scripts/export_golden_fixtures.py
node scripts/export_ui_fixtures.mjs
```

Unit/API tests use temporary databases and fake understanding services.
They do not claim live-model or live-ASR accuracy.
The benchmark files provide that separate experimental context.
