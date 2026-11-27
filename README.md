# L1ne

**A privacy-minded phone app for your own phone system.** L1ne is a SIP softphone for iPhone and Android: sign in to a FreePBX, Asterisk,
Kamailio, 3CX (in SIP mode) or hosted SIP account and make and receive calls, send texts and keep a call history. It has no account of its own,
no cloud service, no analytics and no ads. Your login stays on your phone.

Built on [PJSIP](https://github.com/pjsip/pjproject), with SwiftUI on iOS and Jetpack Compose on Android. The two apps look and behave the same.

[![Android](https://github.com/Livinglive234/l1ne/actions/workflows/android.yml/badge.svg)](https://github.com/Livinglive234/l1ne/actions/workflows/android.yml)
[![iOS](https://github.com/Livinglive234/l1ne/actions/workflows/ios.yml/badge.svg)](https://github.com/Livinglive234/l1ne/actions/workflows/ios.yml)
[![Build scripts](https://github.com/Livinglive234/l1ne/actions/workflows/scripts.yml/badge.svg)](https://github.com/Livinglive234/l1ne/actions/workflows/scripts.yml)

- **Your phone system, your data.** L1ne only talks to the server you sign in to.
- **Its own address book.** It never reads the contacts on your phone. Contacts come from files and servers you set up yourself.
- **Works on older and cheaper phones.** iOS 15 or newer, Android 8 or newer, including 32-bit Android phones.
- **Easy setup.** Type three details, scan a QR code, or open a setup link. Linphone-style configuration files work too.

> **Status: early but usable.** Both apps make and receive calls and are being tested against a real FreePBX server. Calls arrive while the app is
> open or running in the background on Android. Waking an iPhone for a call while the app is closed needs push notifications, which are designed
> but **not built yet** (see [Incoming calls in the background](#incoming-calls-in-the-background)). The [roadmap](docs/ROADMAP.md) lists what is next.

## Getting started

Open the app and you land on a welcome screen. Pick whichever of these your phone-system administrator gave you:

| You have | Do this |
|---|---|
| A server name, an extension or username, and a password | Type them in and tap **Login**. Add the display name people should see when you call them, and choose TLS, TCP or UDP if your server needs it. |
| A QR code | Tap **Scan QR code**. |
| A setup link (`https://…`, `l1ne-config:` or `linphone-config:`) | Tap **Open a setup link**. |
| A server with unusual settings (own registrar, outbound proxy, separate authentication name) | Tap **More options**. |

The password is the SIP password for the extension, not a web login. L1ne checks the login right away and tells you in plain words what went wrong:
wrong password, unknown extension or an unreachable server. You can add more accounts later from the profile menu.

## What it does

**Calls**
- Several accounts at once, each with its own server, transport (TLS, TCP or UDP), media encryption (SRTP or DTLS-SRTP), NAT settings, dial rules and voicemail number.
- Hold, mute, speaker, Bluetooth and headset routing, keypad tones, blind transfer, call recording and a call-quality indicator.
- Shows whether a call is encrypted. Message-waiting light and a voicemail button.
- Local ringback tones (classic US and UK, chime, digital and pulse) while the other phone rings, because most phone systems send no ringback of their own.
- **Quiet redial:** if a call fails right after the phone changes network (Wi-Fi to mobile), L1ne retries once without bothering you.
- Dial from the keypad by name: type letters or digits and pick a suggestion.
- `sip:` and `sips:` links open L1ne with the number filled in.

**Messages and contacts**
- Text messages over SIP `MESSAGE` (the server has to route them; see [docs/PBX-MESSAGING.md](docs/PBX-MESSAGING.md)).
- Contacts from a vCard file or link, CardDAV, LDAP or a PBX contact list. Only entries that have a SIP address are kept.

**On the phone**
- iPhone: calls use CallKit, so they look like normal calls, appear in the Phone app's Recents and can be called back from there.
- Android: calls use the system call screen (self-managed Telecom), a lock-screen call notification and the proximity sensor.
- Light and dark mode and large-text support. The Android layouts adapt to small phones and tablets.

## Supported phones

- **iPhone and iPad: iOS 15 or later** (iPhone 6s and newer). SwiftUI itself needs iOS 13, and the Xcode used here builds nothing below iOS 15.
  A few newer SwiftUI features have stand-ins in `L1ne/Compat.swift`, so older phones get slightly simpler versions of the same screens.
- **Android: 8.0 (API 26) or later**, on 64-bit (`arm64-v8a`) and 32-bit (`armeabi-v7a`) ARM. Many budget phones run a 32-bit system even on a 64-bit chip.

Tested so far: iPhone (current iOS) and a Samsung Galaxy (current Android), the Android 8 emulator, and small-phone, tablet and large-text sizes.
**Not yet tried on real hardware:** iOS 15 and 16, and any 32-bit Android phone. They build and should work; reports are welcome.

## Downloads

**Releases** (the *Releases* page on the right) are the builds to use. A release is made by pushing a version tag: GitHub Actions builds it and signs the Android APKs.
A tag such as `v0.1.0-beta.3` becomes a published **pre-release** ("L1ne 0.1.0 beta 3"); a plain `v0.1.0` becomes a draft that the maintainer publishes after a look. See [docs/RELEASING.md](docs/RELEASING.md).

- **Android `.apk`:** needs Android 8 or later. Choose `arm64-v8a` for almost any phone from the last several years (about 25 MB), `armeabi-v7a` for older
  or budget phones with a 32-bit system (about 22 MB), or `universal` if you are not sure (about 31 MB). Releases and betas are signed with the project's release key, so
  each new one installs over the previous one and keeps your accounts and data (allow installs from your browser or file manager the first time). If you
  installed an earlier *debug* build, uninstall it once first: Android will not replace an app signed with a different key.
- **iPhone `.ipa`:** **unsigned**, so it will not install as it is. Sign it with your own Apple ID using a sideloading tool, or build from source (below).

Every push to `main` and every pull request is also built; open a finished run under the **Actions** tab and look in its *Artifacts* section. Those APKs are
debug-signed with a throwaway key, for testing only, and cannot be updated in place.

These are GPL-covered builds; see [LICENSING.md](LICENSING.md) for what that means if you pass them on. The source for any build is this repository at that commit.

## Privacy

- No account, no analytics, no advertising, no crash reporting, no third-party servers. L1ne talks only to the servers you add.
- SIP passwords are kept in the iOS Keychain or the Android Keystore, never in plain files.
- The app never reads your phone's address book. Contacts that arrive through an import stay inside L1ne.
- The iOS privacy manifest declares no tracking and no data collection.
- If you turn on push in future, the push relay stores only a device push token. Details and the exact rules are in [docs/PUSH.md](docs/PUSH.md).

## Incoming calls in the background

iOS suspends apps, and a suspended app cannot keep its SIP registration alive, so a call can only wake an iPhone through an Apple VoIP push.
Android can keep L1ne running with a small foreground notification, so it works there today.

L1ne is designed so that **nobody has to hand their SIP login to a third party**. The plan, per account:

| Option | PBX setup | Who holds your SIP login | Status |
|---|---|---|---|
| **No push** (default) | none; calls arrive while L1ne is open, and the app says so plainly | your phone only | works today |
| **Webhook push** | one snippet pasted into your PBX (FreePBX/Asterisk first) | your phone only | designed |
| **Self-hosted proxy** | run the open-source proxy yourself | your own server | designed |

There is deliberately no hosted service that keeps your registration alive for you. The design, the data rules for the push relay and the wake-up
sequence are in [docs/PUSH.md](docs/PUSH.md).

## Building from source

You need a Mac with Xcode 26 or newer for iOS (nothing else can build it), and a JDK plus the Android SDK and NDK for Android. The native libraries (PJSIP and OpenSSL) are
downloaded and built from source; nothing third-party is stored in this repository.

### iOS
Needs [XcodeGen](https://github.com/yonaskolb/XcodeGen) and about 5 GB of disk for the dependency builds.

```bash
scripts/fetch-deps.sh            # downloads pjproject 2.17 and OpenSSL 3.5.9 (checksum verified) into vendor/
scripts/build-openssl.sh         # builds OpenSSL for iOS device and simulator
scripts/build-pjsip.sh           # builds PJSIP (TLS, SRTP, DTLS-SRTP, IPv6) into vendor/PJSIP.xcframework
export L1NE_TEAM_ID=XXXXXXXXXX   # your Apple Developer Team ID; skip for simulator-only builds
scripts/gen.sh                   # generates L1ne.xcodeproj from project.yml
xcodebuild -project L1ne.xcodeproj -scheme L1ne -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The bundle ID in `project.yml` is `com.livenet.l1ne`; change `APP_ID` if you build your own copy. The push capability is left out until push exists
(a commented skeleton is in `project.yml`), so a free Apple developer account is enough to run it on your own device.

### Android
Works on macOS, Linux and Windows. On **Windows**, build the native libraries inside **WSL** (Ubuntu), because OpenSSL cannot use the Android compilers from
Git Bash or MSYS2; the Gradle app build itself runs natively on Windows. The `Build scripts` workflow checks all three.
```bash
scripts/fetch-deps.sh                          # if you have not already
scripts/build-android-native.sh arm64-v8a      # OpenSSL + PJSIP for 64-bit phones into vendor/android/arm64-v8a
scripts/build-android-native.sh armeabi-v7a    # the same for 32-bit phones
cd android
./gradlew :core:test                           # the shared Kotlin core needs only a JDK (21)
./gradlew :app:assembleDebug                   # needs the Android SDK and NDK 29.0.14206865: set ANDROID_HOME or sdk.dir in android/local.properties
```
The NDK version is pinned in `scripts/lib.sh` and `android/app/build.gradle.kts` (keep the two in step). Use `gradlew.bat` in a Windows command prompt.

## Tests
- `tests/mock/pbx.py` + the wire tests: L1ne's real SIP engine against a scriptable fake PBX (login errors, busy, early media, hold, transfer, SRTP/DTLS offers, STUN, texts, voicemail),
  no real server needed: `tests/mock/run-android-wire-tests.sh` (Android) and `tests/mock/run-ios-wire-tests.sh` (iPhone, the same scenarios).
- Screen tests: the real screens at phone and tablet widths. Android: `ScreenTest` (Compose UI tests). iPhone and iPad: `tests/ios/run-ui-tests.sh` (XCUITest on an iPhone and an iPad simulator). See [docs/TESTING.md](docs/TESTING.md).
- `android/core`, `android/app`: JVM unit tests (`gradle :core:test :app:testDebugUnitTest`) and instrumented tests for the stores and the engine's event handling
  (`gradle :app:connectedDebugAndroidTest`, on a device or emulator).
- `tests/parsers`: vCard, provisioning, dial rules, account migration and contact-source rules as plain Swift, no simulator needed.
  `tests/parsers/run.sh`
- `tests/directory/run.sh`: the LDAP and CardDAV clients against real OpenLDAP and Radicale servers (`brew install openldap`, a Python venv with `radicale`).
- `tests/mock`: a local SIP-over-TLS server and scripts that place a call from the simulator and print the encryption lines in the offer.

Be careful with `connectedDebugAndroidTest` on a phone you use: Android removes the app (and its data) when the test run ends unless
`android.injected.androidTest.leaveApksInstalledAfterRun=true` is set, which `android/gradle.properties` does.

## Project layout

| Path | What is in it |
|---|---|
| `L1ne/` | the iPhone app (SwiftUI) |
| `android/core/` | shared Kotlin logic with no Android dependencies: accounts, provisioning, dial rules, parsers |
| `android/app/` | the Android app (Compose), the PJSIP bridge in C (`src/main/cpp`) and the Telecom integration |
| `scripts/` | dependency download and native build scripts (`lib.sh` holds the macOS/Linux/Windows differences), and the one PJSIP patch |
| `.github/` | the build workflows (Android, iOS, build scripts) and the release notes text |
| `tests/` | parser tests, directory-server tests, a mock SIP server and fixtures |
| `docs/` | [design](docs/DESIGN.md), [testing](docs/TESTING.md), [roadmap](docs/ROADMAP.md), [feature parity](docs/PARITY.md), [push design](docs/PUSH.md), [PBX text messaging](docs/PBX-MESSAGING.md) |

## License

- L1ne's own source code is **MIT** ([LICENSE](LICENSE)).
- A built copy of L1ne contains **PJSIP (GPL-2.0-or-later)**, so anyone who distributes a build must follow the GPL for the combined work. Using your
  own build needs nothing; distributing one does. Read [LICENSING.md](LICENSING.md) first, in particular the section about the App Store and TestFlight.
- Third-party components and their licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

L1ne is not affiliated with Linphone, Teluu (PJSIP) or any phone-system vendor.
