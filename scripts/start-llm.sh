#!/bin/sh
set -eu

MODEL_PATH=${NOTED_LLM_MODEL_PATH:-data/models/Qwen3.5-4B-Instruct-Q4_K_M.gguf}
SPEC_TYPE=${NOTED_LLM_SPEC_TYPE:-none}

exec llama-server \
  --model "$MODEL_PATH" \
  --ctx-size 4096 \
  --parallel 1 \
  --predict 256 \
  --reasoning off \
  --reasoning-format deepseek \
  --spec-type "$SPEC_TYPE" \
  --host 127.0.0.1 \
  --port 8080
