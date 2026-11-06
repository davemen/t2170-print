#!/bin/zsh
# Compile check (no signing).
# Hosts without xcodegen use the project generated on the Mac and synced over.
set -e -o pipefail
cd "$(dirname "$0")"
if command -v xcodegen >/dev/null; then xcodegen generate >/dev/null; fi
[ -d T2170Print.xcodeproj ] || { echo "no xcodeproj: run xcodegen generate on the Mac first"; exit 1; }
xcodebuild build -project T2170Print.xcodeproj -scheme T2170Print \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedData 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u | head -60
