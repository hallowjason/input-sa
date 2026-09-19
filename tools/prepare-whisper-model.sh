#!/bin/bash
# Reuse the app's model storage by default; a positional directory still allows
# isolated development/test downloads without duplicating the normal model.
set -euo pipefail
MODEL_DIR="${1:-$HOME/Library/Application Support/InputSa/models}"
MODEL="$MODEL_DIR/ggml-large-v3-turbo.bin"
PART="$MODEL.cli.part" # Separate from the app's active .bin.part download.
SHA="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL" ]; then
  curl --fail --location --retry 3 --continue-at - --output "$PART" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
  [ "$(stat -f%z "$PART")" = 1624555275 ]
  printf '%s  %s\n' "$SHA" "$PART" | shasum -a 256 -c -
  mv "$PART" "$MODEL"
fi
[ "$(stat -f%z "$MODEL")" = 1624555275 ]
printf '%s  %s\n' "$SHA" "$MODEL" | shasum -a 256 -c -
echo "$MODEL"
