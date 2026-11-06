#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
bash "$repo_dir/scripts/setup-local-cohere.sh"
runtime="$HOME/Library/Application Support/FihFlow/runtime"
models="$HOME/Library/Application Support/FihFlow/meeting-models"
uv pip install --python "$runtime/bin/python3" 'sherpa-onnx==2.0.1'
mkdir -p "$models"
chmod 700 "$models"
if [[ ! -f "$models/segmentation.onnx" ]]; then
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT
  curl --fail --location --retry 3 https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 -o "$staging/segmentation.tar.bz2"
  tar -xjf "$staging/segmentation.tar.bz2" -C "$staging" sherpa-onnx-pyannote-segmentation-3-0/model.onnx
  cp "$staging/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$models/segmentation.onnx"
fi
if [[ ! -f "$models/embedding.onnx" ]]; then
  curl --fail --location --retry 3 https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx -o "$models/embedding.onnx.download"
  mv "$models/embedding.onnx.download" "$models/embedding.onnx"
fi
echo 'Meeting speaker models installed. Inference runs locally.'
