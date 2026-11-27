# L1ne design

## Accounts
An **account** is one SIP identity on one server; the app holds several. Fields: label, display name, domain, port, transport
(`tls` default / `tcp` / `udp`), optional registrar URI and outbound proxy, expiry, an enabled switch, media encryption
(`none` / SRTP-SDES / DTLS-SRTP, optionally mandatory), username, optional auth user, dial rules (strip/add prefix, international prefix,
`+` to `00`), voicemail number and MWI switch, ICE/TURN/STUN. Secrets live only in the Keychain.

- The port follows the transport (UDP and TCP 5060, TLS 5061) unless you set a custom one.
- A new account is created from a short form (username, password, domain, display name, transport, advanced); everything else is edit-only.
- **Routing:** calls, texts and the MWI subscription are sent *through the account's server over its own transport*. PJSIP's default would
  resolve the domain and use plain UDP 5060, which a TLS-only PBX never sees.
- Incoming calls answer `180 Ringing` (or `183` if outgoing early media is on).

## Security
- TLS and DTLS-SRTP use **OpenSSL** (built by `scripts/build-openssl.sh`). OpenSSL has no access to the OS trust store, so a CA bundle
  (`ios/Resources/cacert.pem`, Mozilla's list) is shipped and the server certificate is verified against it. An untrusted certificate is refused
  and no SIP traffic is sent.
- Media encryption: SRTP (SDES; keys travel in the SDP, so it requires TLS) or DTLS-SRTP, optional or mandatory. SDES on UDP/TCP is warned about.
- New accounts default to mandatory SRTP on TLS (the `RTP/SAVP` form that PBXes requiring SDES expect) and no encryption on UDP/TCP.

## Contacts
- L1ne **never reads the phone's contacts** (no Contacts permission). *Import from Contacts* uses the system picker, which runs out of process,
  so L1ne receives only the contacts you tap.
- Only entries with a **SIP address** are kept (`IMPP`/`X-SIP`/`SIP`, or a `TEL`/`URL` value that starts `sip:`). Phone numbers and other fields are dropped.
- Sources of contacts: typed in, vCard file, picker, a vCard link (one-time import, or a syncing source), CardDAV, LDAP.
- **Sync sources** (vCard link, CardDAV, LDAP) each have a frequency: manual, every time the app opens, 15 minutes, hourly, 6 hours, daily.
  They run while the app is open and, when iOS allows, in the background. A sync makes that source's contacts match the server exactly.
- A real directory (CardDAV or LDAP) **replaces** the vCard link: enabling one asks first, then removes what the link brought.
- Typed-in and picked contacts are never touched by a sync, and a sync never overwrites an entry someone else created.
- LDAP is a small hand-written LDAPv3 client (simple bind + subtree search over LDAPS or plain TCP); CardDAV uses one `REPORT` with a
  `PROPFIND`+`GET` fallback.

## Text messages
SIP `MESSAGE` (RFC 3428) through pjsua. Threads are stored only on the phone, per account and peer. A server that answers 405/501/415 marks the
account as not supporting texts; 404/480/408/503 show as "not reachable". Failed sends can be retried from the bubble. The server must route
`MESSAGE`; see [PBX-MESSAGING.md](PBX-MESSAGING.md). Offline delivery needs push (later).

## Provisioning (Linphone-compatible)
L1ne reads **Linphone's remote-configuration XML** (`<config><section name="proxy_0"><entry name="...">`) from a QR code that holds an https URL,
a `linphone-config:https://…` or `l1ne-config:https://…` link, or a pasted URL. It is fetched once, shown for review, then saved.

| Linphone config | L1ne |
|---|---|
| `proxy_N/reg_identity` | username, domain, display name |
| `proxy_N/reg_proxy` | server, port, transport |
| `proxy_N/reg_expires` | expiry |
| `proxy_N/reg_sendregister=0` | skipped |
| `auth_info_N/{username,userid,passwd,domain}` | login, auth user, secret |
| `sip/media_encryption` (`none`/`srtp`/`dtls`/`zrtp`) | media (`zrtp` = ZRTP) |
| `sip/media_encryption_mandatory` | mandatory switch |
| `misc/contacts-vcard-list` | optional contact sync source (on by default when present) |
| `proxy_N/l1ne_outbound_prefix` | L1ne's own entry (Linphone ignores it), set per account inside that account's `proxy_N` section: its outside-line prefix, for example `9`. Up to 4 characters from `0-9 * #`; an empty value means none, which also overrides the file default below. Put in front of numbers with 10 digits (or 1 and 10 digits) only; extensions like 7001 and codes like *97 dial as they are, and the call history keeps the number without it. Example: `<entry name="l1ne_outbound_prefix">9</entry>` |
| `l1ne/outbound_prefix` | L1ne's own section: a default prefix for every account in the file that has no `l1ne_outbound_prefix` of its own. Same rules. Example: `<section name="l1ne"><entry name="outbound_prefix">9</entry></section>` |
| `ha1` only | account added without a secret |

The review screen shows each account with its own switch; nothing is forced. Fixtures: `tests/fixtures/linphone-provision.xml`.

## Push (later)
See [PUSH.md](PUSH.md) and [ROADMAP.md](ROADMAP.md). Decided approach: a per-account choice of No push (default), Webhook push (one PBX snippet; the relay stores only a
device token) or a self-hosted proxy. A hosted proxy that holds people's SIP logins was ruled out on purpose. Designed, not built.

## Android
Same product, formats and rules, with Android conventions: Material 3 theme with the same palette, an avatar menu that opens account and settings,
the system Telecom `ConnectionService` for calls, and the contact picker via `ACTION_PICK` (no `READ_CONTACTS`). The engine is the same PJSIP behind a small
C bridge (`android/app/src/main/cpp`). `android/core` (accounts, vCard, provisioning, dial rules) is pure Kotlin and tested against the same fixtures as iOS.

## Third-party components
PJSIP 2.17 (SIP, media, SRTP, DTLS-SRTP), OpenSSL 3.5 (TLS), Mozilla CA bundle. See the README for licensing.
