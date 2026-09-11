#!/usr/bin/env bash
# Rasterise the flow bar's transcript view and fail if it draws outside its frame.
# See Scripts/LayoutCheck/main.swift for why this cannot be a unit test.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp Sources/WizardApp/FlowBar/TranscriptFlowView.swift "$WORK/"
cp Scripts/LayoutCheck/main.swift "$WORK/"
# The view's #Preview block pulls in DEBUG-only machinery the harness does not need.
sed -i '' 's/^#if DEBUG/#if LAYOUT_CHECK_SKIP/' "$WORK/TranscriptFlowView.swift"

swiftc -O -parse-as-library \
  -target arm64-apple-macos26.0 \
  "$WORK/TranscriptFlowView.swift" "$WORK/main.swift" \
  -o "$WORK/layoutcheck"
"$WORK/layoutcheck"
