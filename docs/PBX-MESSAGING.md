# SIP text messaging on Asterisk / FreePBX (draft)

Status: **draft; nothing here has been applied anywhere.** L1ne's Chats tab (and Linphone) send SIP `MESSAGE`. A stock Asterisk has the
messaging module loaded but no endpoint has a `message_context` and there is no messages dialplan, so a `MESSAGE` is refused.

## 1. Endpoint setting
Add `message_context=messages` to each endpoint that should be able to text. On FreePBX put it in `/etc/asterisk/pjsip_custom_post.conf`
(not a file that other tooling regenerates):

```
[7100](+type=endpoint)
message_context=messages
```

Start with one test extension, then add the others. Desk phones that cannot text can be left out.

## 2. Dialplan
In `/etc/asterisk/extensions_custom.conf` (adjust the pattern to your numbering):

```
[messages]
; internal extensions only; nothing is sent to outside numbers
exten => _7XXX,1,NoOp(SIP MESSAGE to ${EXTEN})
 same => n,MessageSend(pjsip:${EXTEN},${MESSAGE(from)})
 same => n,Hangup()
; everything else is dropped
exten => _.,1,NoOp(SIP MESSAGE refused for ${EXTEN})
 same => n,Hangup()
```

Verify when applying: the sender must be pinned to the authenticated endpoint so a phone cannot claim to be someone else in `From`.
Test by sending with a forged `From` and checking what the recipient sees.

## 3. Apply and roll back
- Apply when no calls are active: `asterisk -rx "module reload res_pjsip.so"` and `asterisk -rx "dialplan reload"` (or `fwconsole reload`).
- Back up both files first. To roll back, delete the two blocks and reload.

## 4. Test plan
1. Two registered clients: text both ways.
2. Text an extension that is not registered: expect a failure on the sender (404/480). Asterisk does not store messages.
3. Text a number that is not an extension: expect refusal.
4. `asterisk -rx "pjsip show endpoint 7100" | grep message_context` shows `messages`.

## 5. Limits
- **No store-and-forward.** A message to a phone that is not registered at that moment is lost. Fixing that needs push (see the roadmap).
- **Not end-to-end encrypted.** TLS protects each hop to the server; the server itself sees plain text.
- Linphone-only features (group chat, E2EE, file sharing) are provided by Linphone's own servers and are not available this way.
