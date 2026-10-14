#!/usr/bin/env python3
"""The hostile stage's loopback observers (plan-macos-v1 WI-4), adapted from spike 3's: one process, three roles, each
event a JSON line:

- **TCP connection counter**: every accepted connection on a case's port (`tcp-accept`), and whether anything was
  sent before the idle timeout (`tcp-idle`: a bare connection, which is what a preconnect is).
- **HTTP canary**: a request line parsed from what a connection sent (`http`), answered 200 with a tiny body so a
  baseline page sees its load succeed; WebSocket upgrades are recorded and refused.
- **UDP receiver**: every datagram on a case's port (`udp`), classified as STUN (magic cookie) or QUIC (long header).

    python3 -I observe.py --cases cases.json --log events.jsonl --ready ready.flag

Binds 127.0.0.1 only. Exits non-zero if any port cannot be bound: an observer that is not listening counts nothing,
and that must not look like zero.
"""
import argparse
import asyncio
import base64
import json
import resource
import signal
import sys
import time

PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")
TYPES = {".png": ("image/png", PNG), ".js": ("text/javascript", b"/* canary */"), ".css": ("text/css", b"/**/"),
         ".html": ("text/html", b"<p>canary</p>"), ".svg": ("image/svg+xml", b'<svg xmlns="http://www.w3.org/2000/svg"/>'),
         ".json": ("application/json", b"{}"), ".vtt": ("text/vtt", b"WEBVTT\n")}


class Log:
    def __init__(self, path: str):
        self.f = open(path, "a", encoding="utf-8", buffering=1)

    def __call__(self, **event):
        event["t"] = round(time.time(), 3)
        self.f.write(json.dumps(event, sort_keys=True) + "\n")


def classify_udp(data: bytes) -> str:
    if len(data) >= 20 and data[4:8] == b"\x21\x12\xa4\x42":
        return "stun"
    if data and data[0] & 0xC0 == 0xC0:
        return "quic-long-header"
    return "other"


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--idle", type=float, default=4.0)
    a = ap.parse_args()
    battery = json.load(open(a.cases, encoding="utf-8"))
    log = Log(a.log)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(4096, hard), hard))

    control = battery["control"]
    tcp_ports = {c["tcp"]: c["id"] for c in battery["cases"]}
    tcp_ports[battery["reader"]["tcp"]] = "reader"
    tcp_ports[control["http"]] = "@control-http"
    tcp_ports[control["tcp"]] = "@control-tcp"
    udp_ports = {c["udp"]: c["id"] for c in battery["cases"]}
    udp_ports[battery["reader"]["udp"]] = "reader"
    udp_ports[control["udp"]] = "@control-udp"

    async def on_tcp(reader: asyncio.StreamReader, writer: asyncio.StreamWriter, port: int):
        peer = writer.get_extra_info("peername")
        log(kind="tcp-accept", port=port, case=tcp_ports.get(port), peer=str(peer))
        data = b""
        try:
            while b"\r\n\r\n" not in data and len(data) < 65536:
                chunk = await asyncio.wait_for(reader.read(4096), timeout=a.idle)
                if not chunk:
                    break
                data += chunk
        except asyncio.TimeoutError:
            pass
        except ConnectionError:
            pass
        if not data:
            log(kind="tcp-idle", port=port, case=tcp_ports.get(port))
            writer.close()
            return
        head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1", "replace")
        lines = head.split("\r\n")
        first = lines[0][:300]
        parts = first.split(" ")
        is_http = len(parts) == 3 and parts[2].startswith("HTTP/")
        headers = {}
        for line in lines[1:]:
            k, _, v = line.partition(":")
            if k.strip().lower() in ("upgrade", "purpose", "sec-purpose", "content-type", "ping-to", "ping-from",
                                     "referer", "origin", "host", "user-agent", "sec-fetch-dest", "sec-fetch-mode"):
                headers[k.strip().lower()] = v.strip()[:200]
        if is_http:
            log(kind="http", port=port, case=tcp_ports.get(port), method=parts[0], path=parts[1][:300],
                headers=headers)
            if "upgrade" in headers:
                writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            else:
                path = parts[1].split("?", 1)[0]
                ext = path[path.rfind("."):] if "." in path.rsplit("/", 1)[-1] else ""
                ctype, body = TYPES.get(ext, ("text/plain", b"canary"))
                if path.endswith("/es"):
                    ctype, body = "text/event-stream", b"data: canary\n\n"
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: " + ctype.encode() +
                             b"\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: " + str(len(body)).encode() +
                             b"\r\nConnection: close\r\n\r\n" + body)
        else:
            log(kind="tcp-data", port=port, case=tcp_ports.get(port), bytes=len(data), head=data[:24].hex())
        try:
            await writer.drain()
        except ConnectionError:
            pass
        writer.close()

    class Udp(asyncio.DatagramProtocol):
        def __init__(self, port: int):
            self.port = port

        def datagram_received(self, data, addr):
            log(kind="udp", port=self.port, case=udp_ports.get(self.port), bytes=len(data),
                proto=classify_udp(data), head=data[:24].hex(), peer=str(addr))

    loop = asyncio.get_running_loop()
    servers = []
    try:
        for port in sorted(tcp_ports):
            servers.append(await asyncio.start_server(
                lambda r, w, p=port: on_tcp(r, w, p), "127.0.0.1", port, reuse_address=True))
        for port in sorted(udp_ports):
            await loop.create_datagram_endpoint(lambda p=port: Udp(p), local_addr=("127.0.0.1", port))
    except OSError as e:
        print(f"observe: cannot bind: {e}", file=sys.stderr)
        return 2
    log(kind="ready", tcp=len(tcp_ports), udp=len(udp_ports))
    with open(a.ready, "w") as f:
        f.write("ready\n")
    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    log(kind="stopped")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
