#!/bin/zsh
# Usage: ./install-ipad.sh <udid>, or set IPAD_UDID in .local.env (git-ignored).
# iPad must be awake, unlocked once since boot, on the same Wi-Fi as the Mac.
set -e -o pipefail
cd "${0:A:h}"

[ -f .local.env ] && source ./.local.env
UDID="${1:-${IPAD_UDID:?pass a UDID or set IPAD_UDID in .local.env}}"
BUNDLE=JackWagon.T2170Print
DD=build/DerivedData-device

# A mesh network can keep a stale forwarding entry after the Mac roams, causing
# devicectl 4016 / 'unavailable'; re-associating Wi-Fi fixes it.
networksetup -setairportpower en0 off
sleep 3
networksetup -setairportpower en0 on
sleep 4

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate >/dev/null
fi

echo '== build'
xcodebuild build -project T2170Print.xcodeproj -scheme T2170Print -destination "id=$UDID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration -derivedDataPath "$DD" 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)' | sort -u

APP="$DD/Build/Products/Debug-iphoneos/T2170Print.app"
if [[ ! -d "$APP" ]]; then
    echo "Error: $APP does not exist" >&2
    exit 1
fi

echo '== install'
xcrun devicectl device install app --device "$UDID" "$APP"

echo '== launch'
xcrun devicectl device process launch --device "$UDID" "$BUNDLE" || echo "Note: if the device is locked or asleep, the install still succeeded and the app can be opened from the home screen."
