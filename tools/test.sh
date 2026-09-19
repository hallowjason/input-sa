#!/bin/bash
# Local tests only: no microphone, personal history, Keychain, or paid APIs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEST_DIR="$(mktemp -d "${TMPDIR:-/private/tmp}/inputsa-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/modules"
run_test() {
    local name="$1"
    shift
    swiftc -module-cache-path "$TEST_DIR/modules" -warnings-as-errors "$@" -o "$TEST_DIR/$name"
    if ! "$TEST_DIR/$name" > "$TEST_DIR/$name.log" 2>&1; then
        cat "$TEST_DIR/$name.log"
        return 1
    fi
    printf '%s: ' "$name"
    tail -n 1 "$TEST_DIR/$name.log"
}
PROMPTS=(InputSa/AIServices/DojoCorrectionTable.swift InputSa/AIServices/TranscriptionMode.swift
         InputSa/AIServices/DictationCleanupStyle.swift InputSa/Learning/UserStyleModel.swift)
run_test vocabulary tests/main.swift "${PROMPTS[@]}"
run_test cleanup tests/DictationCleanupStyleTests.swift "${PROMPTS[@]}"
run_test language tests/TranslationLanguageTests.swift InputSa/AIServices/TranslationLanguage.swift
run_test translation tests/TranslationSessionTests.swift InputSa/InputMethod/TranslationSession.swift
run_test dictation tests/DictationSessionTests.swift InputSa/InputMethod/DictationSession.swift InputSa/AIServices/VoiceServiceProtocol.swift
run_test protocol tests/VoiceServiceProtocolTests.swift InputSa/AIServices/VoiceServiceProtocol.swift
run_test history tests/TranscriptHistoryTests.swift InputSa/AIServices/TranscriptHistoryStore.swift
run_test numbers tests/NumberFormatterTests.swift InputSa/AIServices/TranscriptNumberFormatter.swift
run_test selection tests/SelectionTranslateTests.swift InputSa/AIServices/SelectionTranslateDirection.swift
run_test whisper-model tests/WhisperModelTests.swift InputSa/AIServices/ModelCatalog.swift InputSa/AIServices/WhisperAudio.swift
run_test whisper-download tests/WhisperDownloadTests.swift InputSa/AIServices/ModelCatalog.swift InputSa/AIServices/ModelManager.swift
bash -n build.sh install.sh package-release.sh tools/sign-app.sh tools/prepare-whisper-runtime.sh tools/prepare-whisper-model.sh
git diff --check
echo "All 11 local test suites and script syntax checks passed."
