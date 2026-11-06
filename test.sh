#!/bin/zsh
# Unit tests on an iPad simulator (no signing).
set -e -o pipefail
cd "$(dirname "$0")"
if command -v xcodegen >/dev/null; then xcodegen generate >/dev/null; fi
SIM=$(xcrun simctl list devices available | grep -E "iPad (Air|Pro)" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$SIM" ] || { echo "no iPad simulator available"; exit 1; }
echo "simulator: $SIM"
xcodebuild test -project T2170Print.xcodeproj -scheme T2170Print \
  -destination "platform=iOS Simulator,id=$SIM" CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedData 2>&1 \
  | grep -E "error:|failed|passed|Test Suite|Executed|BUILD|TEST" | grep -v "^$" | sort -u | head -80
