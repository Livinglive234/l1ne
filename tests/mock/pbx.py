#!/usr/bin/env python3
"""A scriptable fake PBX for testing L1ne's real SIP engine without a real server. Plain SIP over TCP and UDP (no TLS, so no
certificates) plus a STUN server, all on one host. What it does depends on who registers or what is dialled, so one running
instance covers every scenario:

  REGISTER   7100 / 7101 / ... any extension: digest login, password "secret" (a wrong password gets 403)
             7104: 404 (unknown extension)   7105: 503 (server down)   7106: never answers
  INVITE     1001 answers (200 OK, SDP: first offered codec, SRTP echoed if offered)   1002: 486 Busy   1003: 183 early media, then 200
             1004: rings (180) forever   1005: 404   1006: 603 Decline   anything else: answered like 1001
             re-INVITE (hold/resume) is answered and logged with its direction; BYE, REFER, INFO, CANCEL, MESSAGE, SUBSCRIBE are answered
  SUBSCRIBE  message-summary: 200, then a NOTIFY with 3 new voicemails
  STUN       UDP binding requests are answered and logged

A tiny HTTP control port lets a test see and steer it:
  GET /log            everything the server saw, one line each
  GET /clear          forget the log
  GET /invite?user=7100          ring the registered phone (an incoming call)
  GET /text?user=7100&text=hi    send the registered phone a text message

usage: pbx.py [--host 0.0.0.0] [--sip-port 5060] [--stun-port 3478] [--http-port 8099]
"""
import argparse, asyncio, hashlib, re, struct, time, uuid
from urllib.parse import urlparse, parse_qs

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="0.0.0.0"); ap.add_argument("--sip-port", type=int, default=5060)
ap.add_argument("--stun-port", type=int, default=3478); ap.add_argument("--http-port", type=int, default=8099)
args = ap.parse_args()

LOG = []
def log(*a):
    LOG.append(" ".join(str(x) for x in a)); print(time.strftime("%H:%M:%S"), *a, flush=True)

PASSWORD = "secret"; REALM = "mockpbx"
COMPACT = {"v": "via", "f": "from", "t": "to", "i": "call-id", "m": "contact", "l": "content-length", "c": "content-type", "k": "supported", "r": "refer-to", "b": "referred-by"}
registered = {}        # user -> (contact uri, send function)
dialogs = {}           # call-id -> dict
TAG = uuid.uuid4().hex[:8]
FIXED_KEY = "WVNfX19zZWNyZXRfa2V5X21vY2tfdGVzdF9rZXk0"        # 30 bytes, for AES_CM_128_HMAC_SHA1_80

def parse(msg):
    head, _, body = msg.partition("\r\n\r\n"); lines = head.split("\r\n"); hs = {}; vias = []
    for l in lines[1:]:
        if ":" not in l: continue
        k, v = l.split(":", 1); k = COMPACT.get(k.strip().lower(), k.strip().lower()); v = v.strip()
        if k == "via": vias.append(v)
        else: hs.setdefault(k, v)
    return lines[0], hs, vias, body

def reply(code, reason, hs, vias, extra=(), body="", ctype=None):
    to = hs["to"] + (";tag=" + TAG if "tag=" not in hs["to"] and code > 100 else "")
    lines = [f"SIP/2.0 {code} {reason}"] + ["Via: " + v for v in vias] + ["From: " + hs["from"], "To: " + to, "Call-ID: " + hs["call-id"], "CSeq: " + hs["cseq"]]
    lines += list(extra)
    if body: lines.append("Content-Type: " + (ctype or "application/sdp"))
    lines.append(f"Content-Length: {len(body.encode())}")
    return "\r\n".join(lines) + "\r\n\r\n" + body

def uri_of(h):
    m = re.search(r"<([^>]+)>", h); return m.group(1) if m else h.split(";")[0].strip()
def user_of(uri):
    m = re.search(r"sips?:([^@;>]+)", uri); return m.group(1) if m else ""
