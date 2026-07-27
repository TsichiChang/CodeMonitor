#!/usr/bin/env bash
#
# Builds Code Monitor.app from the SwiftPM package.
#
#   ./build-app.sh              release build, auto-picked signing identity
#   CONFIG=debug ./build-app.sh debug build
#   SIGN_ID="Apple Development: you@example.com (TEAMID)" ./build-app.sh
#
# The app must NOT be sandboxed: it shells out to ps/lsof/osascript/otty-cli to
# discover sessions and focus terminal tabs.
#
# Signing matters beyond "it launches": macOS ties Automation (Apple Events)
# permission to the code signature. An ad-hoc signature changes on every
# rebuild, so the user would be re-prompted each time — a stable Development
# identity keeps the grant.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="Code Monitor"
BUNDLE="build/${APP_NAME}.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/CodeMonitor"

echo "▸ Assembling ${BUNDLE}…"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "$BIN" "${BUNDLE}/Contents/MacOS/CodeMonitor"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"

# Prefer the identity matching this repo's git email, so a machine with several
# Development certs picks the developer's own rather than whichever is first.
if [[ -z "${SIGN_ID:-}" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2 }')"
  GIT_EMAIL="$(git config user.email 2>/dev/null || true)"
  if [[ -n "$GIT_EMAIL" ]]; then
    SIGN_ID="$(grep -F "$GIT_EMAIL" <<<"$IDENTITIES" | head -1 || true)"
  fi
  [[ -z "${SIGN_ID:-}" ]] && SIGN_ID="$(head -1 <<<"$IDENTITIES")"
fi

if [[ -n "${SIGN_ID:-}" ]]; then
  echo "▸ Signing as ${SIGN_ID}"
  codesign --force --sign "$SIGN_ID" "$BUNDLE"
else
  echo "▸ No Development identity found — falling back to ad-hoc signing."
  echo "  (macOS will re-ask for Automation permission after each rebuild.)"
  codesign --force --sign - "$BUNDLE"
fi

codesign --verify --verbose=1 "$BUNDLE" 2>&1 | sed 's/^/  /'
echo "▸ Done: ${BUNDLE}"
echo "  Run it:  open '${BUNDLE}'"
