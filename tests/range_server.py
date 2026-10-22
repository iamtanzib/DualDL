#!/usr/bin/env python3
"""Local file server for tests: Range requests, keep-alive, and a speed cap so
pause/cancel can be tested mid-download. Serves one folder on 127.0.0.1.

It can also behave like a difficult server (Google Drive under load):
  /page/<file>          redirects to /tok/<token>/<file>; the token stops working
                        after TOKEN_LIFE requests (403), like an expiring Drive link
  /throttle/<file>      every 3rd request gets 429 + Retry-After: 1
  /norange/<file>       ignores Range and always sends the whole file (200)
  <folder>/.down        while this file exists, everything answers 503
  /embeddedfolderview?id=X   serves <folder>/folder-X.html (a fake Drive folder page)
  /file/d/<id>/view     serves <folder>/<id> (a fake Drive file link)

    python3 range_server.py <folder> <port> [MB/s per connection] [token life]
"""
import http.server
import os
import re
import socketserver
import sys
import time
import urllib.parse

ROOT, PORT = sys.argv[1], int(sys.argv[2])
RATE = float(sys.argv[3]) * 1024 * 1024 if len(sys.argv) > 3 else 0
TOKEN_LIFE = int(sys.argv[4]) if len(sys.argv) > 4 else 6
state = {"token": 1, "uses": 0, "throttle": 0}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, code, headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        route = urllib.parse.unquote(self.path.split("?")[0])
        if os.path.exists(os.path.join(ROOT, ".down")):
            return self.reply(503)
        parts = route.strip("/").split("/")
        if parts[0] == "embeddedfolderview":
            fid = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("id", [""])[0]
            page = os.path.join(ROOT, "folder-%s.html" % fid)
            if not os.path.isfile(page):
                return self.reply(404)
            body = open(page, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parts[:2] == ["file", "d"] and len(parts) >= 3:
            route = parts[2]
        if parts[0] == "page":
            return self.reply(302, [("Location", "/tok/%d/%s" % (state["token"], parts[-1]))])
        if parts[0] == "tok":
            if int(parts[1]) != state["token"]:
                return self.reply(403)
            state["uses"] += 1
            if state["uses"] >= TOKEN_LIFE:
                state["token"] += 1
                state["uses"] = 0
        if parts[0] == "throttle":
            state["throttle"] += 1
            if state["throttle"] % 3 == 0:
                return self.reply(429, [("Retry-After", "1")])
        norange = parts[0] == "norange"
        path = os.path.join(ROOT, os.path.basename(route))
        if not os.path.isfile(path):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        size = os.path.getsize(path)
        start, end = 0, size - 1
        m = None if norange else re.match(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if m:
            start = int(m.group(1))
            end = min(int(m.group(2)) if m.group(2) else size - 1, size - 1)
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % os.path.basename(path))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            while left > 0:
                block = f.read(min(256 * 1024, left))
                try:
                    self.wfile.write(block)
                except (BrokenPipeError, ConnectionResetError):
                    return
                left -= len(block)
                if RATE:
                    time.sleep(len(block) / RATE)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, *_):
        pass            # clients hang up on pause/cancel; that's expected


Server(("127.0.0.1", PORT), Handler).serve_forever()
