#!/usr/bin/env python3
"""Turbo browsing: a local HTTPS proxy that spreads Chrome's sites over every line.

Chrome (through the DualDL extension's PAC script) sends HTTPS connections here as
CONNECT tunnels. Each site goes out through one line and stays there, so its
cookies and logins always see the same IP; related domains of one company
(YouTube + googlevideo, Facebook + fbcdn…) share a line for the same reason. New
sites go to the fastest line until it is really busy; only then does the other line
take new sites, so Turbo adds speed when one line is full and never makes a site
slower. Line speeds are probed at start and learned from traffic. A line that
fails is skipped for 30 s.

Listens on 127.0.0.1 only. Prints a JSON stats line every second.

    python3 turbo.py --port 51978 -i en0,en1
"""
import argparse
import asyncio
import ipaddress
import json
import os
import socket
import ssl
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dualdl  # noqa: E402

IP_BOUND_IF, IPV6_BOUND_IF = 25, 125
STICKY = 10 * 60          # a site keeps its line this long after its last connection
DOWN_FOR = 30             # a line that couldn't connect is skipped this long
CONNECT_TIMEOUT = 8
FAMILIES = {               # one company, one line: logins and IP-tied video links stay valid
    "google": ["google.com", "youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "gstatic.com",
               "googleapis.com", "googleusercontent.com", "youtu.be", "youtube-nocookie.com",
               "googlesyndication.com", "doubleclick.net", "gmail.com", "google.com.bd"],
    "meta": ["facebook.com", "fbcdn.net", "fb.com", "fb.watch", "instagram.com", "cdninstagram.com",
             "messenger.com", "whatsapp.com", "whatsapp.net", "threads.net"],
    "microsoft": ["microsoft.com", "live.com", "office.com", "microsoftonline.com", "bing.com", "msn.com",
                  "outlook.com", "sharepoint.com", "skype.com"],
    "apple": ["apple.com", "icloud.com", "mzstatic.com", "apple-cloudkit.com", "cdn-apple.com"],
    "x": ["x.com", "twitter.com", "twimg.com", "t.co"],
    "tiktok": ["tiktok.com", "tiktokcdn.com", "tiktokv.com", "byteoversea.com", "ibytedtos.com"],
    "netflix": ["netflix.com", "nflxvideo.net", "nflximg.net", "nflxext.com", "nflxso.net"],
    "amazon": ["amazon.com", "primevideo.com", "media-amazon.com", "ssl-images-amazon.com"],
}
FAMILY_OF = {d: name for name, ds in FAMILIES.items() for d in ds}
HEAVY = {"google", "meta", "netflix", "tiktok", "amazon"}      # video sites: always the fastest line
PROBE_HOST, PROBE_PATH = "speed.cloudflare.com", "/__down?bytes=2000000"
FLOOR = 128 * 1024        # never assume a working line is slower than this (bytes/s)
SECOND_LEVEL = {"co", "com", "net", "org", "gov", "ac", "edu"}


def site_of(host):
    """The group a host belongs to: its company family, or its registrable domain."""
    host = host.lower().rstrip(".")
    labels = host.split(".")
    for i in range(len(labels) - 1):
        if ".".join(labels[i:]) in FAMILY_OF:
            return FAMILY_OF[".".join(labels[i:])]
    if len(labels) >= 3 and labels[-2] in SECOND_LEVEL and len(labels[-1]) == 2:
        return ".".join(labels[-3:])          # example.com.bd, example.co.uk
    return ".".join(labels[-2:])


