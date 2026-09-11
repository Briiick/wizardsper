#!/usr/bin/env bash
# Generate the Xcode project and build Wizardsper.app.
#
# Signed with a real Apple Development identity rather than ad-hoc on purpose:
# TCC keys its Microphone, Input Monitoring and Accessibility grants to the code
# signature, and an ad-hoc signature changes on every build — so every rebuild
# would re-prompt for all three.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Debug}"
DERIVED="${DERIVED:-$PWD/build}"

if [ -z "${WIZARD_SIGN_IDENTITY:-}" ]; then
  WIZARD_SIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
fi
if [ -z "$WIZARD_SIGN_IDENTITY" ]; then
  echo "no Apple Development identity found; falling back to ad-hoc (TCC will re-prompt each build)" >&2
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="")
else
  # The team id is the certificate's Organizational Unit. The code in the
  # common name looks like a team id but is not one, and using it makes
  # xcodebuild report "no certificate for team ... found".
  TEAM=$(security find-certificate -c "$WIZARD_SIGN_IDENTITY" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -E 's/.*OU *= *([A-Z0-9]+).*/\1/')
  echo "signing as: $WIZARD_SIGN_IDENTITY (team $TEAM)"
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="$WIZARD_SIGN_IDENTITY"
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="$TEAM"
    PROVISIONING_PROFILE_SPECIFIER=""
  )
fi

xcodegen generate --quiet
xcodebuild \
  -project Wizardsper.xcodeproj \
  -scheme Wizardsper \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  "${SIGN_ARGS[@]}" \
  build "$@"

APP="$DERIVED/Build/Products/$CONFIG/Wizardsper.app"
echo
echo "built: $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/  /'
