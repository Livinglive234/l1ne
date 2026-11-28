#!/bin/bash
# A mock PBX on this Mac that your phones can call over ZRTP. Keeps running until you press Ctrl-C.
#   Register an L1ne account on the phone: server = this Mac's address (printed below), port 5060, transport UDP, extension 7100, password "secret",
#   Media = ZRTP. Dial 1001: it answers, plays a tone (so you can hear that the audio is decrypted) and shows its own ZRTP code here.
#   Compare the code on the phone's call screen with the one printed here: they must be the same.
# usage: tests/mock/run-zrtp-demo.sh [lan-address]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
O="$(brew --prefix openssl)"; IP="${1:-$(ipconfig getifaddr en0 || ipconfig getifaddr en1)}"
cc -std=gnu11 -I"$O/include" "$ROOT/native/zrtp/zrtp.c" "$ROOT/native/zrtp/l1srtp.c" "$ROOT/tests/zrtp/zrtp_peer.c" -L"$O/lib" -lcrypto -lm -o /tmp/l1ne-zrtp-peer
pkill -f l1ne-zrtp-peer 2>/dev/null || true
trap 'pkill -f l1ne-zrtp-peer 2>/dev/null || true; kill $PBX 2>/dev/null || true' EXIT
python3 "$HERE/pbx.py" --zrtp-peer /tmp/l1ne-zrtp-peer > /tmp/l1ne-pbx.log 2>&1 & PBX=$!
cat <<EOF
Mock PBX running at $IP
  server $IP   port 5060   transport UDP   extension 7100   password secret   Media: ZRTP
  dial 1001 (ZRTP peer, 440 Hz tone).  1007 has no ZRTP: it plays a higher tone (880 Hz) in the clear, so you can hear the call carry on once ZRTP gives up.
  macOS may ask to allow incoming connections for python and zrtp_peer: allow them.
What the PBX saw (Ctrl-C to stop):
EOF
tail -f /tmp/l1ne-pbx.log | grep --line-buffered -E "REGISTER .* 200|INVITE|BYE|zrtp-peer"