class Lines:
    def __init__(self, ifaces):
        self.ifaces = ifaces
        self.index = {i: socket.if_nametoindex(i) for i in ifaces}
        self.active = {i: 0 for i in ifaces}
        self.bytes = {i: 0 for i in ifaces}
        self.rate = {i: 0.0 for i in ifaces}      # recent download speed, bytes/s
        self.down_until = {i: 0.0 for i in ifaces}
        self.sites = {}                           # site -> [line, last used]
        self.given = {i: 0 for i in ifaces}       # sites handed to each line, to alternate on ties
        self.capacity = {i: float(1 << 20) for i in ifaces}   # bytes/s each line can do (probed, then learned)
        self.probed = {i: 0.0 for i in ifaces}
        self._last = dict(self.bytes)

    def pick(self, site, exclude=()):
        now = time.time()
        known = self.sites.get(site)
        if known and known[0] not in exclude and self.down_until[known[0]] < now:
            known[1] = now
            return known[0]
        ok = [i for i in self.ifaces if i not in exclude and self.down_until[i] < now]
        ok = ok or [i for i in self.ifaces if i not in exclude] or self.ifaces
        fastest = sorted(ok, key=lambda i: (-self.capacity[i], self.given[i]))
        if site in HEAVY:
            line = fastest[0]
        else:
            # The fastest line takes every site until it's really busy (80% of what it has shown
            # it can do); only then does the next line add its speed. A slow line never slows a
            # site down while the fast one still has room.
            line = next((i for i in fastest if self.rate[i] < 0.8 * self.capacity[i]), None)
            if line is None:
                line = max(ok, key=lambda i: (max(self.capacity[i] - self.rate[i], FLOOR / 8)
                                              / (self.active[i] + 1), -self.given[i]))
        self.given[line] += 1
        self.sites[site] = [line, now]
        return line

    def tick(self):
        now = time.time()
        for i in self.ifaces:
            delta = self.bytes[i] - self._last[i]
            self.rate[i] = 0.6 * self.rate[i] + 0.4 * delta     # smoothed, per second
            self._last[i] = self.bytes[i]
            # learn from real traffic: the estimate rises with what we see, and slowly settles
            # back toward the last measurement (half-life about two minutes)
            settle = max(self.probed[i], FLOOR)
            self.capacity[i] = max(self.rate[i], settle + (self.capacity[i] - settle) * 0.994, FLOOR)
        for site, (line, used) in list(self.sites.items()):
            if now - used > STICKY and self.active[line] == 0:
                del self.sites[site]


async def connect_via(host, port, line, lines):
    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    infos.sort(key=lambda a: a[0] != socket.AF_INET)       # IPv4 first: every line has it
    last = OSError("no address")
    for fam, typ, proto, _, addr in infos:
        s = socket.socket(fam, typ, proto)
        s.setblocking(False)
        try:
            if fam == socket.AF_INET:
                s.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, lines.index[line])
            else:
                s.setsockopt(socket.IPPROTO_IPV6, IPV6_BOUND_IF, lines.index[line])
            await asyncio.wait_for(loop.sock_connect(s, addr), CONNECT_TIMEOUT)
            return await asyncio.open_connection(sock=s)
        except (OSError, asyncio.TimeoutError) as e:
            s.close()
            last = e
    raise last


def is_private(host):
    try:
        ip = ipaddress.ip_address(host.strip("[]"))
        return ip.is_private or ip.is_loopback or ip.is_link_local
    except ValueError:
        return host in ("localhost",) or host.endswith(".local")


async def pipe(reader, writer, count=None):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            if count:
                count(len(data))
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


async def handle(reader, writer, lines, allow_local):
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, OSError):
        writer.close()
        return
    parts = head.split(b"\r\n", 1)[0].decode("latin-1").split()
    if len(parts) < 2 or parts[0].upper() != "CONNECT":
        writer.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
        writer.close()
        return
    host, _, port = parts[1].rpartition(":")
    host = host.strip("[]")
    if not host or not port.isdigit() or (is_private(host) and not allow_local):
        writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        writer.close()
        return

    site = site_of(host)
    tried, up = [], None
    while len(tried) < len(lines.ifaces):
        line = lines.pick(site, exclude=tried)
        try:
            up = await connect_via(host, int(port), line, lines)
            break
        except (OSError, asyncio.TimeoutError):
            tried.append(line)
            lines.down_until[line] = time.time() + DOWN_FOR
            lines.sites.pop(site, None)
    if up is None:
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        writer.close()
        return

    up_reader, up_writer = up
    writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    lines.active[line] += 1

    def counted(n):
        lines.bytes[line] += n

    try:
        await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer, counted))
    finally:
        lines.active[line] -= 1


