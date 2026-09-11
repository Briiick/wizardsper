#!/usr/bin/env bash
# Fetch a Nemotron streaming CoreML tier from Hugging Face into a local directory.
#
# The 160ms tier was removed from `main` on 2026-06-05 ("Remove v1 160ms tier"),
# so each tier pins the last revision known to contain it.
#
# usage: fetch-model.sh <chunk_ms> [dest_root]
set -euo pipefail

CHUNK="${1:-560}"
DEST_ROOT="${2:-$HOME/Library/Application Support/Wizard/Models}"
REPO="FluidInference/nemotron-speech-streaming-en-0.6b-coreml"

case "$CHUNK" in
  160)  REV="c7e2cf6aa07b5e5ff0bb6bd1dfa5bbc0b8d9b1b1" ;;  # resolved below if short
  560|1120|2240) REV="main" ;;
  *) echo "unknown chunk size: $CHUNK (expected 160, 560, 1120, 2240)" >&2; exit 1 ;;
esac
# 160ms lives only in history; resolve the short sha the API accepts.
[ "$CHUNK" = "160" ] && REV="c7e2cf6aa07b"

SUBDIR="nemotron_coreml_${CHUNK}ms"
OUT="$DEST_ROOT/$SUBDIR"
mkdir -p "$OUT"

echo "fetching $SUBDIR from $REPO@$REV -> $OUT"
LIST=$(mktemp)
python3 - "$REV" "$REPO" "$SUBDIR" > "$LIST" <<'PY'
import json, sys, urllib.request
rev, repo, subdir = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=true"
for e in json.load(urllib.request.urlopen(url)):
    if e["type"] == "file" and e["path"].startswith(subdir + "/"):
        print(e["path"])
PY

total=$(wc -l < "$LIST" | tr -d ' ')
[ "$total" -gt 0 ] || { echo "no files found for $SUBDIR@$REV" >&2; exit 1; }

i=0
while read -r p; do
  i=$((i + 1))
  rel="${p#"$SUBDIR"/}"
  mkdir -p "$OUT/$(dirname "$rel")"
  if [ -s "$OUT/$rel" ]; then
    echo "[$i/$total] cached $rel"
  else
    curl -sL --retry 3 --fail "https://huggingface.co/$REPO/resolve/$REV/$p" -o "$OUT/$rel"
    echo "[$i/$total] $rel ($(stat -f%z "$OUT/$rel") bytes)"
  fi
done < "$LIST"
rm -f "$LIST"
echo "done: $(du -sh "$OUT" | cut -f1) in $OUT"
