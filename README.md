# L1ne

A privacy-minded SIP softphone for iOS (SwiftUI) and Android (Compose), built on [PJSIP](https://github.com/pjsip/pjproject).
It works with any SIP server (FreePBX/Asterisk, Kamailio, 3CX in SIP mode, hosted providers) and can set itself up from the same
remote-configuration files and QR codes that Linphone uses.

> **Status:** early. The iOS app builds and is under test against a real PBX. The Android app is a skeleton with a tested shared core.
> See [docs/ROADMAP.md](docs/ROADMAP.md) for what exists, what is next and what is deliberately later.

## Supported phones
- **iPhone / iPad:** iOS 15 and later (iPhone 6s and newer). SwiftUI itself needs iOS 13, and the Xcode used to build this no longer targets anything below iOS 15.
  Newer-only SwiftUI features (iOS 16 and 17) have stand-ins in `L1ne/Compat.swift`, so older phones get a slightly simpler version of the same screens.
- **Android:** Android 8.0 (API 26) and later, 64-bit (`arm64-v8a`) and 32-bit (`armeabi-v7a`) ARM. Many budget phones run a 32-bit system even on a 64-bit chip, so the 32-bit build matters.
  Native libraries: `scripts/build-android-native.sh arm64-v8a` and `scripts/build-android-native.sh armeabi-v7a`.

## What it does
- Several accounts at once, each with its own server, transport (TLS / TCP / UDP), SRTP or DTLS-SRTP, NAT settings, dial rules and voicemail number.
- Calls with hold, mute, speaker, DTMF, blind transfer, recording and call history; message-waiting indicator.
- Text messages over SIP `MESSAGE` (the server has to route them; see [docs/PBX-MESSAGING.md](docs/PBX-MESSAGING.md)).
- Its **own address book**: it never reads your phone's contacts. Contacts arrive only through imports and syncs you set up
  (vCard file or link, CardDAV, LDAP), and only entries with a SIP address are kept.
- Linphone-compatible provisioning: scan a QR code or open a `linphone-config:` / `l1ne-config:` link.
- TLS and DTLS-SRTP through OpenSSL with a bundled CA list; calls, texts and subscriptions are routed through the account's server.

## Incoming calls in the background
iOS suspends apps, and a suspended app cannot keep its SIP registration alive, so a call can only wake an iPhone through an
Apple VoIP push. L1ne is built so that **nobody has to hand their SIP login to a third party**. You choose per account:

| Option | PBX setup | Who holds your SIP login |
|---|---|---|
| **No push** (default) | none. Calls arrive while L1ne is open; the app says so plainly | your phone only |
| **Webhook push** | one snippet pasted into your PBX (FreePBX/Asterisk first) | your phone only |
| **Self-hosted proxy** | run the open-source proxy yourself | your own server |

The push relay stores only a device push token and nothing about your calls, accounts or contacts. There is no hosted service
that keeps your registration alive for you. Design and data rules: [docs/PUSH.md](docs/PUSH.md). This is a design so far; nothing here
is built yet except the default (no push).

## Build (iOS)
Requires Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and about 5 GB of disk for the dependency builds.

```bash
scripts/fetch-deps.sh            # downloads pjproject 2.17 and OpenSSL 3.5.9 (checksum verified) into vendor/
scripts/build-openssl.sh         # builds OpenSSL for iOS device and simulator
scripts/build-pjsip.sh           # builds PJSIP (TLS, SRTP, DTLS-SRTP, IPv6) into vendor/PJSIP.xcframework
export L1NE_TEAM_ID=XXXXXXXXXX   # your Apple Developer Team ID; skip for simulator-only builds
scripts/gen.sh                   # generates L1ne.xcodeproj from project.yml
xcodebuild -project L1ne.xcodeproj -scheme L1ne -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The bundle ID in `project.yml` is `com.livenet.l1ne`; change `APP_ID` if you build your own copy. The push capability is left out until push
exists (see the roadmap), so a free Apple developer account is enough to run it on your own device.

## Build (Android)
```bash
cd android
gradle :core:test      # the shared Kotlin core builds with just a JDK
# :app needs the Android SDK and NDK; set ANDROID_HOME or sdk.dir in local.properties, then: gradle :app:assembleDebug
```

## Tests
- `tests/parsers`: vCard, provisioning, dial rules, account migration, contact-source rules (plain Swift, no simulator).
  `swiftc -o /tmp/p L1ne/VCard.swift L1ne/Provisioning.swift L1ne/Account.swift L1ne/SystemContacts.swift L1ne/ContactsStore.swift tests/parsers/main.swift && /tmp/p tests/fixtures`
- `tests/directory/run.sh`: the LDAP and CardDAV clients against real OpenLDAP and Radicale servers (`brew install openldap`, a Python venv with `radicale`).
- `tests/mock`: a local SIP-over-TLS server and scripts that place a call from the simulator and print the encryption lines in the offer.
- `android/core`: the same fixtures from Kotlin (`gradle :core:test`).

## License
- L1ne's own source code is **MIT** ([LICENSE](LICENSE)).
- A built copy of L1ne contains **PJSIP (GPL-2.0-or-later)**, so anyone who distributes a build must follow the GPL for the combined work.
  Using your own build needs nothing; distributing one does. Read [LICENSING.md](LICENSING.md) first, in particular the section about the App Store and TestFlight.
- Third-party components and their licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