async def probe_line(line, lines):
    """Speed of one line: a 2 MB download from Cloudflare through that line only."""
    loop = asyncio.get_running_loop()
    addr = (await loop.getaddrinfo(PROBE_HOST, 443, family=socket.AF_INET, type=socket.SOCK_STREAM))[0][4]
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setblocking(False)
    s.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, lines.index[line])
    try:
        await asyncio.wait_for(loop.sock_connect(s, addr), CONNECT_TIMEOUT)
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(sock=s, ssl=ssl.create_default_context(), server_hostname=PROBE_HOST), 10)
    except Exception:
        s.close()
        raise
    writer.write(("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n"
                  % (PROBE_PATH, PROBE_HOST)).encode())
    await writer.drain()
    await reader.readuntil(b"\r\n\r\n")
    got, t0 = 0, time.time()
    while True:
        data = await asyncio.wait_for(reader.read(65536), 10)
        if not data:
            break
        got += len(data)
    writer.close()
    return got / max(time.time() - t0, 0.05)


async def probe_all(lines):
    async def one(i):
        try:
            speed = await asyncio.wait_for(probe_line(i, lines), 20)
            lines.probed[i] = speed
            lines.capacity[i] = max(speed, FLOOR)
        except Exception:
            lines.down_until[i] = time.time() + DOWN_FOR
    await asyncio.gather(*(one(i) for i in lines.ifaces))
    dualdl.emit("probe", speeds={i: int(lines.capacity[i]) for i in lines.ifaces})


async def keep_probing(lines):
    """Re-measure every 30 minutes, but only while browsing is busy enough that 2 MB doesn't matter."""
    while True:
        await asyncio.sleep(30 * 60)
        if sum(lines.bytes.values()) - getattr(lines, "_at_probe", 0) > 50 << 20:
            await probe_all(lines)
        lines._at_probe = sum(lines.bytes.values())


async def stats(lines):
    parent = os.getppid()
    while True:
        await asyncio.sleep(1)
        if os.getppid() != parent:
            os._exit(0)              # the app went away: free the port
        lines.tick()
        dualdl.emit("stats", lines={i: {"active": lines.active[i], "rate": int(lines.rate[i]),
                                        "capacity": int(lines.capacity[i])} for i in lines.ifaces},
                    sites=len(lines.sites))


async def main():
    ap = argparse.ArgumentParser(description="Turbo browsing proxy (HTTPS CONNECT over every line)")
    ap.add_argument("--port", type=int, default=51978)
    ap.add_argument("-i", "--interfaces", help="lines to use, e.g. en0,en1 (default: all active)")
    ap.add_argument("--allow-local", action="store_true", help="tests only: allow private targets")
    ap.add_argument("--no-probe", action="store_true", help="don't measure line speeds (tests)")
    args = ap.parse_args()
    dualdl.JSON_MODE = True
    ifaces = args.interfaces.split(",") if args.interfaces else dualdl.active_interfaces()
    if not ifaces:
        dualdl.emit("error", message="No active network line")
        sys.exit(1)
    lines = Lines(ifaces)
    try:
        server = await asyncio.start_server(lambda r, w: handle(r, w, lines, args.allow_local),
                                            "127.0.0.1", args.port, limit=16384)
    except OSError as e:
        dualdl.emit("error", message="Port %d is busy (%s)" % (args.port, e))
        sys.exit(1)
    dualdl.emit("ready", port=args.port, lines=ifaces)
    loop = asyncio.get_running_loop()
    loop.create_task(stats(lines))
    if len(ifaces) > 1 and not args.no_probe:
        loop.create_task(probe_all(lines))
        loop.create_task(keep_probing(lines))
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
