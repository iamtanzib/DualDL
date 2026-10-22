#!/usr/bin/env python3
"""video.py --convert: VP9/AV1/Opus become QuickTime/Premiere-ready; good files are left alone.

    python3 convert_test.py <work folder>
"""
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "engine"))
import tools  # noqa: E402

W = sys.argv[1]
FF, PROBE = tools.tool_path("ffmpeg"), tools.tool_path("ffprobe")
failures = 0


def check(ok, name, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + name + (" — " + str(detail) if detail and not ok else ""))
    failures += not ok


if not FF or not PROBE:
    print("SKIP convert tests (ffmpeg not installed)")
    sys.exit(0)


def make(name, size, vargs, aargs, secs=4):
    out = os.path.join(W, name)
    r = subprocess.run([FF, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=%s:rate=30" % size, "-f", "lavfi", "-i", "sine=frequency=440",
                        "-t", str(secs)] + vargs + aargs + ["-shortest", out], capture_output=True)
    return out if r.returncode == 0 and os.path.getsize(out) > 0 else None


def streams(path):
    r = subprocess.run([PROBE, "-v", "error", "-show_entries", "stream=codec_name,codec_tag_string,pix_fmt:"
                        "format=duration", "-of", "json", path], capture_output=True, text=True)
    return json.loads(r.stdout)


def convert(path):
    out = subprocess.run([sys.executable, os.path.join(HERE, "..", "engine", "video.py"), "--json", "--convert", path],
                         capture_output=True, text=True).stdout
    return [json.loads(l) for l in out.splitlines() if l.strip()][-1]


cases = [
    ("vp9_1440.mp4", "2560x1440", ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "8M"],
     ["-c:a", "libopus"], "hevc"),
    ("vp9_1080.webm", "1920x1080", ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", "-b:v", "5M"],
     ["-c:a", "libopus"], "h264"),
    ("av1_10bit.mp4", "1920x1080", ["-c:v", "libsvtav1", "-preset", "11", "-pix_fmt", "yuv420p10le"],
     ["-c:a", "libopus"], "h264"),
]
for name, size, v, a, want in cases:
    src = make(name, size, v, a)
    if not src:
        print("SKIP %s (this ffmpeg can't make it)" % name)
        continue
    before = os.path.getsize(src)
    e = convert(src)
    ok = e["event"] == "done" and os.path.exists(e["path"])
    check(ok, "%s converts" % name, e)
    if not ok:
        continue
    st = streams(e["path"])
    vs = [s for s in st["streams"] if s["codec_name"] in ("h264", "hevc")]
    aud = [s for s in st["streams"] if s["codec_name"] == "aac"]
    check(vs and vs[0]["codec_name"] == want, "%s → %s video" % (name, want), st)
    check(want != "hevc" or vs[0]["codec_tag_string"] == "hvc1", "%s HEVC carries the hvc1 tag QuickTime needs" % name)
    check(vs and vs[0].get("pix_fmt") in ("yuv420p", "nv12", None) or want == "hevc", "%s → 8-bit for H.264" % name, vs)
    check(bool(aud), "%s audio → AAC" % name, st)
    check(abs(float(st["format"]["duration"]) - 4) < 0.5, "%s keeps its length" % name, st["format"])
    check(e["target"].endswith(".mp4") and os.path.getsize(src) == before, "%s original untouched until the app swaps" % name)
    os.remove(e["path"])

src = make("h264.mp4", "1280x720", ["-c:v", "libx264"], ["-c:a", "aac"])
e = convert(src)
check(e["event"] == "done" and e.get("already") and e["path"] == src, "an H.264 + AAC .mp4 is left alone", e)
check(not glob.glob(os.path.join(W, ".dualdl-convert-*")), "no temp files left behind")

bad = os.path.join(W, "broken.mp4")
open(bad, "wb").write(b"\0" * 1000)
e = convert(bad)
check(e["event"] == "error" and os.path.exists(bad), "a broken file gives a clear error and stays put", e)

sys.exit(1 if failures else 0)
