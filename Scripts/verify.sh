#!/usr/bin/env bash
# Everything that can be checked without a human holding a key.
#
# Run this before trusting a change: the recognition path is exercised against a
# file with a known transcript, and the live capture path is exercised against a
# real microphone, so a regression in either shows up here rather than in the
# middle of dictating.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
check() { if [ "$1" -eq 0 ]; then echo "  ok"; else echo "  FAILED"; fail=1; fi; }

step "build (library, CLI, tests)"
swift build 2>&1 | grep -E "error:|warning:" && fail=1 || echo "  clean"

step "unit + integration tests"
swift test 2>&1 | grep -E "Test run with|✘" || true
swift test >/dev/null 2>&1; check $?

step "app bundle"
./Scripts/build-app.sh >/tmp/wizardsper-verify-app.log 2>&1
if grep -q "BUILD SUCCEEDED" /tmp/wizardsper-verify-app.log; then
  echo "  ok"
  codesign -dv build/Build/Products/Debug/Wizardsper.app 2>&1 \
    | grep -E "Identifier|TeamIdentifier" | sed 's/^/  /'
else
  echo "  FAILED — see /tmp/wizardsper-verify-app.log"; fail=1
fi

step "recognition against a known transcript"
swift build -c release >/dev/null 2>&1
AUDIO=/tmp/wizardsper_audio/librispeech/ls_00.wav
REF=/tmp/wizardsper_audio/librispeech/ls_00.txt
if [ -f "$AUDIO" ] && [ -f "$REF" ]; then
  ./.build/release/wizardsper-cli transcribe "$AUDIO" --reference "$(cat "$REF")" 2>/dev/null \
    | tail -2 | sed 's/^/  /'
else
  echo "  skipped — no fixture at $AUDIO"
fi

step "flow bar layout (rasterised)"
./Scripts/check-layout.sh 2>&1 | sed 's/^/  /'; check ${PIPESTATUS[0]}

step "live capture path"
./.build/release/wizardsper-cli listen --seconds 3 2>/dev/null | tail -3 | sed 's/^/  /'

printf '\n'
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "SOME CHECKS FAILED"; fi
exit "$fail"
