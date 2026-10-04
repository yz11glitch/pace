# Local ASR evaluation

Benchmark adapters, scripted prompts, normalization and scoring for the Mac-hosted
reference engine. Recordings and model weights are not included. Corpus text is
scripted evaluation material; recorded audio hashes identify unpublished inputs.

Run from the repository root on an Apple Silicon Mac:

```sh
uv sync
uv run python -m bench.asr.run --help
uv run python -m bench.asr.score --help
uv run pytest bench/asr/tests
```

`configs.json` declares adapter settings. `corpus.jsonl` provides planned prompts
and confirmed spoken text. `normalize.py` normalizes transcription for scoring.
`score.py` measures transcription and financial amount/merchant preservation.
`download_models.py` downloads separately configured models.

Bring your own synthetic recordings when running the full audio benchmark.
The included unit tests exercise adapters and scoring without private recordings.
