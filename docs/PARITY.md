# Linphone parity checklist

Source: screenshots of Linphone for iOS settings (Calls, Advanced calls settings, Conversations, Contacts, Meetings,
Network, Advanced settings, Manage account, Account settings incl. NAT policy and Advanced), 2026-11-23.

Tiers: **A** = PJSIP supports it and it works on a plain PBX, build now. **B** = doable but needs extra work or push.
**C** = depends on Linphone's own servers, or is a large separate project, or conflicts with a decision already made.
Status: ☐ not started · ◐ partly · ☑ done.

## Calls

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ☐ | Adaptive rate control | Skip for audio | C | PJSIP has no Linphone-style audio ARC; mostly a video feature. Opus adapts by itself once added |
| ☐ | Automatically start recording calls | Per-call record button + optional auto-record | A | `pjsua_recorder_create` to a WAV in app storage. Needs a consent notice in the UI |
| ☐ | Media encryption: SRTP / ZRTP / DTLS / None | SRTP (SDES) and None | A | ZRTP is not in PJSIP; DTLS-SRTP needs OpenSSL and L1ne's TLS is Apple's Network.framework |
| ☐ | Media encryption mandatory | Switch (SRTP mandatory vs optional) | A | Maps to `use_srtp` mandatory/optional |
| ☐ | Accept early media / Allow outgoing early media | Two switches | A | |
| ☐ | Audio codecs list with switches and order | Codec list, enable/disable, reorder | A | `pjsua_codec_set_priority`. Today built in: PCMU, PCMA, GSM, G722, speex, iLBC. **Opus** needs the Opus library built for iOS (B). G729 is patent/licence encumbered, skip |
| ☐ | Video codecs (H265, H264, AV1, VP8) and "Enable video FEC" | Video calls | C | Large project: PJSIP rebuilt with video (VideoToolbox H264, libvpx), camera, video UI. Decide separately |
| ☐ | Advanced calls settings screen | New Settings > Calls > Advanced | A | |

## Conversations

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ◐ | Conversations tab | Built (SIP MESSAGE) | A | Needs the PBX change in `docs/PBX-MESSAGING.md` |
| ☐ | Do not show message content in iOS notification | Switch | B | Only meaningful once message push exists; push text is already generic by design |
| ☐ | Auto-download files / file sharing | Skip | C | Linphone uses its own HTTP file-sharing server |
| ☐ | IM encryption mandatory / E2E encryption keys server URL | Skip | C | LIME end-to-end encryption needs Linphone's key server |
| ☐ | Use CPIM in "basic" conversations | Skip | C | Linphone's message envelope for delivery receipts |

## Contacts

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ☑ | Contacts | Own address book, manual import | A | Done; no access to phone contacts, no background sync (decided) |
| ☐ | Add LDAP server | **Decision needed** | C | Live directory lookup conflicts with "no constant stream". Could be search-on-demand only |
| ☐ | Add CardDAV address book | **Decision needed** | C | Same: a manual "sync now" import would fit the rule |

## Meetings

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ☐ | Meetings, show past meetings, default layout | Skip scheduling | C | Scheduled meetings need Linphone's conference server |
| ☐ | Conference calls | 3-way conference on the phone, and join a PBX conference room by dialing | B | pjsua's conference bridge mixes calls locally; Asterisk ConfBridge rooms need dialplan on the PBX |
| ☐ | Conference factory URI / audio-video factory URI / CCMP server URL | Skip | C | Linphone conference server settings |

## Network

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ☐ | Use only Wi-Fi networks | Switch | A | Path monitor; unregister on cellular when on |
| ☐ | Allow IPv6 | Switch | A | pjsua IPv6 setting |
| ☐ | STUN/TURN server URL, Enable ICE, Enable TURN, TURN username and password | NAT section per account | A | TURN password in the Keychain |

## Advanced settings (app level)

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ◐ | Remote provisioning URL + "Download & apply" | Field and button in Settings | A | Fetch/parse already built (Profile > Accounts > Set up from QR code or link); add a saved URL and a re-apply button |
| ☐ | Device ID | Optional label sent when provisioning | C | Linphone-server concept; low value |

