#!/usr/bin/env python3
"""dualdl.py against a difficult server (tests/range_server.py over loopback, no internet):
expiring links, throttling (429 + Retry-After), a server ignoring Range, a dead server,
and re-adding a file that's already complete.

    python3 robust_test.py <work folder>
"""
import filecmp
import json
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ENGINE = os.path.join(HERE, "..", "engine", "dualdl.py")
W = sys.argv[1]
failures = 0


def check(ok, name, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail and not ok else ""))
    failures += not ok


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def run(url, out, *extra, timeout=240):
    t0 = time.time()
    p = subprocess.run([sys.executable, ENGINE, "--json", "-i", "lo0", "-o", out] + list(extra) + [url],
                       capture_output=True, text=True, timeout=timeout)
    events = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    return events, time.time() - t0


srv_dir = os.path.join(W, "srv")
os.makedirs(srv_dir)
big = os.path.join(srv_dir, "big.bin")
with open(big, "wb") as f:
    f.write(os.urandom(60 << 20))
port = free_port()
server = subprocess.Popen([sys.executable, os.path.join(HERE, "range_server.py"), srv_dir, str(port), "0", "6"])
time.sleep(0.6)
base = "http://127.0.0.1:%d" % port
try:
    out = os.path.join(W, "expiring")
    ev, secs = run(base + "/page/big.bin", out)
    fresh = [e for e in ev if e["event"] == "log" and "fresh download link" in e.get("message", "")]
    check(ev[-1]["event"] == "done", "an expiring link still finishes", ev[-1])
    check(len(fresh) >= 1, "it fetched fresh links along the way", "%d fresh links" % len(fresh))
    check(filecmp.cmp(big, os.path.join(out, "big.bin"), shallow=False), "the file is byte-identical")
    print("     (%.0f s, %d fresh links)" % (secs, len(fresh)))

    out = os.path.join(W, "throttle")
    ev, secs = run(base + "/throttle/big.bin", out)
    check(ev[-1]["event"] == "done" and filecmp.cmp(big, os.path.join(out, "big.bin"), shallow=False),
          "a throttling server (429 + Retry-After) still finishes intact", ev[-1])

    out = os.path.join(W, "norange")
    ev, secs = run(base + "/norange/big.bin", out)
    check(ev[-1]["event"] == "done" and filecmp.cmp(big, os.path.join(out, "big.bin"), shallow=False),
          "a server that ignores Range still works (one stream)", ev[-1])

    ev, secs = run(base + "/throttle/big.bin", os.path.join(W, "throttle"), "--skip-existing", "--name", "big.bin")
    check(ev[-1]["event"] == "done" and ev[-1].get("skipped") and secs < 20,
          "re-adding a complete file finishes at once", (ev[-1], secs))
    check(not os.path.exists(os.path.join(W, "throttle", "big (1).bin")), "…without making a duplicate")

    # a Drive folder page (with a subfolder) lists every file with its own link
    page = ('<html><head><title>My &amp; Folder</title></head><body>'
            '<div class="flip-entry" id="entry-abc"><a href="https://drive.google.com/file/d/abc/view">'
            '<div class="flip-entry-title">one.mov</div></a></div>'
            '<div class="flip-entry" id="entry-SUB"><a href="https://drive.google.com/drive/folders/SUB">'
            '<div class="flip-entry-title">Inner</div></a></div></body></html>')
    open(os.path.join(srv_dir, "folder-TOP.html"), "w").write(page)
    open(os.path.join(srv_dir, "folder-SUB.html"), "w").write(
        '<html><head><title>Inner</title></head><body><div class="flip-entry" id="entry-def">'
        '<a href="https://drive.google.com/file/d/def/view"><div class="flip-entry-title">two.mov</div></a></div></body></html>')
    env = dict(os.environ, DUALDL_DRIVE_BASE=base)
    out = subprocess.run([sys.executable, ENGINE, "--json", "--list-folder", base + "/drive/folders/TOP"],
                         capture_output=True, text=True, env=env).stdout
    e = json.loads(out.strip().splitlines()[-1])
    files = sorted((f["path"], f["name"], f["url"].rsplit("/", 2)[-2]) for f in e.get("files", []))
    check(e.get("name") == "My & Folder" and files == [("", "one.mov", "abc"), ("Inner", "two.mov", "def")],
          "a Drive folder (with a subfolder) lists every file", e)

    open(os.path.join(srv_dir, ".down"), "w").close()
    ev, secs = run(base + "/page/big.bin", os.path.join(W, "down"))
    check(ev[-1]["event"] == "error" and ev[-1].get("retry") is True,
          "a dead server ends with 'retry later' (not a dead end)", ev[-1])
    check(secs < 60, "…and gives up quickly instead of hanging", "%.0f s" % secs)
finally:
    server.terminate()

sys.exit(1 if failures else 0)
