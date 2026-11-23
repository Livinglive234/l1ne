#!/bin/bash
# Places a call from the iOS Simulator app to the mock SIP/TLS server and prints the media lines of the offer.
# usage: run-call-test.sh <srtp-sdes|srtp-dtls|none> [mandatory:true|false]
# Needs: a booted simulator with L1ne built for it, and `tests/mock/gen-certs.sh /tmp/l1ne-mock` run once.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
U="${SIM_UDID:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1)}"
[ -n "$U" ] || { echo "no booted simulator (or set SIM_UDID)"; exit 1; }
MODE="${1:-srtp-sdes}"; MAND="${2:-true}"
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/L1ne-*/Build/Products/Debug-iphonesimulator/L1ne.app | head -1)
xcrun simctl terminate "$U" com.livenet.l1ne 2>/dev/null || true
pkill -f mock_sip_tls.py || true; sleep 1; rm -f /tmp/l1ne-mock/sip.log
(nohup python3 "$HERE/mock_sip_tls.py" ${MOCK_CERT:-/tmp/l1ne-mock/server.pem} ${MOCK_KEY:-/tmp/l1ne-mock/server.key} /tmp/l1ne-mock/sip.log ${MOCK_ARGS:-} >/dev/null 2>&1 &); sleep 1
python3 - "$U" "$MODE" "$MAND" "${ACCOUNT_DOMAIN:-localhost}" <<'PY'
import json,subprocess,sys
udid,mode,mand,domain=sys.argv[1:5]
a=[{"id":"AAAAAAAA-0000-0000-0000-000000000001","label":"Mock PBX","displayName":"Alex","domain":domain,"port":5061,"transport":"tls","media":mode,"mediaMandatory":mand=="true","username":"7100"}]
subprocess.run(["xcrun","simctl","spawn",udid,"defaults","write","com.livenet.l1ne","accounts.v1","-data",json.dumps(a).encode().hex()],check=True)
PY
xcrun simctl install "$U" "$APP"
SIMCTL_CHILD_L1NE_CA_FILE=/tmp/l1ne-mock/bundle-with-test-ca.pem SIMCTL_CHILD_L1NE_AUTODIAL=1234 xcrun simctl launch "$U" com.livenet.l1ne >/dev/null
sleep 9
grep -E "INVITE|m=|a=crypto|a=fingerprint|a=setup" /tmp/l1ne-mock/sip.log | cut -c1-130 | sed 's/inline:.*/inline:<key>/'
