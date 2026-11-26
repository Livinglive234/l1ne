# Roadmap

What exists, what is next, and what is deliberately later. Updated 2026-11-25.

## Built, under test
Both apps (iPhone and Android) have accounts and settings, calls with in-call controls, contacts (own address book, imports and syncs), text messages,
call history, voicemail and message-waiting, codec list, recording, early media, local ringback tones, quiet redial after a network change, Wi-Fi-only, IPv6,
DTLS-SRTP, Linphone-style provisioning, QR setup, `sip:` links and a first-run welcome screen. Android adds the system call screen, a foreground service and
Bluetooth routing. Verified against a local mock SIP/TLS server, real OpenLDAP and Radicale servers, and a real FreePBX server.

## Next
- Keep testing against real PBXes, on real older phones (iOS 15 and 16, 32-bit Android).
- Apply and test the server-side text-messaging configuration ([PBX-MESSAGING.md](PBX-MESSAGING.md)).
- An Apple Developer Program **organization** account (needed for push, TestFlight and team signing), then a first TestFlight build.
- Push for iPhone ([PUSH.md](PUSH.md)): the choice of push mode in account setup, re-registering when the app opens or the network changes, then the relay and wake-up.

## LATER: push to the app (see [PUSH.md](PUSH.md))

> **Status: designed, not built.** Needs an Apple Developer Program organization account (an APNs key) and, for Android, a Google FCM key.

**The decision.** L1ne offers per account: **No push** (default), **Webhook push** (one snippet on the PBX, the relay stores only a device token) and a
**self-hosted proxy** (the user runs it and holds their own login). A **hosted registration proxy was ruled out on purpose**: it would mean holding other
people's SIP logins, which this project will not do. [PUSH.md](PUSH.md) has the wake-up sequence, the data rules for the relay and the build order.

**Still open**
- Which proxy to base the self-hosted option on (Kamailio or Flexisip) and how it keeps registrations alive towards servers that restrict source addresses.
- Android push through the same relay (FCM); cost and uptime of the hosted relay.
- Apple's rule: every VoIP push must show an incoming call immediately, so the relay may push only for real calls.

## CallKit

Calls go through CallKit (`CallKitManager`): the lock-screen call card, the green call indicator, system answer/decline, hold and mute from
headsets and the car. Calls also appear in the Phone app's Recents unless you switch that off in Settings → Calls. A call arriving while L1ne is closed still needs push (see [PUSH.md](PUSH.md))
to wake the app; CallKit by itself cannot do that.

## LATER: voicemail notifications

> **Status: LATER. Skeleton only.** Settings → Voicemail has a "Notify me of new voicemail" switch (disabled) and `VoicemailNotifier`
> is called whenever the message-waiting count goes up, but it does nothing yet.

While the app is running, a local notification is easy. With the app closed it needs push (see [PUSH.md](PUSH.md)): the relay would be told about new voicemail and push the phone. Until then the Voicemail tab badge and the keypad
button count show new messages only while L1ne is running.

## LATER: ZRTP, video calls and end-to-end encrypted texts

None of these is started. They are listed so they are not forgotten, with what each one needs.