def contact(host, proto="tcp"): return f"Contact: <sip:pbx@{host}:{args.sip_port};transport={proto}>"

def sdp_answer(offer, host, direction=None, hold_of=None):
    m = re.search(r"^m=audio (\d+) (\S+) (.*)$", offer, re.M)
    proto = m.group(2) if m else "RTP/AVP"; fmts = m.group(3).split() if m else ["0"]
    fmt = fmts[0]; rtpmap = re.search(rf"^a=rtpmap:{fmt} (\S+)", offer, re.M)
    if fmt == "101" and len(fmts) > 1: fmt = fmts[1]; rtpmap = re.search(rf"^a=rtpmap:{fmt} (\S+)", offer, re.M)
    d = "sendrecv"
    if re.search(r"^a=sendonly", offer, re.M): d = "recvonly"
    elif re.search(r"^a=inactive", offer, re.M): d = "inactive"
    s = f"v=0\r\no=- 1 1 IN IP4 {host}\r\ns=mock\r\nc=IN IP4 {host}\r\nt=0 0\r\nm=audio 40000 {proto} {fmt}\r\n"
    if rtpmap: s += f"a=rtpmap:{fmt} {rtpmap.group(1)}\r\n"
    c = re.search(r"^a=crypto:(\d+) (\S+) inline", offer, re.M)
    if "SAVP" in proto and c: s += f"a=crypto:{c.group(1)} {c.group(2)} inline:{FIXED_KEY}\r\n"
    return s + f"a={d}\r\n"

def media_summary(body):
    out = []
    for l in body.splitlines():
        if l.startswith("m=") or l.startswith("a=rtpmap") or l.startswith("a=crypto") or l.startswith("a=fingerprint") or l.startswith("a=candidate") or l.startswith("a=ice") or l in ("a=sendonly", "a=recvonly", "a=inactive", "a=sendrecv"):
            out.append(re.sub(r"inline:\S+", "inline:<key>", l))
    return " | ".join(out)

def digest_ok(auth, method, user):
    f = dict(re.findall(r'(\w+)="?([^",]*)"?', auth))
    ha1 = hashlib.md5(f"{user}:{REALM}:{PASSWORD}".encode()).hexdigest(); ha2 = hashlib.md5(f"{method}:{f.get('uri','')}".encode()).hexdigest()
    if f.get("qop"): want = hashlib.md5(f"{ha1}:{f.get('nonce')}:{f.get('nc')}:{f.get('cnonce')}:{f['qop']}:{ha2}".encode()).hexdigest()
    else: want = hashlib.md5(f"{ha1}:{f.get('nonce')}:{ha2}".encode()).hexdigest()
    return f.get("response") == want

