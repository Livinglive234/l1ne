#!/usr/bin/env python3
"""A tiny SIP-over-TLS server for testing L1ne on this Mac. It accepts REGISTER (no password), answers OPTIONS and
MESSAGE, replies to SUBSCRIBE and then sends a message-waiting NOTIFY, and logs the SDP of every INVITE (then
refuses it with 488). Not a PBX: it exists so TLS, SRTP/DTLS offers, MWI and texting can be seen on the wire.

usage: mock_sip_tls.py <cert.pem> <key.pem> <logfile> [--port 5061] [--message "text"] [--mwi 3]
"""
import asyncio, re, ssl, sys, time, uuid, argparse

ap = argparse.ArgumentParser()
ap.add_argument("cert"); ap.add_argument("key"); ap.add_argument("log")
ap.add_argument("--port", type=int, default=5061)
ap.add_argument("--message"); ap.add_argument("--mwi", type=int, default=3)
args = ap.parse_args()
LOG = open(args.log, "a", buffering=1)
def log(*a): print(time.strftime("%H:%M:%S"), *a, file=LOG, flush=True)

COMPACT = {"v": "via", "f": "from", "t": "to", "i": "call-id", "m": "contact", "l": "content-length", "c": "content-type"}

def split(buf):
    i = buf.find(b"\r\n\r\n")
    if i < 0: return None
    head = buf[:i].decode(errors="replace")
    m = re.search(r"(?im)^(?:content-length|l)\s*:\s*(\d+)", head)
    n = int(m.group(1)) if m else 0
    if len(buf) < i + 4 + n: return None
    return buf[:i + 4 + n].decode(errors="replace"), buf[i + 4 + n:]

def parse(msg):
    head, _, body = msg.partition("\r\n\r\n")
    lines = head.split("\r\n"); hs = {}; vias = []
    for l in lines[1:]:
        if ":" not in l: continue
        k, v = l.split(":", 1); k = COMPACT.get(k.strip().lower(), k.strip().lower()); v = v.strip()
        if k == "via": vias.append(v)
        hs.setdefault(k, v)
    return lines[0], hs, vias, body

def reply(code, reason, hs, vias, extra=(), body="", totag=None):
    to = hs["to"] + (";tag=" + totag if totag and "tag=" not in hs["to"] else "")
    lines = [f"SIP/2.0 {code} {reason}"] + ["Via: " + v for v in vias] + ["From: " + hs["from"], "To: " + to,
             "Call-ID: " + hs["call-id"], "CSeq: " + hs["cseq"]] + list(extra) + [f"Content-Length: {len(body)}"]
    return "\r\n".join(lines) + "\r\n\r\n" + body

def uri_of(header):
    m = re.search(r"<([^>]+)>", header); return m.group(1) if m else header.split(";")[0].strip()

async def handle(reader, writer):
    peer = writer.get_extra_info("peername"); ssl_obj = writer.get_extra_info("ssl_object")
    log(f"TLS connection from {peer}: {ssl_obj.version()} {ssl_obj.cipher()[0]}")
    buf = b""; me = f"sip:mock@127.0.0.1:{args.port};transport=tls"; srvtag = uuid.uuid4().hex[:8]
    contact_of_client = None; first_register = True
    async def send(text): writer.write(text.encode()); await writer.drain()
    try:
        while True:
            data = await reader.read(65536)
            if not data: break
            buf += data
            while (r := split(buf)):
                msg, buf = r
                start, hs, vias, body = parse(msg)
                method = start.split(" ", 1)[0]
                if start.startswith("SIP/2.0"):
                    log("response from client:", start); continue
                log("<-", start)
                if method == "REGISTER":
                    contact_of_client = uri_of(hs.get("contact", ""))
                    exp = hs.get("expires", "3600")
                    await send(reply(200, "OK", hs, vias, [f"Contact: {hs['contact']};expires={exp}" if "expires=" not in hs.get("contact", "") else f"Contact: {hs['contact']}", "Expires: " + exp], totag=srvtag))
                    log("REGISTER ok for", hs["to"], "contact", contact_of_client)
                    if first_register:
                        first_register = False
                        asyncio.create_task(after_register(send, hs, contact_of_client, me, srvtag))
                elif method == "OPTIONS":
                    await send(reply(200, "OK", hs, vias, totag=srvtag))
                elif method == "MESSAGE":
                    log("MESSAGE from app:", hs["from"], "->", start.split()[1], "|", body.strip())
                    await send(reply(200, "OK", hs, vias, totag=srvtag))
                elif method == "SUBSCRIBE":
                    log("SUBSCRIBE", hs.get("event"), "for", start.split()[1])
                    await send(reply(200, "OK", hs, vias, [f"Contact: <{me}>", "Expires: " + hs.get("expires", "3600")], totag=srvtag))
                    notify = (f"NOTIFY {uri_of(hs['contact'])} SIP/2.0\r\nVia: SIP/2.0/TLS 127.0.0.1:{args.port};branch=z9hG4bK-{uuid.uuid4().hex[:10]};rport\r\n"
                              f"Max-Forwards: 70\r\nFrom: {hs['to']};tag={srvtag}\r\nTo: {hs['from']}\r\nCall-ID: {hs['call-id']}\r\nCSeq: 1 NOTIFY\r\n"
                              f"Contact: <{me}>\r\nEvent: message-summary\r\nSubscription-State: active;expires=3600\r\n"
                              f"Content-Type: application/simple-message-summary\r\nContent-Length: ")
                    summary = f"Messages-Waiting: {'yes' if args.mwi else 'no'}\r\nVoice-Message: {args.mwi}/1 (0/0)\r\n"
                    await send(notify + f"{len(summary)}\r\n\r\n" + summary); log("-> NOTIFY message-summary", args.mwi, "new")
                elif method == "INVITE":
                    log("INVITE", start.split()[1], "SDP offered:")
                    for l in body.splitlines():
                        if l.startswith(("m=", "a=crypto", "a=fingerprint", "a=setup", "c=")): log("   ", l)
                    await send(reply(488, "Not Acceptable Here", hs, vias, totag=srvtag))
                elif method == "ACK":
                    pass
                else:
                    await send(reply(200, "OK", hs, vias, totag=srvtag))
    except (ConnectionResetError, ssl.SSLError) as e:
        log("connection ended:", e)
    finally:
        writer.close()

async def after_register(send, hs, client_contact, me, srvtag):
    if not args.message: return
    await asyncio.sleep(2)
    to = hs["to"].split(";")[0]
    text = args.message
    m = (f"MESSAGE {client_contact} SIP/2.0\r\nVia: SIP/2.0/TLS 127.0.0.1:{args.port};branch=z9hG4bK-{uuid.uuid4().hex[:10]};rport\r\nMax-Forwards: 70\r\n"
         f"From: <sip:7201@localhost>;tag={uuid.uuid4().hex[:8]}\r\nTo: {to}\r\nCall-ID: {uuid.uuid4().hex}\r\nCSeq: 1 MESSAGE\r\n"
         f"Content-Type: text/plain\r\nContent-Length: {len(text)}\r\n\r\n{text}")
    await send(m); log("-> MESSAGE to app:", text)

async def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(args.cert, args.key)
    srv = await asyncio.start_server(handle, "127.0.0.1", args.port, ssl=ctx)
    log(f"mock SIP/TLS listening on 127.0.0.1:{args.port}")
    async with srv: await srv.serve_forever()

asyncio.run(main())
