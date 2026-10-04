# Capture utterance fixtures

`capture_utterances.jsonl` contains one short, plausible capture per line. Each row has:

- `id`: stable test label
- `text`: the transcript sent to the text capture API
- `proposal`: a fixture for the existing compact Qwen schema, used only if the capture path invokes understanding
- `expected`: final saved transaction fields after amount validation and merchant resolution

The API test in `tests/test_capture_reliability.py` runs every row through a temporary SQLite database. It does not claim to measure Whisper accuracy or require a live model. Keep model-specific smoke runs small and separate from this deterministic corpus.
