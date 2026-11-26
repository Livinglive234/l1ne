#!/bin/bash
# Runs L1ne's real SIP engine (iPhone) against the fake PBX in tests/mock/pbx.py and prints what passed.
# usage: tests/mock/run-ios-wire-tests.sh [simulator name or UDID]      (default "iPhone 17"; the simulator reaches this Mac as 127.0.0.1)
# Needs: Xcode, xcodegen, the PJSIP xcframework (scripts/build-pjsip.sh), python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
SIM="${1:-iPhone 17}"
cleanup() { [ -n "${PBX:-}" ] && kill "$PBX" 2>/dev/null || true; }
trap cleanup EXIT
cd "$ROOT"; scripts/gen.sh >/dev/null
xcrun simctl boot "$SIM" 2>/dev/null || true
UDID=$(xcrun simctl list devices | grep -F "$SIM" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl privacy "$UDID" grant microphone com.livenet.l1ne 2>/dev/null || true
python3 "$HERE/pbx.py" > /tmp/l1ne-pbx.log 2>&1 & PBX=$!
sleep 1
set +e
xcodebuild test -project L1ne.xcodeproj -scheme L1ne -destination "id=$UDID" -only-testing:L1neTests -derivedDataPath "${DERIVED:-/tmp/l1ne-dd}" > /tmp/l1ne-xcodebuild.log 2>&1
STATUS=$?
set -e
grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests|error:|TEST (SUCCEEDED|FAILED)" /tmp/l1ne-xcodebuild.log | sed -E 's/\[[^]]*\] //' | tail -60
echo "--- fake PBX log: /tmp/l1ne-pbx.log    full build log: /tmp/l1ne-xcodebuild.log"
exit $STATUS
