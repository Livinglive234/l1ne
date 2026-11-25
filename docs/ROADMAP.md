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

## LATER: other deferred items
Opus (many PBXes offer none), conference calls, and Linphone-server features (file sharing, meetings), which a plain SIP server cannot provide.
