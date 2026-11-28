#!/bin/bash
# Starts the mock PBX with its ZRTP peer and launches the app in the iPhone simulator and/or the Android emulator with a live account on it
# (ZRTP, switching to unencrypted allowed) that calls 1001 by itself, so you can look at the "Continue without encryption" button and the prompt.
# While the call is up: `curl localhost:8099/peer-goclear` makes the other side ask to go unencrypted. Ctrl-C stops the PBX.
# usage: tests/mock/run-ui-goclear.sh [ios|android|both]   (an iPhone simulator and a debug build of each app must already be installed:
#   ios: xcodebuild build -derivedDataPath /tmp/l1ne-dd, simctl install;  android: ./gradlew :app:installDebug)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; O="$(brew --prefix openssl)"; WHICH="${1:-both}"
cc -std=gnu11 -I"$O/include" "$HERE/../../native/zrtp/zrtp.c" "$HERE/../../native/zrtp/l1srtp.c" "$HERE/../zrtp/zrtp_peer.c" -L"$O/lib" -lcrypto -lm -o /tmp/l1ne-zrtp-peer
pkill -f l1ne-zrtp-peer 2>/dev/null || true
trap 'pkill -f l1ne-zrtp-peer 2>/dev/null || true; kill $PBX 2>/dev/null || true' EXIT
python3 "$HERE/pbx.py" --zrtp-peer /tmp/l1ne-zrtp-peer > /tmp/l1ne-pbx.log 2>&1 & PBX=$!; sleep 1
if [ "$WHICH" != android ]; then SIMCTL_CHILD_L1NE_UITEST_SEED=mock-zrtp SIMCTL_CHILD_L1NE_CALLBACK=1001 xcrun simctl launch booted com.livenet.l1ne; fi
if [ "$WHICH" != ios ]; then adb shell am start -n com.livenet.l1ne/.MainActivity --es l1ne_seed mock-zrtp >/dev/null; fi
tail -f /tmp/l1ne-pbx.log | grep --line-buffered -E "REGISTER .* 200|INVITE|BYE|zrtp-peer"
