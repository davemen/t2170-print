#!/bin/zsh
# Archive T2170 Print and upload it to TestFlight with the App Store Connect API key.
# Usage: NOTES="1. Open the app ...  2. ..." ./push-testflight.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
# .local.env (git-ignored) sets ASC_KEY_ID and ASC_ISSUER_ID.
[ -f "$HERE/.local.env" ] && source "$HERE/.local.env"
KEY_ID=${ASC_KEY_ID:?set ASC_KEY_ID in .local.env}
ISSUER_ID=${ASC_ISSUER_ID:?set ASC_ISSUER_ID in .local.env}
KEY=~/.private_keys/AuthKey_$KEY_ID.p8
WORK=${TMPDIR:-/tmp}/t2170-push
[ -f "$KEY" ] || { echo "missing $KEY"; exit 1; }
# TestFlight holds back a build with no "What to Test", so there is no fallback text here.
[ -n "$NOTES" ] || { echo 'usage: NOTES="numbered test steps" ./push-testflight.sh' >&2; exit 1; }
export ASC_APP=6831473803
V=$(date +%Y%m%d%H%M)
(cd "$HERE" && xcodegen generate -q)
rm -rf "$WORK"; mkdir -p "$WORK"
cat > "$WORK/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>DWQ9ZN5SGU</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
echo "archiving build $V"
xcodebuild archive -project "$HERE/T2170Print.xcodeproj" -scheme T2170Print -destination 'generic/platform=iOS' \
  -archivePath "$WORK/T2170Print.xcarchive" -allowProvisioningUpdates -quiet CURRENT_PROJECT_VERSION="$V" \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID"
echo "uploading"
xcodebuild -exportArchive -archivePath "$WORK/T2170Print.xcarchive" -exportOptionsPlist "$WORK/ExportOptions.plist" -exportPath "$WORK/export" \
  -allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID" > "$WORK/export.log" 2>&1 || EXPORT_RC=$?
grep -iE "Upload succeeded|EXPORT|error" "$WORK/export.log" | tail -3 || true
if [ "${EXPORT_RC:-0}" -ne 0 ]; then
  echo "upload FAILED (xcodebuild exit $EXPORT_RC); log at $WORK/export.log" >&2
  tail -20 "$WORK/export.log" >&2
  exit 1
fi
# Detached: the build takes minutes to appear, and the notes must outlive this shell.
~/Jarvis/tools/asc-notes-when-ready.sh "$V" "$NOTES"
echo "what-to-test will be set on $V once it appears (log: ${TMPDIR:-/tmp}/jarvis-asc-notes-$V.log)"
echo "  verify with: cd ~/Jarvis && ASC_APP=6831473803 python3 tools/asc.py builds 3"
