#!/bin/zsh
# Compile check (no signing). Run on the farm: governor.py farm run ...
set -e
cd "$(dirname "$0")"
xcodegen generate >/dev/null
xcodebuild build -project T2170Print.xcodeproj -scheme T2170Print \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedData 2>&1 | tail -40
