#!/bin/bash
# Runs the wire tests against a real TURN server (coturn) so the test that needs one is not skipped: a call with TURN on must offer a relayed address.
# usage: tests/mock/run-turn-test.sh ios|android        (needs: brew install coturn)
# coturn listens on 3479 (the fake PBX already uses 3478 for STUN) with the user l1ne / turnpass, only for this machine.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v turnserver >/dev/null || { echo "turnserver not found: brew install coturn"; exit 1; }
turnserver --listening-ip=127.0.0.1 --listening-port=3479 --relay-ip=127.0.0.1 --min-port=49300 --max-port=49400 --realm=l1ne --user=l1ne:turnpass --lt-cred-mech \
  --no-tls --no-cli --no-stdout-log --log-file=/tmp/l1ne-turn.log --pidfile=/tmp/l1ne-turn.pid >/dev/null 2>&1 &
TURN=$!
trap 'kill "$TURN" 2>/dev/null || true' EXIT
sleep 1
case "${1:-ios}" in
  ios)     TEST_RUNNER_L1NE_TURN=127.0.0.1:3479 "$HERE/run-ios-wire-tests.sh" ;;
  android) "$HERE/run-android-wire-tests.sh" l1ne_api28 -Pandroid.testInstrumentationRunnerArguments.turn=10.0.2.2:3479 ;;
  *) echo "usage: $0 ios|android"; exit 1 ;;
esac
echo "--- TURN server log: /tmp/l1ne-turn.log"
