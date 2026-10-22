#!/usr/bin/env python3
"""unzip.py: Drive pieces merge, loose files, split archives, path escapes, re-runs.

    python3 unzip_test.py <empty work folder>
"""
import filecmp
import json
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
UNZIP = os.path.join(HERE, "..", "engine", "unzip.py")
W = sys.argv[1]
failures = 0


def check(ok, name, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + name + (" — " + detail if detail and not ok else ""))
    failures += not ok


def run(path):
    out = subprocess.run([sys.executable, UNZIP, path], capture_output=True, text=True).stdout
    events = [json.loads(l) for l in out.splitlines() if l.strip()]
    return [e for e in events if e["event"] != "progress"]


def same_tree(a, b):
    c = filecmp.dircmp(a, b)
    return not (c.left_only or c.right_only or c.diff_files or c.funny_files) and all(
        same_tree(os.path.join(a, d), os.path.join(b, d)) for d in c.common_dirs)


src = os.path.join(W, "src", "Holiday Videos")
os.makedirs(os.path.join(src, "sub"))
for n in "abc":
    with open(os.path.join(src, n + ".mov"), "wb") as f:
        f.write(os.urandom(2_000_000))
with open(os.path.join(src, "sub", "note ✓.txt"), "w") as f:
    f.write("unicode name")

# Google Drive pieces, extracted out of order and one of them twice
drive = os.path.join(W, "drive")
os.makedirs(drive)
pieces = {"001": ["a.mov"], "002": ["b.mov", "sub/note ✓.txt"], "003": ["c.mov"]}
for n, files in pieces.items():
    with zipfile.ZipFile(os.path.join(drive, "Holiday Videos -20260101T120000Z-1-%s.zip" % n), "w",
                         zipfile.ZIP_DEFLATED) as z:
        for f in files:
            z.write(os.path.join(src, f), "Holiday Videos/" + f)
for n in ["002", "001", "003", "001"]:
    ev = run(os.path.join(drive, "Holiday Videos -20260101T120000Z-1-%s.zip" % n))
    check(ev[-1]["event"] == "done", "drive piece %s unzips" % n, str(ev[-1:]))
check(same_tree(src, os.path.join(drive, "Holiday Videos")), "drive pieces merge into one identical folder")
check(ev[-1].get("skipped") == 1 and ev[-1].get("files") == 0, "re-running a piece skips existing files")

# Loose files get a folder named after the zip
loose = os.path.join(W, "loose")
os.makedirs(loose)
with zipfile.ZipFile(os.path.join(loose, "photos.zip"), "w") as z:
    z.writestr("x.txt", "x")
    z.writestr("y.txt", "y")
run(os.path.join(loose, "photos.zip"))
check(sorted(os.listdir(os.path.join(loose, "photos"))) == ["x.txt", "y.txt"], "loose files go into a named folder")

# Split archive: waits until every piece is there
split = os.path.join(W, "split")
os.makedirs(split)
whole = os.path.join(split, "big.zip")
with zipfile.ZipFile(whole, "w", zipfile.ZIP_STORED) as z:
    for n in "abc":
        z.write(os.path.join(src, n + ".mov"), "Big/" + n + ".mov")
data = open(whole, "rb").read()
os.remove(whole)
k = len(data) // 3 + 1
for i in range(3):
    with open(os.path.join(split, "big.zip.%03d" % (i + 1)), "wb") as f:
        f.write(data[i * k:(i + 1) * k])
os.rename(os.path.join(split, "big.zip.003"), os.path.join(W, "held.003"))
check(run(os.path.join(split, "big.zip.002"))[-1]["event"] == "waiting", "split archive waits for missing pieces")
os.rename(os.path.join(W, "held.003"), os.path.join(split, "big.zip.003"))
check(run(os.path.join(split, "big.zip.003"))[-1]["event"] == "done", "split archive unzips when complete")
check(filecmp.cmp(os.path.join(split, "Big", "b.mov"), os.path.join(src, "b.mov"), shallow=False),
      "split archive content is intact")

# Entries that try to leave the folder are refused
evil = os.path.join(W, "evil")
os.makedirs(evil)
with zipfile.ZipFile(os.path.join(evil, "evil.zip"), "w") as z:
    z.writestr("../escaped.txt", "bad")
    z.writestr("/abs.txt", "bad")
    z.writestr("ok.txt", "ok")
run(os.path.join(evil, "evil.zip"))
check(not os.path.exists(os.path.join(W, "escaped.txt")), "'../' entry can't escape")
check(os.listdir(os.path.join(evil, "evil")) == ["ok.txt"], "only the safe entry is written",
      str(os.listdir(os.path.join(evil, "evil"))))

# A broken zip fails cleanly
with open(os.path.join(evil, "broken.zip"), "wb") as f:
    f.write(b"not a zip at all")
ev = run(os.path.join(evil, "broken.zip"))
check(ev and ev[-1]["event"] == "error", "a broken zip reports an error", str(ev))

sys.exit(1 if failures else 0)
