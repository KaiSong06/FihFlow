#!/bin/bash
set -euo pipefail

if [[ "$(uname -m)" != arm64 ]]; then
  echo "Local Cohere requires an Apple Silicon Mac." >&2
  exit 1
fi
if ! command -v uv >/dev/null; then
  echo "Install uv, then run this script again: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 1
fi

runtime="$HOME/Library/Application Support/FihFlow/runtime"
if [[ ! -x "$runtime/bin/python3" ]]; then
  uv venv --python 3.12 "$runtime"
fi
uv pip install --python "$runtime/bin/python3" 'mlx-audio[stt]==0.6.2'
echo "Local runtime installed. Select Local Cohere + OpenAI in FihFlow."