async def process(text, send, host, proto, peer):
    """Handles one SIP message; send(text) writes to the same peer."""
    start, hs, vias, body = parse(text)
    if start.startswith("SIP/2.0"):
        log("response from phone:", start);
        if "INVITE" in hs.get("cseq", "") and start.split()[1] == "200":
            d = dialogs.get(hs["call-id"])
            if d and d.get("ours"):
                ack = (f"ACK {uri_of(hs.get('contact', d['target']))} SIP/2.0\r\nVia: SIP/2.0/{proto.upper()} {host}:{args.sip_port};branch=z9hG4bK-{uuid.uuid4().hex[:10]}\r\n"
                       f"Max-Forwards: 70\r\nFrom: {d['from']}\r\nTo: {hs['to']}\r\nCall-ID: {hs['call-id']}\r\nCSeq: {hs['cseq'].split()[0]} ACK\r\nContent-Length: 0\r\n\r\n")
                await send(ack); log("-> ACK to phone")
        return
    if len(start.split()) < 2: return           # a bare CRLF keep-alive from the phone, not a request
    method, ruri = start.split()[0], start.split()[1]; cseq = hs.get("cseq", "")
    m_host = re.search(r"sips?:(?:[^@/;>]*@)?([^:;>/]+)", ruri)
    if m_host and re.match(r"[\d.]+$|[A-Za-z]", m_host.group(1)): host = m_host.group(1)       # advertise the address the phone dialled (the socket's own address is 127.0.0.1 behind the emulator's NAT)
    log("<-", method, ruri[:60], f"({proto})")
    if method == "REGISTER":
        user = user_of(hs["to"]); auth = hs.get("authorization")
        if user == "7104": log("REGISTER", user, "-> 404"); await send(reply(404, "Not Found", hs, vias)); return
        if user == "7105": log("REGISTER", user, "-> 503"); await send(reply(503, "Service Unavailable", hs, vias)); return
        if user == "7106": log("REGISTER", user, "-> (no answer)"); return
        if not auth:
            nonce = uuid.uuid4().hex; log("REGISTER", user, "-> 401 challenge")
            await send(reply(401, "Unauthorized", hs, vias, [f'WWW-Authenticate: Digest realm="{REALM}", nonce="{nonce}", algorithm=MD5']))
        elif digest_ok(auth, "REGISTER", user):
            exp = re.search(r"expires=(\d+)", hs.get("contact", "")); e = exp.group(1) if exp else hs.get("expires", "3600")
            registered[user] = (uri_of(hs["contact"]), send, host)
            log("REGISTER", user, "-> 200 OK", f"expires={e}", f"via={proto}"); await send(reply(200, "OK", hs, vias, [f"Contact: {hs['contact']}", "Expires: " + e]))
        else:
            log("REGISTER", user, "-> 403 bad password"); await send(reply(403, "Forbidden", hs, vias))
    elif method == "OPTIONS": await send(reply(200, "OK", hs, vias))
    elif method == "INVITE":
        callee = user_of(ruri); cid = hs["call-id"]; first = cid not in dialogs
        if not first:   # re-INVITE: hold or resume
            offer_dir = next((x for x in ("sendonly", "inactive", "recvonly", "sendrecv") if f"a={x}" in body), "sendrecv")
            log("re-INVITE", f"dir={offer_dir}", "(hold)" if offer_dir in ("sendonly", "inactive") else "(resume)")
            await send(reply(200, "OK", hs, vias, [contact(host, proto)], sdp_answer(body, host))); return
        dialogs[cid] = {"callee": callee, "target": ruri}
        log("INVITE", callee, "|", media_summary(body))
        for l in body.splitlines():
            if l.startswith("c=IN IP4"): log("   offer connection", l)
        await send(reply(100, "Trying", hs, vias))
        if callee == "1002": log("-> 486 Busy"); await send(reply(486, "Busy Here", hs, vias))
        elif callee == "1005": log("-> 404"); await send(reply(404, "Not Found", hs, vias))
        elif callee == "1006": log("-> 603 Decline"); await send(reply(603, "Decline", hs, vias))
        elif callee == "1004": log("-> 180 (ringing forever)"); await send(reply(180, "Ringing", hs, vias, [contact(host, proto)]))
        elif callee == "1003":
            log("-> 183 early media"); await send(reply(183, "Session Progress", hs, vias, [contact(host, proto)], sdp_answer(body, host)))
            await asyncio.sleep(1.2); log("-> 200 OK (after early media)"); await send(reply(200, "OK", hs, vias, [contact(host, proto)], sdp_answer(body, host)))
        else:
            await send(reply(180, "Ringing", hs, vias, [contact(host, proto)])); await asyncio.sleep(0.4)
            log("-> 200 OK"); await send(reply(200, "OK", hs, vias, [contact(host, proto)], sdp_answer(body, host)))
    elif method == "ACK": log("ACK")
    elif method == "BYE": log("BYE"); dialogs.pop(hs["call-id"], None); await send(reply(200, "OK", hs, vias))
    elif method == "CANCEL": log("CANCEL"); await send(reply(200, "OK", hs, vias))
    elif method == "INFO": log("INFO", body.strip().replace("\r\n", " ")); await send(reply(200, "OK", hs, vias))
    elif method == "REFER":
        log("REFER Refer-To:", hs.get("refer-to")); await send(reply(202, "Accepted", hs, vias, [contact(host, proto)]))
        frag = "SIP/2.0 200 OK\r\n"
        await send(f"NOTIFY {uri_of(hs['contact'])} SIP/2.0\r\nVia: SIP/2.0/{proto.upper()} {host}:{args.sip_port};branch=z9hG4bK-{uuid.uuid4().hex[:10]}\r\nMax-Forwards: 70\r\n"
                   f"From: {hs['to']};tag={TAG}\r\nTo: {hs['from']}\r\nCall-ID: {hs['call-id']}\r\nCSeq: 1 NOTIFY\r\nEvent: refer\r\nSubscription-State: terminated;reason=noresource\r\n"
                   f"Content-Type: message/sipfrag\r\nContent-Length: {len(frag)}\r\n\r\n{frag}")
    elif method == "MESSAGE":
        log("MESSAGE from phone:", user_of(hs["from"]), "->", user_of(ruri), "|", body.strip()); await send(reply(200, "OK", hs, vias))
    elif method == "SUBSCRIBE":
        log("SUBSCRIBE", hs.get("event")); await send(reply(200, "OK", hs, vias, [contact(host, proto), "Expires: " + hs.get("expires", "3600")]))
        summary = "Messages-Waiting: yes\r\nVoice-Message: 3/1 (0/0)\r\n"
        await asyncio.sleep(0.3)
        await send(f"NOTIFY {uri_of(hs['contact'])} SIP/2.0\r\nVia: SIP/2.0/{proto.upper()} {host}:{args.sip_port};branch=z9hG4bK-{uuid.uuid4().hex[:10]};rport\r\nMax-Forwards: 70\r\n"
                   f"From: {hs['to']};tag={TAG}\r\nTo: {hs['from']}\r\nCall-ID: {hs['call-id']}\r\nCSeq: 1 NOTIFY\r\n{contact(host, proto)}\r\nEvent: message-summary\r\nSubscription-State: active;expires=3600\r\n"
                   f"Content-Type: application/simple-message-summary\r\nContent-Length: {len(summary)}\r\n\r\n{summary}")
        log("-> NOTIFY message-summary 3 new")
    else: await send(reply(200, "OK", hs, vias))

