#!/usr/bin/env python3
"""Finds, installs and updates the helper tools DualDL uses for video sites.

    yt-dlp  reads video pages and picks the streams   (github.com/yt-dlp/yt-dlp)
    deno    runs YouTube's JavaScript checks so the     (github.com/denoland/deno)
            high-quality formats aren't hidden
    ffmpeg  joins video + audio, makes MP3              (found on the system)

Every download is checked against the SHA-256 the project publishes before it
is installed. Prints one JSON object per line.

    python3 tools.py --status
    python3 tools.py --install        # installs or updates yt-dlp and deno
"""
import hashlib
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import glob
import tempfile
import urllib.request
import zipfile

TOOLS_DIR = os.path.expanduser("~/Library/Application Support/DualDL/tools")
# yt-dlp's unpacked build: the single-file build re-extracts itself on every run,
# which costs ~8 s before it does anything. This one starts at once.
YTDLP_DIR = os.path.join(TOOLS_DIR, "yt-dlp-dist")
FFMPEG_DIRS = [TOOLS_DIR, os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
               "/usr/bin"]
UA = {"User-Agent": "DualDL", "Accept": "application/vnd.github+json"}
CTX = ssl.create_default_context()


def emit(event, **data):
    data["event"] = event
    sys.stdout.write(json.dumps(data) + "\n")
    sys.stdout.flush()


def tool_path(name):
    """Full path of yt-dlp / deno / ffmpeg / ffprobe, or None."""
    if name in ("ffmpeg", "ffprobe"):
        for d in FFMPEG_DIRS:
            p = os.path.join(d, name)
            if os.access(p, os.X_OK):
                return p
        return None
    if name == "yt-dlp":
        for p in sorted(glob.glob(os.path.join(YTDLP_DIR, "**", "yt-dlp_macos"), recursive=True)):
            if os.path.isfile(p) and os.access(p, os.X_OK):
                return p
    p = os.path.join(TOOLS_DIR, name)
    return p if os.access(p, os.X_OK) else None


def version_of(name):
    p = tool_path(name)
    if not p:
        return None
    arg = "-version" if name.startswith("ff") else "--version"
    try:
        out = subprocess.run([p, arg], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    line = out.strip().splitlines()[0] if out.strip() else ""
    m = re.search(r"(\d+(?:\.\d+)+)", line)
    return m.group(1) if m else line or None


def status():
    return {n: {"path": tool_path(n), "version": version_of(n)} for n in ("yt-dlp", "deno", "ffmpeg")}


def fetch_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), context=CTX, timeout=30) as r:
        return json.loads(r.read().decode())


def download(url, dest, label):
    req = urllib.request.Request(url, headers={"User-Agent": "DualDL"})
    with urllib.request.urlopen(req, context=CTX, timeout=60) as r, open(dest, "wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        got, last = 0, -1
        while True:
            block = r.read(1 << 20)
            if not block:
                break
            f.write(block)
            got += len(block)
            pct = got * 100 // total if total else 0
            if pct != last:
                emit("progress", tool=label, done=got, size=total)
                last = pct


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def expected_hash(text, filename):
    for line in text.splitlines():
        m = re.match(r"([0-9a-fA-F]{64})\s+\*?(\S+)", line.strip())
        if m and os.path.basename(m.group(2)) == filename:
            return m.group(1).lower()
    m = re.match(r"([0-9a-fA-F]{64})", text.strip())     # single-hash file
    return m.group(1).lower() if m else None


def install_from_release(repo, asset, sums_asset, name, staging):
    rel = fetch_json("https://api.github.com/repos/%s/releases/latest" % repo)
    tag = rel["tag_name"]
    assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
    if asset not in assets or sums_asset not in assets:
        raise RuntimeError("%s release %s is missing %s" % (repo, tag, asset))
    have = version_of(name)
    upgrading_build = name == "yt-dlp" and not os.path.isdir(YTDLP_DIR)
    if have and have.lstrip("v") == tag.lstrip("v") and not upgrading_build:
        emit("log", message="%s %s is already up to date" % (name, have))
        return tag

    emit("log", message="Downloading %s %s" % (name, tag))
    path = os.path.join(staging, asset)
    download(assets[asset], path, name)
    with urllib.request.urlopen(urllib.request.Request(assets[sums_asset], headers={"User-Agent": "DualDL"}),
                                context=CTX, timeout=30) as r:
        want = expected_hash(r.read().decode(), asset)
    got = sha256(path)
    if not want or got != want:
        raise RuntimeError("%s checksum does not match (%s), not installed" % (asset, got[:12]))

    if name == "yt-dlp":
        # ditto keeps the executable bits and symlinks the unpacked build relies on
        dist = os.path.join(staging, "yt-dlp-dist")
        subprocess.run(["/usr/bin/ditto", "-x", "-k", path, dist], check=True)
        exe = glob.glob(os.path.join(dist, "**", "yt-dlp_macos"), recursive=True)
        if not exe:
            raise RuntimeError("yt-dlp_macos.zip didn't contain yt-dlp_macos")
        r = subprocess.run([exe[0], "--version"], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise RuntimeError("the new yt-dlp doesn't start: %s" % r.stderr.strip()[-200:])
        old = os.path.join(staging, "old")
        if os.path.isdir(YTDLP_DIR):
            os.replace(YTDLP_DIR, old)            # swap in one step; the old copy goes with staging
        os.replace(dist, YTDLP_DIR)
        single = os.path.join(TOOLS_DIR, "yt-dlp")
        if os.path.isfile(single):
            os.remove(single)
        emit("installed", tool=name, version=tag)
        return tag
    if asset.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            member = next(m for m in z.namelist() if os.path.basename(m) == name)
            with z.open(member) as src, open(os.path.join(staging, name), "wb") as dst:
                shutil.copyfileobj(src, dst)
        path = os.path.join(staging, name)
    os.chmod(path, 0o755)
    os.makedirs(TOOLS_DIR, exist_ok=True)
    os.replace(path, os.path.join(TOOLS_DIR, name))       # atomic: a running copy is never half-written
    emit("installed", tool=name, version=tag)
    return tag


def install():
    os.makedirs(TOOLS_DIR, exist_ok=True)
    staging = tempfile.mkdtemp(prefix=".staging-", dir=TOOLS_DIR)
    try:
        install_from_release("yt-dlp/yt-dlp", "yt-dlp_macos.zip", "SHA2-256SUMS", "yt-dlp", staging)
        install_from_release("denoland/deno", "deno-aarch64-apple-darwin.zip",
                             "deno-aarch64-apple-darwin.zip.sha256sum", "deno", staging)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main():
    try:
        if "--install" in sys.argv:
            install()
        emit("status", tools=status())
    except Exception as e:
        emit("error", message="%s: %s" % (type(e).__name__, e))
        sys.exit(1)


if __name__ == "__main__":
    main()