## Manage account

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ☐ | SIP address with copy button | Show + copy | A | |
| ☐ | Display name | Per-account field | A | Used as the From display name |
| ☐ | International prefix (country code) | Country picker feeding dial rules | A | Builds on the strip/add prefix already in the account |
| ☐ | Connected switch ("everybody can call you") | Enable/disable registration per account | A | |
| ☐ | Devices (other devices on the account) | Skip | C | Needs Linphone's server; a PBX could list contacts via its admin, separate work |
| ☐ | Account settings, Sign out | Account screen with Remove | A | |

## Account settings

| | Linphone setting | L1ne | Tier | Notes |
|---|---|---|---|---|
| ☐ | Allow push notifications | Per-account switch | **LATER** | Push, see `docs/PUSH.md` (no hosted registration proxy). Needs the Apple Developer Program organization account and a small relay |
| ☐ | Voicemail URI | Field + a Voicemail button on the keypad | A | FreePBX: `*97` |
| ☐ | MWI server URI (message waiting indicator) | Voicemail badge | A | `mwi_enabled` and `on_mwi_info`; FreePBX mailbox must exist for that extension |
| ☐ | Format phone numbers using international prefix / Replace + by 00 | Two switches in dial rules | A | Matches the PBX's own provisioning flags (`dial_escape_plus=0`) |
| ☐ | Transport, Registrar URI, Outbound SIP proxy URI | Advanced section | A | Transport and server done; add raw registrar URI override and proxy |
| ☐ | Expire (seconds) | Field, default 3600 | A | |
| ☐ | AVPF, Bundle mode | Skip | C | Video / WebRTC features |

## Suggested order

1. **Account screen and advanced account settings** (everything marked A under Manage account and Account settings, plus Network and NAT).
2. **Calls settings**: codecs, SRTP mandatory, early media, recording.
3. **Voicemail and MWI**, call hold/mute/speaker/transfer (the in-call controls Linphone has).
4. **Push (designed in `docs/PUSH.md`, marked LATER in `docs/ROADMAP.md`)**: the push-mode choice, then the relay and wake-up, then the push switches.
5. **Opus**, conference calls.
6. Decide later: video, LDAP/CardDAV, Linphone-server features (likely never on a plain PBX).

---

## Status 2026-11-23 (end of the Tier A pass)

**Built and verified**
- Account screen: details, display name, country prefix, Connected switch, registrar/proxy/expire, dial rules, voicemail number + MWI,
  media (None / SRTP / DTLS-SRTP, mandatory), NAT (STUN/TURN/ICE). Parser/dial-rule/migration tests in `tests/parsers`.
- Verified on the wire against `tests/mock` (a local SIP/TLS server): OpenSSL TLS 1.2 handshake and certificate verification (an
  untrusted CA is refused and no REGISTER is sent); REGISTER with display name; message-waiting SUBSCRIBE/NOTIFY showing "3 new messages";
  inbound text appears in Conversations; INVITE offers `RTP/SAVP` + `a=crypto` (SDES), `UDP/TLS/RTP/SAVP` + `a=fingerprint` + `a=setup:actpass`
  (DTLS-SRTP), plain `RTP/AVP` (none); IPv6 compiled in and attempted.
- LDAP (own client) and CardDAV against real OpenLDAP and Radicale servers: `tests/directory/run.sh`, 31 checks.
- Found and fixed: calls/texts/MWI went to plain UDP 5060 instead of the TLS server (everything is now routed through the account's server);
  incoming calls never sent 180 Ringing; PJSIP offered an unwanted real-time-text stream; a launch crash because the library lacked IPv6.

**Built, not yet verified against a real server**
- Registration and calls against a real PBX.
- The DTLS-SRTP *handshake* with a real peer (the offer is verified; a PBX/peer that answers DTLS is needed).
- Call recording, codec reordering effect, hold/mute/transfer, TURN/ICE, Wi-Fi-only, early media: compile and UI checked, no live call yet.
- Directory sync scheduling in the background: iOS decides when background runs happen.

**Not done**
- Tier B: push (needs an Apple Developer Program organization account), Opus (many PBXes offer no Opus), conference calls.
- Tier C: video, ZRTP, Linphone-server features.
- Android: the app mirrors the iPhone one (same screens and settings, system call screen, foreground service). The rows marked ☐ above are still open on both platforms.