# ---------- transports ----------
async def tcp_client(reader, writer):
    peer = writer.get_extra_info("peername"); host = writer.get_extra_info("sockname")[0]; buf = b""
    async def send(t): writer.write(t.encode()); await writer.drain()
    try:
        while True:
            data = await reader.read(65536)
            if not data: break
            buf += data
            while True:
                i = buf.find(b"\r\n\r\n")
                if i < 0: break
                m = re.search(rb"(?im)^(?:content-length|l)\s*:\s*(\d+)", buf[:i]); n = int(m.group(1)) if m else 0
                if len(buf) < i + 4 + n: break
                msg, buf = buf[:i + 4 + n].decode(errors="replace"), buf[i + 4 + n:]
                asyncio.create_task(process(msg, send, host, "tcp", peer))
    except ConnectionError: pass
    finally: writer.close()

class UdpSip(asyncio.DatagramProtocol):
    def connection_made(self, t): self.t = t
    def datagram_received(self, data, addr):
        text = data.decode(errors="replace")
        if not text.strip(): return
        async def send(s): self.t.sendto(s.encode(), addr)
        asyncio.create_task(process(text, send, self.t.get_extra_info("sockname")[0] if False else (addr[0] and local_ip_for(addr[0])), "udp", addr))

def local_ip_for(remote):
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try: s.connect((remote, 9)); return s.getsockname()[0]
    finally: s.close()

