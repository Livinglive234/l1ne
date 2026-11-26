#!/bin/bash
# Runs L1ne's real SIP engine (Android) against the fake PBX in tests/mock/pbx.py and prints what passed.
# usage: tests/mock/run-android-wire-tests.sh [emulator-avd-name]     (default l1ne_api28; the emulator reaches this Mac as 10.0.2.2)
# Needs: the Android SDK (android/local.properties), the native libraries built (scripts/build-android-native.sh), python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
SDK="${ANDROID_HOME:-$(sed -n 's/^sdk.dir=//p' "$ROOT/android/local.properties")}"
AVD="${1:-l1ne_api28}"
cleanup() { [ -n "${PBX:-}" ] && kill "$PBX" 2>/dev/null || true; [ -n "${EMU:-}" ] && "$SDK/platform-tools/adb" -s emulator-5554 emu kill >/dev/null 2>&1 || true; }
trap cleanup EXIT
python3 "$HERE/pbx.py" > /tmp/l1ne-pbx.log 2>&1 & PBX=$!
if ! "$SDK/platform-tools/adb" devices | grep -q "emulator-"; then
  "$SDK/emulator/emulator" -avd "$AVD" -no-window -no-audio -no-snapshot -gpu swiftshader_indirect >/tmp/l1ne-emu.log 2>&1 & EMU=$!
  "$SDK/platform-tools/adb" wait-for-device
  until [ "$("$SDK/platform-tools/adb" -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && "$SDK/platform-tools/adb" -s emulator-5554 shell pm path android >/dev/null 2>&1; do sleep 3; done
fi
"$SDK/platform-tools/adb" -s emulator-5554 shell pm clear com.livenet.l1ne >/dev/null 2>&1 || true      # start from an empty app (leftovers from a crashed run would fill PJSIP's account slots)
cd "$ROOT/android"
export ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5554}"      # a phone on USB would otherwise be picked up too (and cannot reach the fake PBX as 10.0.2.2)
if ! ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.livenet.l1ne.WireTest "$@" > /tmp/l1ne-gradle.log 2>&1; then tail -40 /tmp/l1ne-gradle.log; fi
grep -E "Tests |FAILED|PASSED|tests completed|Failed to" /tmp/l1ne-gradle.log | head -20
echo "--- fake PBX log: /tmp/l1ne-pbx.log"
