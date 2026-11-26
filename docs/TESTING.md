# Testing without a real PBX

Most of what L1ne does is signalling with a phone server. A real PBX only has some of the features (no STUN, no SRTP, no early media, no transfer), so the
repository ships a **fake PBX** and tests that drive L1ne's real SIP engine against it.

## The fake PBX: `tests/mock/pbx.py`
Python, standard library only. SIP over TCP and UDP, a STUN server and a small HTTP control port, all on one machine. What it does depends on who registers or
what is dialled, so one running copy covers every scenario:

| You do | The fake PBX does |
|---|---|
| Register any extension with password `secret` | Digest login (401 challenge, then 200). A wrong password gets 403 |
| Register `7104` / `7105` / `7106` | 404 unknown extension / 503 server down / never answers |
| Dial `1001` (or anything else) | Ringing, then answered. Offers back the first codec you offered, echoes SRTP if you offered it |
| Dial `1002` / `1005` / `1006` | 486 Busy / 404 Not found / 603 Decline |
| Dial `1003` | 183 early media, then answered a second later |
| Dial `1004` | Rings forever (to test cancelling) |
| Hold / resume | Logs the re-INVITE and its direction (`sendonly` = hold) |
| Transfer | Logs the REFER and its Refer-To |
| Subscribe to message waiting | Sends a NOTIFY with 3 new voicemails |
| Send a text | Logs it |
| `GET /invite?user=7100` | Rings the registered phone (an incoming call) |
| `GET /text?user=7100&text=hi` | Sends the registered phone a text |
| STUN binding request (UDP 3478) | Answers with the sender's address and logs it |

`GET /log` returns everything it saw, `GET /clear` empties the log. `tests/mock/mock_sip_tls.py` is the older TLS-only server used for certificate and
encryption-offer checks from the iPhone simulator (`run-call-test.sh`).

## Android: `WireTest` (27 tests)
`android/app/src/androidTest/kotlin/com/livenet/l1ne/WireTest.kt` uses the app's own engine (PJSIP can only start once per process) and checks both what the
engine reports and what the server saw on the wire: registration (good and wrong password, 404, 503, silent server, UDP, disabled account), calls (answered, busy,
declined, unknown, cancelled while ringing, early media, hold and resume, transfer, voicemail button, dial rules, incoming), what is offered (no encryption, SDES keys, DTLS
fingerprint, disabled codec, codec order, ICE candidates, a STUN lookup), texts (sent, received) and message waiting.

```bash
tests/mock/run-android-wire-tests.sh          # starts the fake PBX and an emulator (default AVD l1ne_api28), runs the tests, shuts both down
```
Run it on an **emulator**: the tests add and remove their own accounts and change the codec settings, and the emulator reaches the computer as `10.0.2.2`.
The script clears the app's data first.

## What this cannot prove
- Audio quality, echo, Bluetooth and the real network (carrier NAT, firewalls). Only a real call shows those.
- **TURN** (a relay server). There is no TURN server in the fake PBX yet, so TURN is compiled and switchable but not exercised.
- **TLS** with a real certificate chain on Android (use `mock_sip_tls.py` for the offer checks) and **DTLS-SRTP** key exchange (only the offer is checked).
- The iPhone engine. The same scenarios still need an iOS port of `WireTest` (the fake PBX works from the simulator at `localhost`).
