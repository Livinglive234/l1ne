#!/bin/bash
# Runs the iPhone / iPad screen tests (tests/ios/L1neUITests) on an iPhone and an iPad simulator. No PBX is needed.
# usage: tests/ios/run-ui-tests.sh [iPhone simulator name] [iPad simulator name]     (defaults "iPhone 17" and "iPad Pro 13-inch (M5)")
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
cd "$ROOT"; scripts/gen.sh >/dev/null
FAIL=0
for SIM in "${1:-iPhone 17}" "${2:-iPad Pro 13-inch (M5)}"; do
  xcrun simctl boot "$SIM" 2>/dev/null || true
  UDID=$(xcrun simctl list devices | grep -F "$SIM (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  echo "=== $SIM"
  xcodebuild test -project L1ne.xcodeproj -scheme L1ne -destination "id=$UDID" -only-testing:L1neUITests -derivedDataPath "${DERIVED:-/tmp/l1ne-dd}" > "/tmp/l1ne-ui-$UDID.log" 2>&1 || FAIL=1
  grep -E "Test Case .* (passed|failed|skipped)|Executed [0-9]+ tests|error:" "/tmp/l1ne-ui-$UDID.log" | sed -E 's/\[[^]]*\] //' | sort -u | tail -30
done
exit $FAIL
