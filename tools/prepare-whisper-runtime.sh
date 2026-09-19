#!/bin/bash
# Reproducible, self-contained whisper.cpp runtime. No Homebrew/system installs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/whisper-runtime-source"
DEST="$ROOT/vendor/whisper"
REV="f049fff95a089aa9969deb009cdd4892b3e74916" # official whisper.cpp v1.9.1
SOURCE_SHA="279af4ce60dbf397362868f3bacc75b56a4332ac2541cae155070093f6aaf0e3"
CMAKE_VERSION="4.4.3"
CMAKE_SHA="0c5d65251c14cc884bfa16bdbed3c263ce5bffe2e21c0d0d00962cb0610464fa"
mkdir -p "$WORK" "$DEST"
if [ "$(uname -m)" != arm64 ]; then echo "Whisper runtime requires an arm64 Mac." >&2; exit 1; fi

if command -v cmake >/dev/null 2>&1; then
  CMAKE_BIN="$(command -v cmake)"
else
  ARCHIVE="$WORK/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
  if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --retry 3 --output "$ARCHIVE.part" \
      "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
    mv "$ARCHIVE.part" "$ARCHIVE"
  fi
  printf '%s  %s\n' "$CMAKE_SHA" "$ARCHIVE" | shasum -a 256 -c -
  if [ ! -d "$WORK/cmake-$CMAKE_VERSION-macos-universal" ]; then tar -xzf "$ARCHIVE" -C "$WORK"; fi
  CMAKE_BIN="$WORK/cmake-$CMAKE_VERSION-macos-universal/CMake.app/Contents/bin/cmake"
fi

SOURCE="$WORK/whisper.cpp-$REV"
if [ ! -d "$SOURCE" ]; then
  curl --fail --location --retry 3 --output "$WORK/whisper-source.tar.gz" \
    "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/$REV"
  printf '%s  %s\n' "$SOURCE_SHA" "$WORK/whisper-source.tar.gz" | shasum -a 256 -c -
  tar -xzf "$WORK/whisper-source.tar.gz" -C "$WORK"
fi
"$CMAKE_BIN" -S "$SOURCE" -B "$WORK/build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=OFF -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_CURL=OFF
"$CMAKE_BIN" --build "$WORK/build" --config Release --parallel 4 --target whisper-server whisper-cli
for BIN in whisper-server whisper-cli; do
  cp "$WORK/build/bin/$BIN" "$DEST/$BIN"
  chmod 755 "$DEST/$BIN"
  # Static ggml prevents a build-machine-only dylib from entering the release.
  if otool -L "$DEST/$BIN" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/)' ; then
    echo "Non-system dynamic dependency in $BIN" >&2; exit 1
  fi
  codesign --force --sign - "$DEST/$BIN"
  file "$DEST/$BIN"
  otool -l "$DEST/$BIN" | grep -A5 LC_BUILD_VERSION
done
cp "$SOURCE/LICENSE" "$DEST/LICENSE-whisper.cpp.txt"
cp "$ROOT/tools/prepare-whisper-NOTICES.txt" "$DEST/LICENSE-THIRD-PARTY.txt"
if [ -f "$SOURCE/ggml/LICENSE" ]; then cp "$SOURCE/ggml/LICENSE" "$DEST/LICENSE-ggml.txt"; fi
printf 'whisper.cpp v1.9.1\ncommit %s\narm64 macOS 14.0\nstatic ggml, embedded Metal\n' "$REV" > "$DEST/VERSION.txt"
(
  cd "$DEST"
  shasum -a 256 whisper-server whisper-cli > SHA256SUMS.txt
)
echo "Runtime ready: $DEST"
