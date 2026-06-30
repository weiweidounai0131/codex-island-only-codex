#!/bin/bash
# Builds the .app and packages a DMG for distribution.
# Requires `npm install --global create-dmg` (Node 20+). Unsigned — no Apple
# Developer Program certificates involved. Ad-hoc codesign keeps Apple Silicon
# Macs from rejecting the binary as "damaged" after re-download.

set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must be X.Y.Z (got '$VERSION')" >&2
  exit 1
fi
APP_NAME="CodexIsland oc"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/CodexIsland-oc-$VERSION.dmg"
CREATE_DMG_OUT="$DIST/CodexIsland oc $VERSION.dmg"

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg is required. Install with: npm install --global create-dmg" >&2
  exit 1
fi

./build.sh

rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "build/$APP_NAME.app" "$DIST/"

# Ad-hoc sign — does NOT satisfy Gatekeeper, but prevents the
# "CodexIsland oc is damaged and can't be opened" failure mode that
# unsigned Apple Silicon binaries hit after a download round-trip.
codesign --force --deep --sign - "$APP"

rm -f "$DMG" "$CREATE_DMG_OUT"
create-dmg \
  --overwrite \
  --no-code-sign \
  --dmg-title "CodexIsland oc $VERSION" \
  "$APP" \
  "$DIST"

if [[ -f "$CREATE_DMG_OUT" ]]; then
  mv "$CREATE_DMG_OUT" "$DMG"
fi

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

echo ""
echo "✓ $DMG"
echo "  size: $(du -h "$DMG" | cut -f1)"
echo "  sha256: $DMG_SHA256"
