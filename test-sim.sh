#!/bin/zsh
# Whole print flow against simulated printers, on this Mac only (needs /usr/bin/ippeveprinter).
#   ./test-sim.sh [--ppd /path/to/Epson.ppd] [--refs /path/to/rasterref]
# The PPD is Epson's and stays out of the repo; without it the "ppd" scenarios fail by design.
set -e -o pipefail
cd "$(dirname "$0")"
ROOT=$PWD; PPD=""; REFS=""
while [ $# -gt 0 ]; do case "$1" in
  --ppd) PPD=$2; shift 2;;
  --refs) REFS=$2; shift 2;;
  *) echo "unknown option $1"; exit 2;;
esac; done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/t2170-sim.XXXXXX"); echo "work: $WORK"
pids=()
cleanup() { for p in $pids; do kill $p 2>/dev/null || true; done }
trap cleanup EXIT

start() { # key port extra-args...
  local key=$1 port=$2; shift 2
  mkdir -p "$WORK/$key"
  ( cd "$WORK" && exec /usr/bin/ippeveprinter "$@" -p $port -n localhost -k -d "$WORK/$key" -c /usr/bin/true -r off -vv "Sim $key" ) \
    > "$WORK/$key.log" 2>&1 &
  pids+=($!)
}
SIM=""
if [ -n "$PPD" ]; then cp "$PPD" "$WORK/t2170.ppd"; start ppd 8631 -P t2170.ppd; SIM="ppd=ipp://localhost:8631/ipp/print,"; fi
start urf 8632 -f image/urf
start pwg 8633 -f image/pwg-raster
start pdf 8634 -f application/pdf
SIM="${SIM}urf=ipp://localhost:8632/ipp/print,pwg=ipp://localhost:8633/ipp/print,pdf=ipp://localhost:8634/ipp/print"
if [ -x "$ROOT/tools/fake_ipp.py" ]; then
  python3 "$ROOT/tools/fake_ipp.py" 8635 > "$WORK/fake.log" 2>&1 &
  pids+=($!); export TEST_RUNNER_T2170_FAKE=http://localhost:8635
  LAN_IP=$(ipconfig getifaddr en0 || true)
  [ -n "$LAN_IP" ] && export TEST_RUNNER_T2170_FAKE_LAN="$LAN_IP,$(scutil --get LocalHostName).local"
fi
sleep 2
export TEST_RUNNER_T2170_SIM=$SIM
[ -n "$REFS" ] && export TEST_RUNNER_T2170_RASTERREF=$REFS
DEST=$(xcrun simctl list devices available | grep -E "iPad (Air|Pro)" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
command -v xcodegen >/dev/null && xcodegen generate -q
xcodebuild test -project T2170Print.xcodeproj -scheme T2170Print \
  -destination "platform=iOS Simulator,id=${SIM_DEVICE:-$DEST}" CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath build/DerivedData > "$WORK/xcodebuild.log" 2>&1 || XC=$?
grep -E "error:|✘|Test run with|\*\* TEST" "$WORK/xcodebuild.log" | sort -u | cut -c1-300 || true
python3 "$ROOT/tools/check_spool.py" "$WORK"
exit ${XC:-0}
