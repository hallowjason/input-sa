#!/usr/bin/env python3
"""Export input-sa dojo correction terms into McBopomofo user phrases.

Reads the runtime dojo table (falls back to the bundled seed), generates
bopomofo readings for every unique *correct* term, and appends the ones not
already present to the McBopomofo user-phrase file (one `詞 ㄅ-ㄆ-ㄇ` per line).

The data file is Syncthing-synced, so writing goes through a temp file +
os.replace (atomic), with a timestamped backup left beside it.

Usage:
    python3 tools/export_dojo_to_mcbopomofo.py            # apply
    python3 tools/export_dojo_to_mcbopomofo.py --dry-run  # preview only
"""

import json
import os
import shutil
import sys
import time
from pathlib import Path

from pypinyin import Style, pinyin

RUNTIME_DOJO = Path.home() / "Library/Application Support/InputSa/dojo_corrections.json"
SEED_DOJO = Path(__file__).resolve().parent.parent / "InputSa/Resources/dojo/dojo_corrections.json"
MCBOPOMOFO_DATA = Path("/Users/gooo/Desktop/DAO-Vault/Projects/小麥鍵盤-偏好詞庫/data.txt")

# pypinyin falls back to per-character readings for words outside its dict,
# which picks the wrong pronunciation for these. Full-word readings win.
READING_OVERRIDES = {
    "了愿": "ㄌㄧㄠˇ-ㄩㄢˋ",
}


def load_dojo_terms() -> list[str]:
    path = RUNTIME_DOJO if RUNTIME_DOJO.exists() else SEED_DOJO
    entries = json.loads(path.read_text(encoding="utf-8"))["entries"]
    terms = sorted({e["correct"] for e in entries if len(e["correct"]) >= 2})
    print(f"dojo table: {path} ({len(entries)} entries → {len(terms)} unique terms)")
    return terms


def bopomofo(word: str) -> str:
    if word in READING_OVERRIDES:
        return READING_OVERRIDES[word]
    readings = pinyin(word, style=Style.BOPOMOFO, errors="ignore")
    syllables = [r[0] for r in readings if r and r[0]]
    if len(syllables) != len(word):
        raise ValueError(f"無法為「{word}」產生完整注音（{syllables}），請加進 READING_OVERRIDES")
    return "-".join(syllables)


def main() -> None:
    dry_run = "--dry-run" in sys.argv

    existing_words = set()
    lines = MCBOPOMOFO_DATA.read_text(encoding="utf-8").splitlines()
    for line in lines:
        parts = line.split()
        if parts:
            existing_words.add(parts[0])

    additions = []
    for term in load_dojo_terms():
        if term in existing_words:
            continue
        additions.append(f"{term} {bopomofo(term)}")

    if not additions:
        print("已全部存在，無需新增。")
        return

    print(f"\n將新增 {len(additions)} 條：")
    for a in additions:
        print(f"  {a}")

    if dry_run:
        print("\n(dry-run，未寫入)")
        return

    backup = MCBOPOMOFO_DATA.with_suffix(f".txt.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(MCBOPOMOFO_DATA, backup)

    content = "\n".join(lines + additions) + "\n"
    tmp = MCBOPOMOFO_DATA.with_suffix(".txt.tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, MCBOPOMOFO_DATA)
    print(f"\n✅ 已寫入 {MCBOPOMOFO_DATA}（備份：{backup.name}）")


if __name__ == "__main__":
    main()