**ZRTP (call encryption without the PBX's help).** ZRTP agrees keys between the two phones during the call and shows a short code both people can read out to rule
out a man in the middle. It works on a plain PBX, since the PBX only relays audio. **Not in PJSIP.** It needs a ZRTP library (GNU ZRTP or ZRTP4PJ) built for iOS and
Android and hooked into PJSIP's media layer, plus a "verify this code" screen. Only worth it if the other end also speaks ZRTP (Linphone does; most phones do not).

**Video calls.** Needs PJSIP rebuilt with video: H.264 (VideoToolbox on iPhone, MediaCodec on Android) and VP8, the camera and its permissions, a video call screen
(picture-in-picture, camera flip, mute video), bandwidth handling and the SDP/AVPF settings. Many PBXes need video enabled per extension. It is a large piece of work on both platforms.

**End-to-end encrypted texts.** Plain SIP `MESSAGE` goes through the PBX in the clear. The usual fix is Linphone's LIME, which needs a **key server** run by Linphone, so it
only works between Linphone-family apps. Options: (1) skip it; (2) use an open standard that needs no vendor server, for example an OMEMO-style or Signal-style double ratchet
carried inside SIP `MESSAGE`, with public keys published through the PBX (a vCard/URL on the contact, or a small `OPTIONS`/`PUBLISH` exchange). That would be new and only
L1ne-to-L1ne. Decide later; it must not need a hosted server run by this project (see the push decision above).

## LATER (maybe): group chats through a self-hosted Flexisip server

Not started, and not planned for the first releases. Plain SIP `MESSAGE` is one person to one person, and FreePBX/Asterisk have no group text. Linphone's group chats need a **chat room server**, and the one
they use is **Flexisip** (Belledonne Communications), published as open source (**AGPLv3**, with a paid proprietary licence as the alternative). A user would run it themselves; no server run by this project would be involved.

What the Linphone documentation says about running it next to an existing phone system ([third-party SIP servers page](https://wiki.linphone.org/xwiki/wiki/public/view/Flexisip/Conference%20server/Flexisip%20group%20chat%20server%20integration%20with%20third%20party%20SIP%20servers/), read 2026-11-26):
- The existing system must be **proxy-style software** (the page names Kamailio, OpenSIPS and SER) that authenticates the clients and routes their SIP. **It does not mention Asterisk or FreePBX**, so whether this can work with a plain FreePBX is unknown and probably needs an extra proxy in front.
- That proxy must **copy accepted REGISTERs to the Flexisip machine**, **route `sip:conference-factory@<domain>` and `sip:chatroom-*@<domain>` to it**, and **let requests from the Flexisip machine through without a login challenge**.
- Flexisip keeps chat room state in **MySQL/MariaDB**, and today also needs **Redis** (the page says a later version will drop the Redis and registrar-copy requirements).
- Clients need Linphone 5.x (linphone-sdk 5.2 or newer) to be "conference aware".

Not confirmed: how a client is told the server's address (the page does not say; the address pattern above suggests a `conference-factory` account setting), and the exact option names. Check Flexisip's [conference server configuration](https://wiki.linphone.org/xwiki/wiki/public/view/Flexisip/Configuration/Conference%20server%20configuration/) and liblinphone before building anything.
Supporting it in L1ne would mean implementing Linphone's group chat protocol on both platforms, and it would only work against a Flexisip server. A "group" that just sends the same text to each person separately was rejected: replies would come back as separate one-to-one chats, which is misleading.

## Built: wide screens, and LATER: foldable and dual-screen phones

**Built (2026-11-25): two-pane layouts on wide windows**, on both platforms, whenever the window is wide (iPad, the iPhone Duo's inner screen, an Android tablet or unfolded foldable; Android: 840 dp or more).
Recents, Contacts and Chats show the list beside the person or conversation; the Keypad shows the matching contacts (or recent calls while the number is empty) beside the keys.
Voicemail and Settings stay single-column (nothing to show beside them) at a readable width. On a narrow window nothing changes. The keypad also shrinks its keys on a short screen. Tested on the iPad Pro 13" and iPhone Duo simulators and an Android tablet emulator; the Duo's hinge postures were checked (closed, half open, flat) and the keypad entry survived switching screens.
Android's main activity handles size changes itself, so folding does not recreate it.

**Still to do for foldables:** Jetpack WindowManager fold and hinge handling, a tabletop posture, the call screen across a screen change, and testing on a foldable emulator profile or real hardware.

- **Android foldables** (Samsung Galaxy Z Fold and Flip, Google Pixel Fold, and dual-screen phones such as the Microsoft Surface Duo): use Jetpack WindowManager to read the fold and
  hinge, keep content out of the hinge area, and handle the cover screen and inner screen switching without losing the call or the keypad entry. Ideas: a two-pane layout
  (list and detail, keypad and call) when the screen is wide, and a **tabletop / laptop posture** for a call (controls on the lower half, caller on the upper half).
- **Calls across a fold or a screen change** must survive the activity being recreated (a call already keeps going; check the in-call screen state and keyboard).
- **iPhone Duo** (a dual-screen iPhone; Xcode has an *iPhone Duo* simulator, `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`): a small outer screen and a large inner screen, with the hinge
  closed, half open (any angle) or flat. The app has to lay out on both screens, survive the switch between them mid-call (a call, the keypad entry and the keyboard must not be lost),
  and cope with the hinge posture. Test in the simulator by moving the hinge between closed, half open and open and checking each screen. Check that no black bars appear on the inner screen.
- Android: needs real hardware or the emulator's foldable and resizable profiles. iPhone Duo: the Xcode simulator.

## LATER: desktop apps (Windows, macOS, Linux)

Not started. A softphone on the computer, with the same privacy rules (no account, no cloud, no analytics) and the same look.

- **What can be shared.** The SIP engine is PJSIP, which already builds for all three. The Kotlin core (`android/core`: accounts, provisioning, dial rules, parsers) has no Android dependency
  and could run on the JVM; the iPhone app has its own Swift twin of the same logic.
- **Choices to make.** (1) **Compose Multiplatform** (Kotlin) reusing the Android screens and core, a JNI/JNA bridge to PJSIP, one codebase for Windows, macOS and Linux;
  (2) a native Mac app in SwiftUI (reusing much of the iPhone app; Mac Catalyst or a native macOS target) plus something else for Windows and Linux;
  (3) Electron or Tauri, which is quick but heavy and awkward for audio. Leaning to (1), with a Mac build from the same code.
- **Desktop-specific work.** Audio device choice (headset, speakers, mic) and echo cancellation, call notifications and a ringing window, a system tray / menu bar icon, global
  `sip:` and `tel:` link handling, keyboard shortcuts, running at login, window sizes, secure password storage (Keychain, Windows Credential Manager, Secret Service), and installers
  (signed `.msi`/`.exe`, notarised `.dmg`, `.deb`/AppImage/Flatpak). Mac distribution has the same GPL/App Store question as the iPhone ([LICENSING.md](../LICENSING.md)).
- **No push needed** on a desktop: the app can stay running and registered.

## LATER: other deferred items
Opus (many PBXes offer none), conference calls, and Linphone-server features (file sharing, meetings), which a plain SIP server cannot provide.
