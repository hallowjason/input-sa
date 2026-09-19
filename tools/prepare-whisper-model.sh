#!/bin/bash
# Optional development/test model download. Release apps download after consent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="${1:-$ROOT/build/whisper-models}"
MODEL="$MODEL_DIR/ggml-large-v3-turbo.bin"
SHA="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL" ]; then
  curl --fail --location --retry 3 --continue-at - --output "$MODEL.part" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
  [ "$(stat -f%z "$MODEL.part")" = 1624555275 ]
  printf '%s  %s\n' "$SHA" "$MODEL.part" | shasum -a 256 -c -
  mv "$MODEL.part" "$MODEL"
fi
[ "$(stat -f%z "$MODEL")" = 1624555275 ]
printf '%s  %s\n' "$SHA" "$MODEL" | shasum -a 256 -c -
echo "$MODEL"
