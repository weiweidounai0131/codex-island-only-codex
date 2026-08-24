#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CodexIsland oc"
BUNDLE_ID="com.weiweidounai0131.CodexIslandOC"
VERSION="$(cat VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERSION must be X.Y.Z (got '$VERSION')" >&2
  exit 1
fi
BUILD_DIR="./build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
HELPERS_DIR="$CONTENTS/Helpers"

resolve_sdkroot() {
  if [[ -n "${SDKROOT:-}" && -d "${SDKROOT:-}" ]]; then
    printf '%s\n' "$SDKROOT"
    return
  fi

  local default_sdk
  default_sdk="$(xcrun --show-sdk-path)"

  # Some mixed Command Line Tools installs leave a Swift 6 macOS 15 SDK
  # beside Swift 5.10 executables. Swift then tries to compile Swift.swift
  # from the newer SDK and fails before reaching app code. Prefer the newest
  # installed 14.x SDK in that case; it matches the Swift 5.10 CLT line.
  if swift --version | grep -q "Apple Swift version 5.10" \
      && [[ "$default_sdk" == *"MacOSX15"* ]]; then
    for candidate in \
      /Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk \
      /Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk; do
      if [[ -d "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
      fi
    done
  fi

  printf '%s\n' "$default_sdk"
}

SDKROOT="$(resolve_sdkroot)"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$FRAMEWORKS_DIR" "$HELPERS_DIR"

cp ./Resources/openai_logo.pdf "$RES_DIR/openai_logo.pdf"
cp ./Resources/codexisland_logo.png "$RES_DIR/codexisland_logo.png"
cp ./Resources/CodexIsland.icns "$RES_DIR/CodexIsland.icns"
find ./Resources -maxdepth 1 -type d -name '*.lproj' -exec cp -R {} "$RES_DIR/" \;

SWIFT_SOURCES=$(find Sources -name '*.swift' ! -path 'Sources/TaskActivityHook/*' | sort)

# Universal binary, macOS 13 (Ventura) minimum. swiftc can't emit a
# multi-arch Mach-O directly, so compile each slice and lipo them.
DEPLOYMENT_TARGET="13.0"
ARM64_BIN="$BUILD_DIR/$APP_NAME-arm64"
X86_64_BIN="$BUILD_DIR/$APP_NAME-x86_64"

for arch_pair in "arm64:$ARM64_BIN" "x86_64:$X86_64_BIN"; do
  arch="${arch_pair%%:*}"
  out="${arch_pair##*:}"
  swiftc \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -O \
    -parse-as-library \
    -sdk "$SDKROOT" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ServiceManagement \
    -o "$out" \
    $SWIFT_SOURCES
done

lipo -create "$ARM64_BIN" "$X86_64_BIN" -output "$MACOS_DIR/$APP_NAME"
rm "$ARM64_BIN" "$X86_64_BIN"

# The Codex hook is a separate executable. Keeping it outside the app source
# list avoids a second @main entry point while still bundling one universal
# helper that the app can install into Application Support.
HELPER_SOURCE="Sources/TaskActivityHook/main.swift"
HELPER_ARM64="$BUILD_DIR/CodexIslandTaskActivityHook-arm64"
HELPER_X86_64="$BUILD_DIR/CodexIslandTaskActivityHook-x86_64"

for arch_pair in "arm64:$HELPER_ARM64" "x86_64:$HELPER_X86_64"; do
  arch="${arch_pair%%:*}"
  out="${arch_pair##*:}"
  swiftc \
    -target "${arch}-apple-macos${DEPLOYMENT_TARGET}" \
    -O \
    -parse-as-library \
    -sdk "$SDKROOT" \
    -o "$out" \
    "$HELPER_SOURCE"
done

lipo -create "$HELPER_ARM64" "$HELPER_X86_64" \
  -output "$HELPERS_DIR/CodexIslandTaskActivityHook"
chmod 700 "$HELPERS_DIR/CodexIslandTaskActivityHook"
rm "$HELPER_ARM64" "$HELPER_X86_64"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>CodexIsland oc</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>CodexIsland</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$DEPLOYMENT_TARGET</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Eric Park. MIT licensed.</string>
</dict>
</plist>
EOF

echo "✓ built $APP_DIR ($VERSION)"
