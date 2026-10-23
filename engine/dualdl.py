#!/usr/bin/env python3
"""dualdl - download a file over Ethernet and Wi-Fi at the same time (macOS).

The file is split into small chunks. Every active network interface runs its
own pool of connections and keeps pulling the next missing chunk, so a faster
line naturally takes more of the work. Google Drive share links are supported.
Interrupt with Ctrl-C and run the same command again to resume.

    python3 dualdl.py "https://drive.google.com/file/d/XXXX/view"

With --json every status update is printed as one JSON object per line, which
is how the DualDL app drives this script.
"""
import argparse
import calendar
import fcntl
import http.client
import json
import os
import queue
import re
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, unquote, urlencode, urljoin, urlparse

IP_BOUND_IF = 25            # macOS <netinet/in.h>: pin a socket to one interface
CHUNK = 4 * 1024 * 1024     # bytes per range request
BLOCK = 256 * 1024          # read size inside a chunk
TIMEOUT = 20                # seconds without data before a connection is dropped
STALL_LIMIT = 120           # seconds with no data on any line before trying a fresh link
REFRESH_AT = 6              # error replies in a row before fetching a fresh link (Drive links expire)
MAX_REFRESHES = 4           # fresh links in a row that still don't work before handing back to the app
SKIP_PREFIXES = ("lo", "utun", "bridge", "awdl", "llw", "anpi", "gif", "stf", "ap", "ipsec")
HEADERS = {
    # A fake browser UA gets dropped by bot filters that check the TLS fingerprint
    "User-Agent": "dualdl/1.0",
    "Accept": "*/*",
    "Accept-Encoding": "identity",
}
SSL_CTX = ssl.create_default_context()
JSON_MODE = False


def say(text):
    if not JSON_MODE:
        print(text)


def emit(event, **data):
    if JSON_MODE:
        data["event"] = event
        sys.stdout.write(json.dumps(data) + "\n")
        sys.stdout.flush()


# ---------------------------------------------------------------- interfaces

def hardware_names():
    out = subprocess.run(["networksetup", "-listallhardwareports"],
                         capture_output=True, text=True).stdout
    names, port = {}, None
    for line in out.splitlines():
        if line.startswith("Hardware Port:"):
            port = line.split(":", 1)[1].strip()
        elif line.startswith("Device:") and port:
            names[line.split(":", 1)[1].strip()] = port
    return names


def active_interfaces():
    out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
    found, name, block = [], None, []
    for line in out.splitlines() + ["END:"]:
        if line and not line[0].isspace():
            if name and "status: active" in "\n".join(block) and \
                    re.search(r"inet (?!127\.)", "\n".join(block)):
                found.append(name)
            name, block = line.split(":", 1)[0], []
            if name.startswith(SKIP_PREFIXES):
                name = None
        block.append(line)
    # Wired first, then the rest in ifconfig order
    hw = hardware_names()
    return sorted(found, key=lambda i: 0 if "Ethernet" in hw.get(i, "") else 1)


def bound_socket(host, port, ifname, timeout):
    idx = socket.if_nametoindex(ifname)
    last = OSError("no address for %s" % host)
    for fam, typ, proto, _, addr in socket.getaddrinfo(host, port, socket.AF_INET,
                                                        socket.SOCK_STREAM):
        s = socket.socket(fam, typ, proto)
        try:
            s.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, idx)
            s.settimeout(timeout)
            s.connect(addr)
            return s
        except OSError as e:
            s.close()
            last = e
    raise last


class BoundHTTPConnection(http.client.HTTPConnection):
    def __init__(self, host, port, ifname):
        super().__init__(host, port, timeout=TIMEOUT)
        self.ifname = ifname

    def connect(self):
        self.sock = bound_socket(self.host, self.port, self.ifname, self.timeout)


class BoundHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, port, ifname):
        super().__init__(host, port, timeout=TIMEOUT, context=SSL_CTX)
        self.ifname = ifname

    def connect(self):
        sock = bound_socket(self.host, self.port, self.ifname, self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def open_conn(url, ifname):
    u = urlparse(url)
    if u.scheme == "https":
        return BoundHTTPSConnection(u.hostname, u.port or 443, ifname)
    return BoundHTTPConnection(u.hostname, u.port or 80, ifname)


def path_of(url):
    u = urlparse(url)
    return (u.path or "/") + ("?" + u.query if u.query else "")


def request(url, ifname, headers, jars, timeout=None):
    """GET following redirects. Returns (final_url, conn, response).

    jars maps host -> cookies, so a cookie only ever goes back to the host it
    came from, even when a redirect points somewhere else."""
    for _ in range(10):
        conn = open_conn(url, ifname)
        if timeout:
            conn.timeout = timeout
        jar = jars.setdefault(urlparse(url).hostname, {})
        h = dict(headers)
        if jar:
            h["Cookie"] = "; ".join("%s=%s" % kv for kv in jar.items())
        conn.request("GET", path_of(url), headers=h)
        resp = conn.getresponse()
        for c in resp.msg.get_all("Set-Cookie") or []:
            k, _, v = c.split(";", 1)[0].partition("=")
            jar[k.strip()] = v.strip()
        if resp.status in (301, 302, 303, 307, 308):
            url = urljoin(url, resp.getheader("Location"))
            resp.read()
            conn.close()
            continue
        return url, conn, resp
    raise IOError("too many redirects")


# ---------------------------------------------------------------- google drive

class Fail(SystemExit):
    """A message for the user; retry=True means trying again later may well work."""
    def __init__(self, message, retry=False):
        super().__init__(message)
        self.retry = retry


# ---------------------------------------------------------------- signed links

def link_expiry(url):
    """(expires at, lifetime in seconds or None) for a signed link that stops working on its
    own (Amazon S3, Hetzner and other S3 storage, Google Cloud Storage, CloudFront), else None.
    The server checks the signature when a request starts; a request begun in time keeps going."""
    q = {k.lower(): v[0] for k, v in parse_qs(urlparse(url).query).items()}
    for p in ("x-amz-", "x-goog-"):
        if q.get(p + "date") and q.get(p + "expires", "").isdigit():
            try:
                signed = calendar.timegm(time.strptime(q[p + "date"], "%Y%m%dT%H%M%SZ"))
            except ValueError:
                return None
            return signed + int(q[p + "expires"]), int(q[p + "expires"])
    if q.get("expires", "").isdigit() and len(q["expires"]) >= 9:      # Unix time (S3 v2, CloudFront)
        return int(q["expires"]), None
    return None


def link_expired(url, slack=30):
    exp = link_expiry(url)
    return exp is not None and time.time() >= exp[0] - slack


def expired_message(url):
    exp = link_expiry(url)
    life = " (this site's links only work for %d minutes)" % max(1, exp[1] // 60) if exp and exp[1] else ""
    return ("The download link expired%s. Click Download on the website again: DualDL takes the new "
            "link and carries on from where it stopped." % life)


DRIVE_BASE = os.environ.get("DUALDL_DRIVE_BASE", "https://drive.google.com")   # tests point this at a local server


def is_drive_folder(url):
    return bool(re.search(r"(drive|docs)\.google\.com/(drive/(u/\d+/)?folders/|embeddedfolderview|folderview)", url)
                or (DRIVE_BASE in url and "folders/" in url))


def list_drive_folder(url, cookies=None, _path="", _depth=0, _seen=None):
    """Every file in a shared Drive folder (and its subfolders), read from Drive's
    plain "embedded folder" page; no API key or login needed for public folders.
    Returns (folder name, [{"id", "name", "path"}])."""
    import html as htmllib
    import urllib.request
    m = re.search(r"folders/([\w-]+)", url) or re.search(r"[?&]id=([\w-]+)", url)
    if not m:
        raise Fail("That doesn't look like a Google Drive folder link.")
    fid = m.group(1)
    _seen = _seen if _seen is not None else set()
    if fid in _seen or _depth > 6:
        return "", []
    _seen.add(fid)
    headers = {"User-Agent": "Mozilla/5.0"}
    if cookies:
        headers["Cookie"] = "; ".join("%s=%s" % kv for kv in cookies.items())
    req = urllib.request.Request("%s/embeddedfolderview?id=%s" % (DRIVE_BASE, fid), headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30, context=SSL_CTX) as r:
            page = r.read().decode("utf-8", "replace")
    except Exception as e:
        code = getattr(e, "code", None)
        if code in (401, 403, 404):
            raise Fail("Drive won't show this folder. Share it as 'Anyone with the link', or send it from "
                       "Chrome with the DualDL extension (it brings your login).")
        raise Fail("Couldn't read the Drive folder (%s)." % e, retry=True)
    title = re.search(r"<title>(.*?)</title>", page, re.S)
    name = htmllib.unescape(title.group(1)).strip() if title else "Drive folder"
    files = []
    for eid, href, entry in re.findall(r'<div class="flip-entry" id="entry-([\w-]+)".*?<a href="([^"]+)"'
                                       r'.*?<div class="flip-entry-title">(.*?)</div>', page, re.S):
        entry = htmllib.unescape(entry).strip().replace("/", "_") or eid
        if "/folders/" in href:
            sub_name, sub_files = list_drive_folder(href, cookies, os.path.join(_path, entry), _depth + 1, _seen)
            files += sub_files
        else:
            files.append({"id": eid, "name": entry, "path": _path, "url": "%s/file/d/%s/view" % (DRIVE_BASE, eid)})
    return name, files


def drive_url(url):
    if not re.search(r"(drive|docs|drive\.usercontent)\.google\.com", url):
        return url
    m = re.search(r"/file/d/([\w-]+)", url) or re.search(r"[?&]id=([\w-]+)", url)
    if not m:
        return url
    out = "https://drive.usercontent.google.com/download?id=%s&export=download&confirm=t" % m.group(1)
    user = re.search(r"[?&]authuser=(\d+)", url)     # which signed-in Google account
    return out + ("&authuser=" + user.group(1) if user else "")


def drive_confirm_url(html):
    form = re.search(r'<form[^>]*id="download-form"[^>]*>', html)
    if not form:
        return None
    action = re.search(r'action="([^"]+)"', form.group(0)).group(1).replace("&amp;", "&")
    params = {}
    for tag in re.findall(r"<input[^>]*>", html):
        if 'type="hidden"' in tag:
            n = re.search(r'name="([^"]+)"', tag)
            v = re.search(r'value="([^"]*)"', tag)
            if n:
                params[n.group(1)] = v.group(1) if v else ""
    return action + "?" + urlencode(params)


# ---------------------------------------------------------------- probing

def filename_from(resp, url):
    cd = resp.getheader("Content-Disposition") or ""
    m = re.search(r"filename\*=UTF-8''([^;]+)", cd, re.I)
    name = unquote(m.group(1)) if m else None
    if not name:
        m = re.search(r'filename="?([^";]+)"?', cd, re.I)
        name = m.group(1) if m else None
    if not name:
        name = unquote(urlparse(url).path.rsplit("/", 1)[-1]) or "download"
    return name.replace("/", "_").strip() or "download"


def probe(url, ifaces, cookies):
    """Find the real file URL, its size, name and whether ranges work."""
    is_drive = url != drive_url(url) or "google.com" in url
    url = drive_url(url)
    jars = {urlparse(url).hostname: cookies}
    busy = 0                                  # "slow down" answers so far
    confirms = 0
    while confirms < 3:
        resp = conn = None
        for ifname in ifaces:
            try:
                # Short timeout here: if one line hangs, fall through to the next quickly.
                final, conn, resp = request(url, ifname, dict(HEADERS, Range="bytes=0-0"), jars,
                                            timeout=8)
                break
            except OSError as e:
                say("  can't connect through %s (%s)" % (ifname, e))
                emit("log", message="Can't connect through %s (%s)" % (ifname, e))
        if resp is None:
            raise Fail("No line can reach this link right now.", retry=True)
        ctype = resp.getheader("Content-Type", "")
        if is_drive and "text/html" in ctype:
            page = resp.read(2_000_000).decode("utf-8", "replace")
            conn.close()
            nxt = drive_confirm_url(page)
            if not nxt:
                low = page.lower()
                if "quota" in low or "too many users" in low:
                    raise Fail("Google Drive's download limit for this file is used up for now (too many "
                               "downloads). It resets within 24 hours and DualDL keeps trying. Faster: open "
                               "the file in Drive, choose Make a copy, and download your copy.", retry=True)
                if "accounts.google.com" in final or "servicelogin" in low or "sign in" in low:
                    raise Fail("This Drive file is private. Share it as 'Anyone with the link', or send it "
                               "from Chrome with the DualDL extension (it brings your login).")
                raise Fail("Google Drive didn't hand over this file. Check that it's shared as 'Anyone "
                           "with the link'.", retry=True)
            url = nxt
            confirms += 1
            continue
        if resp.status == 206:
            cr = resp.getheader("Content-Range", "")
            size = int(cr.rsplit("/", 1)[1]) if "/" in cr and not cr.endswith("*") else None
            resp.read()
            conn.close()
            return dict(url=final, size=size, ranges=size is not None,
                        name=filename_from(resp, final), cookies=jars, conn=None, resp=None)
        if resp.status == 200:
            cl = resp.getheader("Content-Length")
            # No range support: hand the open response over for a single stream.
            return dict(url=final, size=int(cl) if cl else None, ranges=False,
                        name=filename_from(resp, final), cookies=jars, conn=conn, resp=resp)
        conn.close()
        if (resp.status in (408, 425, 429) or resp.status >= 500) and busy < 4:
            # A busy server: wait as long as it asks (or 2, 4, 8 s) and ask again.
            wait = resp.getheader("Retry-After") or ""
            time.sleep(min(int(wait), 30) if wait.isdigit() else 2 ** (busy + 1))
            busy += 1
            continue
        if resp.status in (400, 401, 403) and link_expired(url):
            raise Fail(expired_message(url))      # retrying the same link can never work
        raise Fail("The server answered HTTP %d %s." % (resp.status, resp.reason),
                   retry=resp.status in (403, 408, 425, 429) or resp.status >= 500)
    raise Fail("Google Drive kept asking for confirmation; try again in a little while.", retry=True)


# ---------------------------------------------------------------- download

class Job:
    def __init__(self, info, ifaces, per_iface, part, state_path, refresh=None, expires=None):
        self.refresh = refresh            # () -> fresh probe info, when links can expire
        self.expires = expires            # the link we were given stops working then, and no refresh helps
        self.url, self.size = info["url"], info["size"]
        # Per-line URLs for sites that tie a link to the IP that asked for it (YouTube)
        self.urls = info.get("urls") or {}
        self.cookies = info["cookies"].get(urlparse(self.url).hostname, {})
        self.ifaces, self.per_iface = ifaces, per_iface
        self.part, self.state_path = part, state_path
        self.total = (self.size + CHUNK - 1) // CHUNK
        self.done = set()
        if os.path.exists(state_path) and os.path.exists(part):
            try:
                st = json.load(open(state_path))
                if st.get("size") == self.size and st.get("chunk") == CHUNK:
                    self.done = set(st["done"])
            except (ValueError, KeyError):
                pass
        self.fd = os.open(part, os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit("This file is already being downloaded by another DualDL process.")
        os.ftruncate(self.fd, self.size)
        self.pending = queue.Queue()
        for i in range(self.total):
            if i not in self.done:
                self.pending.put(i)
        self.lock = threading.Lock()
        self.last_data = time.time()
        self.http_errors = 0
        self.last_status = None
        self.retry = False                # the error is worth retrying later
        self.refreshes = 0
        self.since_refresh = 0
        self.fails = {i: 0 for i in ifaces}
        self.stop = threading.Event()
        self.error = None
        self.received = {i: 0 for i in ifaces}
        self.completed = sum(self.chunk_len(i) for i in self.done)
        self.resumed = self.completed
        # An expiring link gets no new requests once it's dead, so every connection asks for
        # its whole share up front, in one request, while the link still works.
        workers = len(ifaces) * per_iface
        self.span = -(-self.pending.qsize() // workers) if expires else 1

    def chunk_len(self, idx):
        return min(CHUNK, self.size - idx * CHUNK)

    def link_dead(self):
        return self.expires is not None and time.time() >= self.expires

    def claim(self):
        """The next chunk, plus the ones right after it up to `span`, for one request."""
        run = [self.pending.get(timeout=0.3)]
        while len(run) < self.span:
            try:
                nxt = self.pending.get_nowait()
            except queue.Empty:
                break
            if nxt != run[-1] + 1:
                self.pending.put(nxt)
                break
            run.append(nxt)
        return run

    def save(self):
        with self.lock:
            data = {"size": self.size, "chunk": CHUNK, "done": sorted(self.done)}
        with open(self.state_path, "w") as f:
            json.dump(data, f)

    def finished(self):
        return len(self.done) == self.total

    def worker(self, ifname):
        conn, conn_for, fails = None, None, 0
        while not self.stop.is_set() and not self.finished():
            if self.link_dead():
                break           # a new request can't work; requests already running carry on
            try:
                run = self.claim()
            except queue.Empty:
                continue        # a chunk may still be requeued by another worker
            start = run[0] * CHUNK
            end = run[-1] * CHUNK + self.chunk_len(run[-1]) - 1
            pos = start
            # The link can be swapped for a fresh one while we run (see run()).
            with self.lock:
                url, cookies = self.urls.get(ifname, self.url), dict(self.cookies)
            try:
                origin = urlparse(url)[:2]
                if conn is not None and conn_for != origin:
                    conn.close()
                    conn = None
                if conn is None:
                    conn, conn_for = open_conn(url, ifname), origin
                h = dict(HEADERS, Range="bytes=%d-%d" % (start, end))
                if cookies:
                    h["Cookie"] = "; ".join("%s=%s" % kv for kv in cookies.items())
                conn.request("GET", path_of(url), headers=h)
                resp = conn.getresponse()
                if resp.status != 206:
                    # Never read the body: a server ignoring Range would send the whole file.
                    wait = resp.getheader("Retry-After") or ""
                    with self.lock:
                        self.http_errors += 1
                        self.last_status = resp.status
                    if resp.status in (429, 503) and wait.isdigit():
                        time.sleep(min(int(wait), 120))      # the server said how long to wait
                    raise IOError("HTTP %d" % resp.status)
                for idx in run:
                    chunk_end = idx * CHUNK + self.chunk_len(idx) - 1
                    while pos <= chunk_end:
                        data = resp.read(min(BLOCK, chunk_end - pos + 1))
                        if not data:
                            raise IOError("connection closed early")
                        os.pwrite(self.fd, data, pos)
                        pos += len(data)
                        with self.lock:
                            self.received[ifname] += len(data)
                            self.completed += len(data)
                            self.since_refresh += len(data)
                            self.last_data = time.time()
                            self.http_errors = 0
                            self.fails[ifname] = 0
                        LIMITER.take(len(data))
                    with self.lock:
                        self.done.add(idx)
                fails = 0
            except Exception as e:
                if conn is not None:
                    conn.close()
                    conn = None
                with self.lock:
                    left = [i for i in run if i not in self.done]
                    if left:
                        self.completed -= pos - left[0] * CHUNK     # the unfinished chunk starts over
                    self.fails[ifname] += 1
                for i in left:
                    self.pending.put(i)
                fails += 1
                # A dead line backs off (up to 30 s) and the healthy one takes its chunks;
                # it rejoins on its own once it works again.
                if not self.link_dead():
                    time.sleep(min(2 ** fails, 30))
        if conn is not None:
            conn.close()

    def run(self, labels):
        threads = [threading.Thread(target=self.worker, args=(i,), daemon=True)
                   for i in self.ifaces for _ in range(self.per_iface)]
        for t in threads:
            t.start()
        t0 = last_save = time.time()
        history = []    # (time, {iface: bytes}) for a ~3 s speed window
        try:
            while any(t.is_alive() for t in threads):
                time.sleep(0.5)
                if JSON_MODE and os.getppid() == 1:
                    raise KeyboardInterrupt     # the app went away: save and stop
                now = time.time()
                with self.lock:
                    snap = dict(self.received)
                    completed = self.completed
                history.append((now, snap))
                while len(history) > 2 and now - history[0][0] > 3:
                    history.pop(0)
                t_old, old = history[0]
                dt = max(now - t_old, 0.001)
                speeds = {i: (snap[i] - old[i]) / dt for i in self.ifaces}
                with self.lock:
                    down = [i for i, f in self.fails.items() if f >= 3]
                    stalled = now - self.last_data > STALL_LIMIT
                    refused = self.http_errors >= REFRESH_AT
                    if self.since_refresh > 64 << 20:      # the last fresh link worked for a good while
                        self.refreshes, self.since_refresh = 0, 0
                print_progress(completed, self.size, speeds, labels, snap, down)
                # A fresh copy of an expiring link is just as dead, and stopping would cut off
                # the requests that are still streaming: those run until they finish.
                if (stalled or refused) and not self.error and not self.expires:
                    self.renew(stalled)
                if self.error:
                    break
                if now - last_save > 2:
                    self.save()
                    last_save = now
        except KeyboardInterrupt:
            # Only fully written chunks are in `done`, so saving now is safe; the
            # workers may be stuck in a socket read, so don't wait for them.
            self.stop.set()
            self.save()
            say("\n\nStopped. Run the same command again to carry on where it left off.")
            emit("paused")
            sys.stdout.flush()
            os._exit(130)
        self.save()
        say("")
        return time.time() - t0

    def renew(self, stalled):
        """Expired link, a server that keeps refusing, or no data for a while: fetch a fresh
        link and carry on from where we are. Only after several fresh links in a row fail
        does the download stop, marked as worth retrying later (the app does that)."""
        if self.refresh is None or self.refreshes >= MAX_REFRESHES:
            status = self.last_status
            if status in (403, 429):
                msg = ("The server keeps limiting this download (HTTP %d). Google Drive does this for a while "
                       "after heavy use; DualDL will retry on its own." % status)
            elif stalled:
                msg = "No data on any line for %d seconds; DualDL will retry on its own." % STALL_LIMIT
            else:
                msg = "The server keeps refusing (HTTP %s); DualDL will retry on its own." % status
            self.error, self.retry = msg, True
            self.stop.set()
            return
        self.refreshes += 1
        emit("log", message="Getting a fresh download link (try %d)…" % self.refreshes)
        say("  fresh link (try %d)" % self.refreshes)
        try:
            info = self.refresh()
        except SystemExit as e:
            self.error, self.retry = str(e.code), getattr(e, "retry", True)
            self.stop.set()
            return
        except Exception as e:
            info = None
            emit("log", message="Couldn't get a fresh link: %s" % e)
        if info and info.get("conn"):
            info["conn"].close()
        if info and info.get("size") and info["size"] != self.size:
            self.error, self.retry = "The file changed on the server; start the download again.", False
            self.stop.set()
            return
        with self.lock:
            if info and info.get("ranges"):
                self.url = info["url"]
                self.urls = {}
                self.cookies = info["cookies"].get(urlparse(self.url).hostname, {})
            self.http_errors = 0
            self.last_data = time.time()          # give the fresh link a full window


class Limiter:
    """Shared speed cap for every connection of this download (0 = no cap)."""
    def __init__(self):
        self.rate = 0
        self.lock = threading.Lock()
        self.next = 0.0

    def take(self, n):
        if not self.rate:
            return
        with self.lock:
            now = time.time()
            start = max(self.next, now - 0.5)     # allow a half-second burst
            self.next = start + n / self.rate
            wait = self.next - now
        if wait > 0:
            time.sleep(wait)


LIMITER = Limiter()


def check_line(item):
    """Public IP and ISP of one line, asked through that line only."""
    t0 = time.time()
    item.update(ok=False, public_ip="", isp="", ms=0)
    for url in ("https://ipinfo.io/json", "https://api.ipify.org?format=json"):
        try:
            conn = open_conn(url, item["iface"])
            conn.timeout = 6
            conn.request("GET", path_of(url), headers={"User-Agent": "dualdl/1.0",
                                                       "Accept": "application/json"})
            resp = conn.getresponse()
            body = resp.read()
            conn.close()
            if resp.status != 200:
                continue
            data = json.loads(body.decode("utf-8", "replace"))
            item["public_ip"] = data.get("ip", "")
            item["isp"] = re.sub(r"^AS\d+\s+", "", data.get("org", ""))
            item["ok"] = bool(item["public_ip"])
            break
        except (OSError, ValueError, http.client.HTTPException):
            continue
    item["ms"] = int((time.time() - t0) * 1000)


def check_lines():
    lines = interface_list()
    threads = [threading.Thread(target=check_line, args=(l,)) for l in lines]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    # Two lines with one public IP are the same internet connection: no speed gain.
    seen = {}
    for l in lines:
        l["same_as"] = ""
        if l["ok"]:
            if l["public_ip"] in seen:
                l["same_as"] = seen[l["public_ip"]]
            else:
                seen[l["public_ip"]] = l["iface"]
    return lines


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


# Lets a caller downloading several streams (video + audio) report them as one:
# progress = OFFSET + this stream, out of TOTAL.
PROGRESS_OFFSET = 0
PROGRESS_TOTAL = None
PROGRESS_RECEIVED = {}      # bytes per line from streams that already finished


def print_progress(done, size, speeds, labels, received, down=()):
    if JSON_MODE:
        emit("progress", done=PROGRESS_OFFSET + done, size=PROGRESS_TOTAL or size,
             speeds={i: int(s) for i, s in speeds.items()},
             received={i: PROGRESS_RECEIVED.get(i, 0) + received.get(i, 0)
                       for i in set(received) | set(PROGRESS_RECEIVED)},
             down=list(down))
        return
    total_speed = sum(speeds.values())
    pct = done * 100.0 / size if size else 0
    bar = "#" * int(pct / 5) + "." * (20 - int(pct / 5))
    eta = (size - done) / total_speed if total_speed > 0 else 0
    lines = " | ".join("%s %s/s" % (labels[i], human(s)) for i, s in speeds.items())
    sys.stdout.write("\r[%s] %5.1f%%  %s  | total %s/s  ETA %dm%02ds   "
                     % (bar, pct, lines, human(total_speed), eta // 60, eta % 60))
    sys.stdout.flush()


def single_stream(info, path, iface):
    """Server does not support ranges: one connection, one line."""
    say("  This server doesn't allow ranged downloads, so one line downloads it.")
    emit("log", message="This server doesn't allow ranged downloads, so one line downloads it.")
    resp = info["resp"]
    got, t0, last = 0, time.time(), 0
    with open(path, "wb") as f:
        while True:
            data = resp.read(BLOCK)
            if not data:
                break
            f.write(data)
            got += len(data)
            LIMITER.take(len(data))
            now = time.time()
            el = max(now - t0, 0.001)
            if JSON_MODE:
                if now - last > 0.5:
                    emit("progress", done=got, size=info["size"], speeds={iface: int(got / el)},
                         received={iface: got})
                    last = now
            else:
                sys.stdout.write("\r  %s  %s/s   " % (human(got), human(got / el)))
                sys.stdout.flush()
    info["conn"].close()
    say("")
    return time.time() - t0, got


def unique_path(folder, name):
    base, ext = os.path.splitext(name)
    path, n = os.path.join(folder, name), 1
    while os.path.exists(path) and not os.path.exists(path + ".dualdl-part"):
        path = os.path.join(folder, "%s (%d)%s" % (base, n, ext))
        n += 1
    return path


def interface_list():
    hw = hardware_names()
    out = []
    for i in active_interfaces():
        ip = re.search(r"inet (\S+)", subprocess.run(["ifconfig", i], capture_output=True,
                                                    text=True).stdout)
        out.append({"iface": i, "label": hw.get(i, i).replace("Wi-Fi", "WiFi"),
                    "ip": ip.group(1) if ip else ""})
    return out


def download(url, folder, per_iface, only, cookies, name=None, skip_existing=False):
    ifaces = only or active_interfaces()
    hw = hardware_names()
    labels = {i: hw.get(i, i).replace("Wi-Fi", "WiFi") for i in ifaces}
    say("\nLink: %s" % url)
    say("Line: %s" % ", ".join("%s (%s)" % (labels[i], i) for i in ifaces))
    emit("lines", lines=[{"iface": i, "label": labels[i]} for i in ifaces])
    if is_drive_folder(url):
        raise Fail("That's a Google Drive folder link: add it in the DualDL app, which downloads every "
                   "file in it.")
    info = probe(url, ifaces, dict(cookies))
    clean = (name or info["name"]).replace("/", "_")
    if skip_existing and info["size"] and os.path.isfile(os.path.join(folder, clean)) \
            and os.path.getsize(os.path.join(folder, clean)) == info["size"]:
        done_path = os.path.join(folder, clean)            # already here in full (re-added folder)
        if info.get("conn"):
            info["conn"].close()
        emit("info", name=clean, path=done_path, size=info["size"], ranges=True, resumed=info["size"])
        emit("done", path=done_path, elapsed=0, size=info["size"], received={}, skipped=True)
        return
    if "google" in (urlparse(info["url"]).hostname or ""):
        per_iface = min(per_iface, 3)        # Google Drive limits sooner with many parallel requests
    path = unique_path(folder, clean)
    say("File: %s  (%s)" % (os.path.basename(path),
                            human(info["size"]) if info["size"] else "size ojana"))

    if not info["ranges"] or not info["size"]:
        emit("info", name=os.path.basename(path), path=path, size=info["size"],
             ranges=False, resumed=0)
        elapsed, got = single_stream(info, path, ifaces[0])
        say("Done: %s  (%.0f s)" % (path, elapsed))
        emit("done", path=path, elapsed=elapsed, size=got, received={ifaces[0]: got})
        return

    part, state = path + ".dualdl-part", path + ".dualdl.json"
    exp = link_expiry(url)
    job = Job(info, ifaces, per_iface, part, state, refresh=lambda: probe(url, ifaces, dict(cookies)),
              expires=exp and exp[0])
    emit("info", name=os.path.basename(path), path=path, size=job.size, ranges=True,
         resumed=job.resumed)
    if job.resumed:
        say("Resuming: %s already downloaded" % human(job.resumed))
    elapsed = job.run(labels)
    os.close(job.fd)
    if not job.error and not job.finished() and job.link_dead():
        raise Fail(expired_message(url))
    if job.error or not job.finished():
        raise Fail(job.error or "The download stopped early.", retry=job.retry or not job.error)
    os.replace(part, path)
    os.remove(state)
    fresh = job.size - job.resumed
    say("Done: %s" % path)
    say("Took %.0f s, average %s/s" % (elapsed, human(fresh / max(elapsed, 0.001))))
    total = sum(job.received.values()) or 1
    for i in ifaces:
        say("  %-10s %s  (%d%%)" % (labels[i], human(job.received[i]),
                                    job.received[i] * 100 // total))
    emit("done", path=path, elapsed=elapsed, size=job.size, received=job.received)


def parse_cookies(raw):
    cookies = {}
    for part in (raw or "").split(";"):
        k, sep, v = part.strip().partition("=")
        if sep and k:
            cookies[k] = v
    return cookies


def interrupt(*_):
    raise KeyboardInterrupt


def main():
    global JSON_MODE
    ap = argparse.ArgumentParser(description="Download one file over every network line at once (Ethernet + Wi-Fi)")
    ap.add_argument("urls", nargs="*", help="download link (Google Drive file links work too)")
    ap.add_argument("-o", "--out", default=os.path.expanduser("~/Downloads"),
                    help="folder to save into (default: ~/Downloads)")
    ap.add_argument("-n", "--connections", type=int, default=4,
                    help="connections per line (default 4)")
    ap.add_argument("-i", "--interfaces", help="only these interfaces, e.g. en0,en1")
    ap.add_argument("--cookie", help="a browser Cookie header (for private files)")
    ap.add_argument("--referer", help="Referer header")
    ap.add_argument("--name", help="save under this file name")
    ap.add_argument("--json", action="store_true", help="JSON lines output (what the app reads)")
    ap.add_argument("--list-interfaces", action="store_true", help="list the active network lines")
    ap.add_argument("--check-lines", action="store_true",
                    help="show each line's public IP and ISP (are they really different ISPs?)")
    ap.add_argument("--limit", type=float, default=0, help="speed limit in MB/s (0 = none)")
    ap.add_argument("--list-folder", metavar="URL", help="list every file in a shared Google Drive folder")
    ap.add_argument("--skip-existing", action="store_true",
                    help="finish at once if the file is already there in full (re-added folders)")
    args = ap.parse_args()
    JSON_MODE = args.json
    signal.signal(signal.SIGTERM, interrupt)

    if args.list_interfaces:
        print(json.dumps(interface_list()))
        return
    if args.check_lines:
        print(json.dumps(check_lines()))
        return
    cookie = args.cookie or os.environ.get("DUALDL_COOKIE")    # env keeps it out of `ps`
    if args.list_folder:
        try:
            name, files = list_drive_folder(args.list_folder, parse_cookies(cookie))
            emit("folder", name=name, files=files) if JSON_MODE else print(json.dumps({"name": name, "files": files}))
        except SystemExit as e:
            if JSON_MODE and isinstance(e.code, str):
                emit("error", message=e.code, retry=getattr(e, "retry", False))
                sys.exit(1)
            raise
        return
    LIMITER.rate = args.limit * 1024 * 1024
    if not args.urls:
        ap.error("give a link to download")
    if args.referer:
        HEADERS["Referer"] = args.referer
    only = args.interfaces.split(",") if args.interfaces else None
    try:
        if not (only or active_interfaces()):
            sys.exit("No active network connection found.")
        os.makedirs(args.out, exist_ok=True)
        for url in args.urls:
            download(url, args.out, args.connections, only, parse_cookies(cookie), args.name, args.skip_existing)
    except SystemExit as e:
        if JSON_MODE and isinstance(e.code, str):
            emit("error", message=e.code, retry=getattr(e, "retry", False))
            sys.exit(1)
        raise
    except KeyboardInterrupt:
        emit("paused")
        sys.exit(130)
    except Exception as e:
        if JSON_MODE:
            emit("error", message="%s: %s" % (type(e).__name__, e), retry=isinstance(e, OSError))
            sys.exit(1)
        raise


if __name__ == "__main__":
    main()
