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

## Android: `WireTest`
`android/app/src/androidTest/kotlin/com/livenet/l1ne/WireTest.kt` uses the app's own engine (PJSIP can only start once per process) and checks both what the
engine reports and what the server saw on the wire: registration (good and wrong password, 404, 503, silent server, UDP, disabled account), calls (answered, busy,
declined, unknown, cancelled while ringing, early media, hold and resume, transfer, voicemail button, dial rules, incoming), what is offered (no encryption, SDES keys, DTLS
fingerprint, disabled codec, codec order, ICE candidates, a STUN lookup), texts (sent, received), message waiting, and the login check the QR / setup-link screen
runs before it keeps an account (good login saves nothing, wrong password, unknown extension, server error, silent server).

```bash
tests/mock/run-android-wire-tests.sh          # starts the fake PBX and an emulator (default AVD l1ne_api28), runs the tests, shuts both down
```
Run it on an **emulator**: the tests add and remove their own accounts and change the codec settings, and the emulator reaches the computer as `10.0.2.2`.
The script clears the app's data first.

## Android: `ScreenTest`
`android/app/src/androidTest/kotlin/com/livenet/l1ne/ScreenTest.kt` renders the real app screens (Jetpack Compose UI tests) with a few contacts, chats and calls in place, at a phone width and a wide width, and clicks through them.
It checks that a wide window shows Recents, Contacts, Chats and the Keypad as two panes, that a narrow window keeps the single column with a page and a back arrow, that starting a chat with someone new opens it,
and that an open person moves between the right pane and a page as the window changes size. No PBX is needed. The width is faked through the configuration the layouts read, so the same tests run on any emulator.

```bash
cd android && ANDROID_SERIAL=<emulator> ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.livenet.l1ne.ScreenTest
```
Keep the emulator awake and unlocked (`adb shell svc power stayon true`): a sleeping screen makes every test fail with "No compose hierarchies found". Breaking `TWO_PANE_MIN_DP` on purpose makes 5 of the 8 fail, so they do notice.

## iPhone: `WireTests`
`tests/ios/L1neTests/WireTests.swift` is the same set of scenarios as the Android one (registration, calls, what is offered, texts, message waiting and the QR / setup-link login check), run by Xcode inside the app on a simulator so it drives the app's own engine.

```bash
tests/mock/run-ios-wire-tests.sh               # generates the project, boots the simulator (default "iPhone 17"), starts the fake PBX, runs the tests, stops it
tests/mock/run-ios-wire-tests.sh "iPhone Duo"  # another simulator, by name
```
The simulator reaches the computer as `127.0.0.1` (`PBX=<ip>` for a phone on Wi-Fi). The tests switch the local ringback tone off: a Mac with no audio device makes each attempt to play it stall the app for about 15 seconds.
Written in Swift against `SIPEngine`, `AccountStore` and the other app singletons (`@testable import L1ne`), so they need the PJSIP xcframework built (`scripts/build-pjsip.sh`).

## iPhone and iPad: screen tests (9 tests)
`tests/ios/L1neUITests/ScreenTests.swift` (XCUITest) launches the app with a few contacts, a chat and some calls (the debug-only `UITestSeed`, switched on by `L1NE_UITEST_SEED=1`; Release builds do not contain it)
and clicks through it. On an iPad: Recents, Contacts, Chats and the Keypad are two panes, and they stay two panes when rotated. On an iPhone: one column that pushes pages, the keypad alone,
a chat opens in a page, and starting a chat with someone new opens it (the bug where the sheet closed and nothing appeared). No PBX is needed.

```bash
tests/ios/run-ui-tests.sh                                  # an iPhone 17 simulator, then an iPad Pro 13-inch (M5) simulator; the iPhone-only tests skip on the iPad and the other way round
```
Breaking the iPad Chats layout on purpose makes its test fail, so they do notice.

## Foldables (Android emulator)
An Android 14 **Pixel Fold** emulator profile (`l1ne_fold`: `avdmanager`'s `pixel_fold` device on `system-images;android-34;google_apis;arm64-v8a`) has the hinge sensor. Move the hinge with
`adb shell cmd device_state state 0` (closed: the cover screen), `1` (half open) or `2` (open); screenshots need the display id (`adb exec-out screencap -p -d <id>`, ids from `adb shell dumpsys SurfaceFlinger --display-id`).
The rule being checked: **half open looks exactly like open**, and a call and the app's process survive every change. The iPhone Duo simulator does the same job on iOS (`set_posture`: closed, half open, open).

## What this cannot prove
- Audio quality, echo, Bluetooth and the real network (carrier NAT, firewalls). Only a real call shows those.
- **TURN** (a relay server). There is no TURN server in the fake PBX yet, so TURN is compiled and switchable but not exercised.
- **TLS** with a real certificate chain on Android (use `mock_sip_tls.py` for the offer checks) and **DTLS-SRTP** key exchange (only the offer is checked).
