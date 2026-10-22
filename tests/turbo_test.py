#!/usr/bin/env python3
"""turbo.py: site grouping, line choice, and a real tunnel over loopback (no internet).

    python3 turbo_test.py <work folder>     (needs tests/range_server.py)
"""
import filecmp
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "engine"))
import turbo  # noqa: E402

W = sys.argv[1]
failures = 0


def check(ok, name, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail and not ok else ""))
    failures += not ok


# --- which line a site belongs with
for host, want in [("www.youtube.com", "google"), ("rr3---sn-a5m7ln7d.googlevideo.com", "google"),
                   ("i.ytimg.com", "google"), ("scontent.xx.fbcdn.net", "meta"), ("www.instagram.com", "meta"),
                   ("news.bbc.co.uk", "bbc.co.uk"), ("www.prothomalo.com", "prothomalo.com"),
                   ("ib.bank.com.bd", "bank.com.bd"), ("Example.COM.", "example.com")]:
    check(turbo.site_of(host) == want, "site of %s is %s" % (host, want), turbo.site_of(host))

# --- line choice (lo0 stands in for real lines; only the bookkeeping is tested)
MB = 1 << 20
lines = turbo.Lines.__new__(turbo.Lines)
lines.ifaces = ["en0", "en1"]
lines.index = {"en0": 1, "en1": 1}
lines.active = {"en0": 0, "en1": 0}
lines.bytes = {"en0": 0, "en1": 0}
lines.rate = {"en0": 0.0, "en1": 0.0}
lines.down_until = {"en0": 0.0, "en1": 0.0}
lines.sites, lines.given = {}, {"en0": 0, "en1": 0}
lines.capacity = {"en0": 1.1 * MB, "en1": 6.0 * MB}
lines.probed = dict(lines.capacity)
lines._last = dict(lines.bytes)

check(lines.pick("a.com") == "en1", "an idle setup sends new sites to the fast line")
check(lines.pick("b.com") == "en1", "the fast line keeps taking sites while it has room")
lines.rate["en1"] = 5.5 * MB
check(lines.pick("c.com") == "en0", "a busy fast line spills new sites to the other line")
check(lines.pick("a.com") == "en1", "a known site stays on its line (logins see one IP)")
check(lines.pick("google") == "en1", "video sites always use the fastest line")
lines.down_until["en1"] = time.time() + 30
check(lines.pick("a.com") == "en0", "a site moves off a line that stopped working")
check(lines.pick("d.com") == "en0", "new sites skip a line that stopped working")
lines.down_until["en1"] = 0
lines.rate["en1"] = 0
lines.bytes["en0"] += 3 * MB
for _ in range(5):
    lines.tick()
check(lines.capacity["en0"] > 1.1 * MB, "a line's speed estimate grows when it shows more",
      lines.capacity["en0"])

# --- a real tunnel over loopback
srv_dir = os.path.join(W, "srv")
os.makedirs(srv_dir)
with open(os.path.join(srv_dir, "f.bin"), "wb") as f:
    f.write(os.urandom(5 * MB))


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


sp, tp = free_port(), free_port()
srv = subprocess.Popen([sys.executable, os.path.join(HERE, "range_server.py"), srv_dir, str(sp)])
prox = subprocess.Popen([sys.executable, os.path.join(HERE, "..", "engine", "turbo.py"), "--port", str(tp),
                         "-i", "lo0", "--allow-local", "--no-probe"], stdout=subprocess.PIPE, text=True)
try:
    ready = prox.stdout.readline()
    check('"ready"' in ready, "proxy starts", ready)
    out = os.path.join(W, "got.bin")
    code = subprocess.run(["curl", "-s", "-p", "-x", "http://127.0.0.1:%d" % tp, "-o", out, "-w", "%{http_code}",
                           "--max-time", "20", "http://127.0.0.1:%d/f.bin" % sp], capture_output=True, text=True).stdout
    check(code == "200" and filecmp.cmp(out, os.path.join(srv_dir, "f.bin"), shallow=False),
          "a file through the tunnel arrives byte-identical", code)
    code = subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5",
                           "-x", "http://127.0.0.1:%d" % tp, "http://127.0.0.1:%d/f.bin" % sp],
                          capture_output=True, text=True).stdout
    check(code == "405", "plain (non-tunnel) requests are refused", code)
finally:
    prox.terminate()
    srv.terminate()

# private targets are refused unless --allow-local
tp2 = free_port()
prox = subprocess.Popen([sys.executable, os.path.join(HERE, "..", "engine", "turbo.py"), "--port", str(tp2),
                         "-i", "lo0", "--no-probe"], stdout=subprocess.PIPE, text=True)
try:
    prox.stdout.readline()
    r = subprocess.run(["curl", "-s", "-p", "-x", "http://127.0.0.1:%d" % tp2, "-o", "/dev/null", "-w",
                        "%{http_connect}", "--max-time", "5", "http://192.168.1.1/"], capture_output=True, text=True)
    check(r.stdout.strip() == "403", "tunnels to the local network are refused", r.stdout)
finally:
    prox.terminate()

sys.exit(1 if failures else 0)
