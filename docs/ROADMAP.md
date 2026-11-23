# Roadmap

What exists, what is next, and what is deliberately later. Updated 2026-11-23.

## Built (iOS), under test
Accounts and settings, calls with in-call controls, contacts (own address book, imports and syncs), text messages, call history, voicemail and
message-waiting, codec list, recording, early media, Wi-Fi-only, IPv6, DTLS-SRTP, Linphone-style provisioning. Verified against a local mock SIP/TLS
server (TLS verification, registration, MWI, inbound text, SDES/DTLS/none offers) and against real OpenLDAP and Radicale servers.

## Next
- Test registration and calls against real PBXes.
- Apply and test the server-side text-messaging configuration ([PBX-MESSAGING.md](PBX-MESSAGING.md)).
- An Apple Developer Program **organization** account (needed for push, TestFlight and team signing).
- Android app: account screen, calls, contacts, messages on top of the tested core.

## LATER: push to the app for any server (the push proxy)

> **Status: LATER. Not started, not scheduled.** Needs an Apple Developer Program organization account (APNs key), a Google FCM key for
> Android, and a small always-on server.

**The decision.** Do it as a **proxy**: L1ne registers through a gateway that keeps the registration towards the user's server, so a server of any kind
needs no change. On an incoming call the gateway pushes the phone, waits for the app to wake and connect, then passes the call through.

**Alternatives that were not chosen** (kept for reference):
- *Webhook*: the server tells the gateway about each call and holds it until the app registers. Easy on Asterisk/FreePBX, but every server admin has to add a hook, and 3CX or hosted PBXes cannot.
- *RFC 8599 push parameters*: only servers that implement the standard (Flexisip, some Kamailio) can use them. L1ne will still put these parameters in its registration so compatible servers can use them.

**Open questions for when this starts**
- Which SIP proxy to run (Kamailio or Flexisip) and how it keeps registrations alive towards servers that restrict source addresses.
- Media: keep RTP direct (device to server) so SRTP/DTLS stay end to end; the proxy handles signalling only.
- Trust and privacy: the proxy sees signalling, so it has to be run by the user or someone they trust. Pushes to Apple carry only a generic "incoming call".
- Abuse limits: per-device secrets, rate limits, only ring for servers the user added.
- Apple's rule: every call-type (VoIP) push must show an incoming call immediately, so the proxy may push only for real calls.
- Android uses FCM through the same gateway; cost and uptime of the service.

The gateway and proxy can be built and tested against a fake push endpoint before the Apple account exists; real pushes need it.

## LATER: voicemail notifications

> **Status: LATER. Skeleton only.** Settings → Voicemail has a "Notify me of new voicemail" switch (disabled) and `VoicemailNotifier`
> is called whenever the message-waiting count goes up, but it does nothing yet.

While the app is running, a local notification is easy. With the app closed it needs the push gateway above (the gateway would watch the
message-waiting subscription, or the server's voicemail event, and push the phone). Until then the Voicemail tab badge and the keypad
button count show new messages only while L1ne is running.

## LATER: other deferred items
Opus (many PBXes offer none), conference calls, video calls, and Linphone-server features (end-to-end encrypted chat, file sharing, meetings),
which a plain SIP server cannot provide.
