#!/bin/bash
# Compiles the usage-resolution sources together with the test harness and
# runs it. No XCTest/SPM — mirrors build.sh's bare-swiftc approach. The env
# token stub routes resolveUsage through the injected probe deterministically
# (see Tests/ResolveUsageTests.swift).
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=$(mktemp -d)
trap 'rm -rf "$OUT_DIR"' EXIT

if [[ -z "${SDKROOT:-}" || ! -d "${SDKROOT:-}" ]]; then
  SDKROOT="$(xcrun --show-sdk-path)"
  if swift --version | grep -q "Apple Swift version 5.10" \
      && [[ "$SDKROOT" == *"MacOSX15"* ]]; then
    for candidate in \
      /Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk \
      /Library/Developer/CommandLineTools/SDKs/MacOSX14.4.sdk; do
      if [[ -d "$candidate" ]]; then
        SDKROOT="$candidate"
        break
      fi
    done
  fi
fi

swiftc \
  -parse-as-library \
  -sdk "$SDKROOT" \
  -o "$OUT_DIR/task-activity-tests" \
  Sources/Model/TaskActivityModel.swift \
  Tests/TaskActivityTests.swift

"$OUT_DIR/task-activity-tests"

swiftc \
  -parse-as-library \
  -sdk "$SDKROOT" \
  -o "$OUT_DIR/resolve-usage-tests" \
  Sources/Model/PreferenceStorage.swift \
  Sources/Model/CodexQuotaModeStore.swift \
  Sources/Model/UsageDisplayModeStore.swift \
  Sources/Usage/AppUsage.swift \
  Sources/Usage/ClaudeCredentials.swift \
  Sources/Usage/UsageFetcher.swift \
  Tests/ResolveUsageTests.swift

CLAUDE_CODE_OAUTH_TOKEN="test-stub-token" "$OUT_DIR/resolve-usage-tests"
