# Push design (draft)

Status: design only, nothing built yet. Written so the data rules are fixed before any code exists.

## The problem

iOS suspends a backgrounded app. A suspended app cannot renew its SIP registration, so the PBX drops it at its expiry
(1 hour with the default 3600 s; observed with Linphone too). The only supported way to wake an iPhone for a call is an
Apple VoIP push (PushKit), and only the holder of the app's APNs key can send one. Android can use FCM the same way,
or keep using the foreground service.

## Per-account push mode

Chosen when an account is added, changeable in the account editor. Default is **No push**.

| Mode | PBX setup | What LiveNet stores | Who holds the SIP login |
|---|---|---|---|
| 1. No push | none | nothing | the phone only |
| 2. Webhook push | one snippet for the PBX admin | push token + hashed webhook secret | the phone only |
| 3. Self-hosted proxy | run the proxy | nothing but the token (relay) | the user's own proxy |
| ~~4. Hosted registration proxy~~ | none | the SIP login and call signalling | **Decided against, see below** |

Mode 1 says plainly in the app that calls will not arrive while L1ne is closed or suspended.

## Wake sequence (modes 2 to 4)

1. A call arrives for the user's extension.
2. The PBX (mode 2) or the user's own proxy (mode 3) calls the relay with the push ID.
3. The relay sends an APNs VoIP push. It carries a call ID only; names and numbers are looked up by the app
   when the INVITE arrives, so neither the relay nor Apple sees them.
4. The app must report an incoming call to CallKit straight away (Apple requirement), then re-registers.
5. The INVITE is delivered and matched to the CallKit call by call ID. If the caller hangs up first, the app ends it.

For mode 2 on Asterisk and FreePBX the dialplan snippet fires the webhook, then holds the call for up to about
15 s until the contact re-registers, because Asterisk fails a dial instantly when the contact has expired.

## Data rules for the relay (modes 2 to 4)

- Stored: push ID, device push token, hash of the webhook secret, creation date, last-seen date. Nothing else.
- Never stored: SIP accounts, passwords, PBX addresses, extensions, phone numbers, names, contacts, call history.
- Caller information is never forwarded; the push carries a call ID only.
- No request logs, no IP logging, no analytics. Errors log an event type only, never an ID, token or IP.
  Web servers and reverse proxies in front must be configured the same way (they log IPs by default).
- Tokens that Apple reports invalid are deleted at once; devices unseen for about 60 days are purged.
- "Remove this device" in the app deletes the record immediately. There is no account, email or login.
- Open source and self-hostable.

## Mode 4: decided against

A hosted proxy that keeps registrations alive for sleeping phones must hold each user's SIP credentials and sees call
signalling (the Zoiper/Groundwire model). LiveNet will not run one: it would make the project a custodian of other
people's logins, with the breach, deletion and privacy-law obligations that come with that, and the project cannot take
those on. Anyone who wants zero PBX setup can run the proxy themselves (mode 3), where they hold their own credentials
and LiveNet holds none. Revisit only if that changes. The App Store privacy label stays "Data Not Collected".

## Apple requirements that shape the build

- `aps-environment` entitlement and the `voip` background mode (already set); skeleton in `project.yml`, commented out
  until the paid team is in place.
- Every VoIP push must be reported to CallKit or iOS will stop delivering them.
- TestFlight external testing needs a privacy policy URL and a review account on a test extension.

## Build order

1. Push-mode choice in account setup (default: No push) and honest status wording.
2. Re-register on foreground and on network change (needs no proxy).
3. Relay, PushKit and CallKit wake-up, webhook mode, FreePBX/Asterisk snippet.
4. Self-hosted proxy.
5. Android FCM.