class Stun(asyncio.DatagramProtocol):
    def connection_made(self, t): self.t = t
    def datagram_received(self, data, addr):
        if len(data) < 20: return
        mtype, mlen, cookie = struct.unpack("!HHI", data[:8]); txid = data[8:20]
        if mtype != 0x0001: return
        log("STUN binding request from", addr[0]); port = addr[1] ^ (cookie >> 16)
        ip = struct.unpack("!I", bytes(int(x) for x in addr[0].split(".")))[0] ^ cookie
        attr = struct.pack("!HHBBHI", 0x0020, 8, 0, 1, port, ip)
        self.t.sendto(struct.pack("!HHI", 0x0101, len(attr), cookie) + txid + attr, addr)

# ---------- control (HTTP) ----------
async def http(reader, writer):
    line = (await reader.readline()).decode();
    while (await reader.readline()).strip(): pass
    u = urlparse(line.split()[1]) if line else urlparse("/"); q = {k: v[0] for k, v in parse_qs(u.query).items()}; out = "ok"
    if u.path == "/log": out = "\n".join(LOG) + "\n"
    elif u.path == "/clear": LOG.clear()
    elif u.path == "/invite": out = await invite(q.get("user", "7100"))
    elif u.path == "/text": out = await text(q.get("user", "7100"), q.get("text", "hello"))
    writer.write(f"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {len(out.encode())}\r\n\r\n{out}".encode()); await writer.drain(); writer.close()

async def invite(user):
    if user not in registered: return "not registered"
    target, send, me = registered[user]; cid = uuid.uuid4().hex; frm = f"<sip:7777@mockpbx>;tag={uuid.uuid4().hex[:8]}"
    host = re.search(r"@([^:;>]+)", target).group(1)
    sdp = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=mock\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 40002 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
    dialogs[cid] = {"ours": True, "target": target, "from": frm}
    await send(f"INVITE {target} SIP/2.0\r\nVia: SIP/2.0/TCP {me}:{args.sip_port};branch=z9hG4bK-{uuid.uuid4().hex[:10]}\r\nMax-Forwards: 70\r\nFrom: \"Mock Caller\" {frm}\r\n"
               f"To: <sip:{user}@mockpbx>\r\nCall-ID: {cid}\r\nCSeq: 1 INVITE\r\nContact: <sip:7777@{me}:{args.sip_port};transport=tcp>\r\nContent-Type: application/sdp\r\nContent-Length: {len(sdp)}\r\n\r\n{sdp}")
    log("-> INVITE to phone (incoming call)", user); return "invited"

async def text(user, body):
    if user not in registered: return "not registered"
    target, send, me = registered[user]
    await send(f"MESSAGE {target} SIP/2.0\r\nVia: SIP/2.0/TCP {me}:{args.sip_port};branch=z9hG4bK-{uuid.uuid4().hex[:10]}\r\nMax-Forwards: 70\r\n"
               f"From: <sip:7201@mockpbx>;tag={uuid.uuid4().hex[:8]}\r\nTo: <sip:{user}@mockpbx>\r\nCall-ID: {uuid.uuid4().hex}\r\nCSeq: 1 MESSAGE\r\nContent-Type: text/plain\r\nContent-Length: {len(body)}\r\n\r\n{body}")
    log("-> MESSAGE to phone:", body); return "sent"

async def main():
    loop = asyncio.get_running_loop()
    await asyncio.start_server(tcp_client, args.host, args.sip_port)
    await loop.create_datagram_endpoint(UdpSip, local_addr=(args.host, args.sip_port))
    await loop.create_datagram_endpoint(Stun, local_addr=(args.host, args.stun_port))
    await asyncio.start_server(http, args.host, args.http_port)
    log(f"mock PBX: SIP tcp+udp {args.sip_port}, STUN udp {args.stun_port}, control http {args.http_port}")
    await asyncio.Event().wait()

asyncio.run(main())
