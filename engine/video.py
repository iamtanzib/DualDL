#!/usr/bin/env python3
"""Video and audio downloads (YouTube and the other sites yt-dlp supports).

yt-dlp only reads the page and picks the streams. The bytes come down through
dualdl's engine over every line at once, in 4 MB ranges (which also sidesteps
YouTube's per-connection throttling). ffmpeg then joins video + audio without
re-encoding, or makes an MP3 with cover art.

Sites hand out stream links tied to the IP that asked for them, so each line
asks for its own link. If one line gets rate-limited or bot-checked, the page
is read through the next line (a different ISP, a different IP) instead.

    python3 video.py --json -o ~/Downloads --mode video --quality 1080 URL
    python3 video.py --preview URL            # title, thumbnail, qualities, sizes
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dualdl  # noqa: E402
import tools   # noqa: E402

CACHE_DIR = os.path.expanduser("~/Library/Caches/DualDL/info")
CACHE_AGE = 20 * 60            # preview info is reused for this long (links stay valid for hours)
MP4_VIDEO = ("avc1", "h264", "hev1", "hvc1", "av01", "vp09", "vp9")
EDIT_VIDEO = ("h264", "hevc")                   # what QuickTime and Premiere open (ffprobe names)
EDIT_AUDIO = ("aac", "mp3", "alac")
VIDEO_EXTS = (".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".flv", ".3gp", ".ts")
BROWSER = None                 # --browser-cookies: read the login from this browser when no cookies file
RUNNING = set()                # yt-dlp processes still reading a page (killed once one line has answered)
emit = dualdl.emit


class SiteError(Exception):
    pass


def friendly(stderr):
    lines = [l for l in stderr.strip().splitlines() if l.strip()]
    last = next((l for l in reversed(lines) if "ERROR" in l), lines[-1] if lines else "yt-dlp failed")
    low = last.lower()
    if "not a bot" in low or "sign in to confirm" in low:
        return ("YouTube wants to check you're not a bot. Turn on Settings → Use my Chrome login "
                "(with Chrome open), or send the video from Chrome with the DualDL extension.")
    if "private video" in low or "members-only" in low or "age" in low and "sign in" in low:
        return "This video needs you to be signed in. Send it from Chrome with the DualDL extension."
    if "unsupported url" in low:
        return "This site isn't supported for video. Download it as a normal file instead."
    if "429" in low or "too many requests" in low:
        return "The site is rate-limiting both lines right now. Wait a few minutes and retry."
    return re.sub(r"^ERROR:\s*(\[[^\]]+\]\s*)?", "", last).strip()


def ytdlp_info(url, ip, fmt=None, sort=None, cookies=None, info_file=None):
    cmd = [tools.tool_path("yt-dlp"), "-J", "--no-playlist", "--no-warnings",
           "--socket-timeout", "20", "--extractor-retries", "3", "--source-address", ip]
    deno = tools.tool_path("deno")
    if deno:
        cmd += ["--js-runtimes", "deno:" + deno]
    if fmt:
        cmd += ["-f", fmt]
    if sort:
        cmd += ["-S", sort]
    if cookies:
        cmd += ["--cookies", cookies]
    elif BROWSER and not info_file:
        cmd += ["--cookies-from-browser", BROWSER]
    cmd += ["--load-info-json", info_file] if info_file else [url]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    RUNNING.add(p)
    try:
        out, err = p.communicate(timeout=180)
    except subprocess.TimeoutExpired:
        p.kill()
        raise SiteError("Reading the page took too long")
    finally:
        RUNNING.discard(p)
    if p.returncode != 0:
        raise SiteError(friendly(err) if err.strip() else "Stopped")
    info = json.loads(out)
    if info.get("_type") == "playlist":
        raise SiteError("That's a playlist. Open one video and send its link.")
    if info.get("is_live"):
        raise SiteError("Live streams can't be downloaded while they're live.")
    return info


def choose(mode, quality, audio):
    """yt-dlp format + sort strings. Highest resolution first; at equal resolution
    prefer H.264/AAC, which play everywhere and decode with little CPU."""
    if mode == "audio":
        return ("ba[ext=m4a]/ba/b" if audio == "original" else "ba/b"), None
    if quality == "compatible":
        return "bv*+ba/b", "vcodec:h264,res,fps,acodec:aac"
    cap = "res:%s," % quality if quality.isdigit() else "res,"
    return "bv*+ba/b", cap + "fps,vcodec:h264,acodec:aac"


def cache_path(url):
    return os.path.join(CACHE_DIR, hashlib.sha1(url.encode()).hexdigest()[:16] + ".json")


def read_all(url, lines, ips, cookies, fmt, sort):
    """Reads the page through every line at once. Each line gets stream links for its
    own IP, and a line that's rate-limited or bot-checked simply drops out.
    Returns ({line: info}, primary line)."""
    import threading
    results, errors = {}, []
    cached = cache_path(url)
    if os.path.exists(cached) and time.time() - os.path.getmtime(cached) < CACHE_AGE:
        meta = json.load(open(cached + ".line")) if os.path.exists(cached + ".line") else {}
        if meta.get("iface") in lines:
            try:   # no network: re-pick formats from what the preview already read
                results[meta["iface"]] = ytdlp_info(url, ips[meta["iface"]], fmt, sort, cookies, info_file=cached)
            except SiteError:
                pass

    def one(ln):
        try:
            results[ln] = ytdlp_info(url, ips[ln], fmt, sort, cookies)
        except SiteError as e:
            errors.append(str(e))
            emit("log", message="%s couldn't read the page" % ln)

    threads = [threading.Thread(target=one, args=(ln,)) for ln in lines if ln not in results]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    primary = next((ln for ln in lines if ln in results), None)
    if not primary:
        raise SiteError(errors[-1] if errors else "No line could read the page")
    return results, primary


def read_first(url, lines, ips, cookies):
    """Asks every line at once and takes the first answer, so a blocked or slow line
    never makes you wait. Returns (info, line used)."""
    import queue
    import threading
    answers = queue.Queue()

    def one(ln):
        try:
            answers.put((ln, ytdlp_info(url, ips[ln], None, None, cookies)))
        except SiteError as e:
            answers.put((ln, e))

    for ln in lines:
        threading.Thread(target=one, args=(ln,), daemon=True).start()
    errors = []
    try:
        for _ in lines:
            ln, result = answers.get()
            if isinstance(result, dict):
                return result, ln
            errors.append(str(result))
    finally:
        for p in list(RUNNING):        # the other lines' answers aren't needed any more
            p.kill()
    raise SiteError(errors[-1] if errors else "No line could read the page")


def streams_of(info):
    return info.get("requested_formats") or [info]


def human_size(info, f):
    return f.get("filesize") or f.get("filesize_approx") or 0


# ------------------------------------------------------------------ preview

def preview(url, lines, ips, cookies):
    info, ln = read_first(url, lines, ips, cookies)
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = cache_path(url)
    with open(path, "w") as f:
        json.dump(info, f)
    with open(path + ".line", "w") as f:
        json.dump({"iface": ln}, f)

    fmts = info.get("formats") or [info]
    audio = [f for f in fmts if f.get("vcodec") == "none" and f.get("acodec") not in (None, "none")]
    best_audio = max(audio, key=lambda f: (f.get("ext") == "m4a", f.get("abr") or 0), default=None)
    asize = human_size(info, best_audio) if best_audio else 0
    heights = {}
    for f in fmts:
        h = f.get("height")
        if not h or f.get("vcodec") in (None, "none"):
            continue
        size = human_size(info, f) + (asize if f.get("acodec") in (None, "none") else 0)
        better = (f.get("vcodec", "").startswith("avc1"), size)
        if h not in heights or better > heights[h][0]:
            heights[h] = (better, size, f.get("fps"))
    duration = info.get("duration") or 0
    emit("preview", title=info.get("title") or "Video", uploader=info.get("uploader") or "",
         duration=duration, thumbnail=info.get("thumbnail") or "", site=info.get("extractor_key") or "",
         qualities=[{"height": h, "size": v[1], "fps": v[2]} for h, v in sorted(heights.items(), reverse=True)],
         mp3_size=int(duration * 245000 / 8) if duration else 0, audio_size=asize)


# ------------------------------------------------------------------ download

def probe_line(url, ln, headers):
    dualdl.HEADERS.clear()
    dualdl.HEADERS.update(headers)
    dualdl.HEADERS["Accept-Encoding"] = "identity"
    try:
        p = dualdl.probe(url, [ln], {})
    except SystemExit:
        return None
    if p.get("conn"):
        p["conn"].close()
    return p if p["ranges"] and p["size"] else None


def plan_streams(infos, primary, lines):
    """For each stream: the URL each line should use, and the stream's size."""
    plan = []
    picked = streams_of(infos[primary])
    others = {ln: {f.get("format_id"): f for f in streams_of(i)} for ln, i in infos.items() if ln != primary}
    for f in picked:
        entry = {"fmt": f, "urls": {}, "size": None, "info": None}
        if f.get("protocol") in ("https", "http") and f.get("url"):
            candidates = {primary: f}
            for ln in lines:
                if ln != primary:
                    # The line's own link for the same stream; otherwise try the primary's
                    # (fine where links aren't tied to an IP; the probe drops it if refused).
                    candidates[ln] = others.get(ln, {}).get(f["format_id"], f)
            for ln, cf in candidates.items():
                p = probe_line(cf["url"], ln, cf.get("http_headers") or {})
                if not p:
                    continue
                if entry["size"] is None:
                    entry["size"], entry["info"] = p["size"], p
                if p["size"] == entry["size"]:
                    entry["urls"][ln] = p["url"]
        plan.append(entry)
    return plan


def native_download(info_file, f, ip, out, offset, total, primary):
    """yt-dlp's own downloader for streams that come in fragments (HLS/DASH)."""
    cmd = [tools.tool_path("yt-dlp"), "--load-info-json", info_file, "-f", f["format_id"],
           "-o", out, "--source-address", ip, "-N", "8", "--newline", "--no-warnings",
           "--retries", "10", "--fragment-retries", "10", "--no-part",
           "--progress-template", "download:DL %(progress.downloaded_bytes)s "
           "%(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for line in p.stdout:
            m = re.match(r"DL (\S+) (\S+) (\S+) (\S+)", line.strip())
            if not m:
                continue
            num = lambda v: float(v) if v not in ("NA", "None") else 0
            got, size = num(m.group(1)), num(m.group(2)) or num(m.group(3))
            emit("progress", done=int(offset + got), size=int(total or offset + size),
                 speeds={primary: int(num(m.group(4)))}, received={primary: int(got)}, down=[])
        if p.wait() != 0:
            raise SiteError(friendly(p.stderr.read()))
    except KeyboardInterrupt:
        p.terminate()
        raise
    return os.path.getsize(out) if os.path.exists(out) else 0


def ffmpeg(args, what):
    exe = tools.tool_path("ffmpeg")
    if not exe:
        raise SiteError("ffmpeg isn't installed, so %s isn't possible." % what)
    r = subprocess.run([exe, "-hide_banner", "-loglevel", "error", "-y", "-nostdin"] + args,
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SiteError("ffmpeg couldn't %s: %s" % (what, (r.stderr.strip().splitlines() or ["?"])[-1]))


def probe_codecs(path):
    """Codec names, height and duration of a media file (ffprobe)."""
    exe = tools.tool_path("ffprobe")
    if not exe:
        raise SiteError("ffprobe isn't installed (it comes with ffmpeg).")
    r = subprocess.run([exe, "-v", "error", "-show_entries", "stream=codec_type,codec_name,height,pix_fmt:"
                        "stream_disposition=attached_pic:format=duration", "-of", "json", path],
                       capture_output=True, text=True)
    d = json.loads(r.stdout or "{}")
    streams = d.get("streams", [])
    v = next((x for x in streams if x.get("codec_type") == "video"
              and not x.get("disposition", {}).get("attached_pic")), None)
    a = next((x for x in streams if x.get("codec_type") == "audio"), None)
    return {"v": v and v.get("codec_name"), "height": (v or {}).get("height") or 0,
            "pix": (v or {}).get("pix_fmt") or "", "a": a and a.get("codec_name"),
            "duration": float(d.get("format", {}).get("duration") or 0)}


_ENCODERS = None


def has_encoder(name):
    global _ENCODERS
    if _ENCODERS is None:
        r = subprocess.run([tools.tool_path("ffmpeg"), "-hide_banner", "-encoders"], capture_output=True, text=True)
        _ENCODERS = r.stdout
    return " %s " % name in _ENCODERS


def compat_args(c):
    """ffmpeg codec options that make a file open in QuickTime and Premiere.
    Already-friendly streams are copied untouched; VP9/AV1 go through the Mac's hardware
    encoder (H.264 up to 1080p, HEVC above), so the CPU barely notices."""
    if c["v"] in EDIT_VIDEO:
        v = ["-c:v", "copy"] + (["-tag:v", "hvc1"] if c["v"] == "hevc" else [])
    elif c["v"] is None:
        v = []
    elif c["height"] > 1080:
        v = ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1"]
    else:
        v = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]   # H.264 has no 10-bit here
    if c["a"] in EDIT_AUDIO or c["a"] is None:
        a = ["-c:a", "copy"] if c["a"] else []
    else:
        a = ["-c:a", "aac_at" if has_encoder("aac_at") else "aac", "-b:a", "192k"]
    return v, a


def needs_convert(c):
    return (c["v"] is not None and c["v"] not in EDIT_VIDEO) or (c["a"] is not None and c["a"] not in EDIT_AUDIO)


def ffmpeg_progress(args, duration, label, what):
    """ffmpeg showing a percentage on the download ("Converting for Mac & Premiere… 42%")."""
    exe = tools.tool_path("ffmpeg")
    if not exe:
        raise SiteError("ffmpeg isn't installed, so %s isn't possible." % what)
    p = subprocess.Popen([exe, "-hide_banner", "-loglevel", "error", "-y", "-nostdin", "-nostats",
                          "-progress", "pipe:1"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    last = 0.0
    try:
        for line in p.stdout:
            k, _, v = line.strip().partition("=")
            if k == "out_time_us" and v.isdigit() and duration > 0 and time.time() - last > 0.5:
                pct = min(99, int(int(v) / 1e6 / duration * 100))
                emit("stage", message="%s %d%%" % (label, pct))
                emit("progress", done=pct, size=100, speeds={}, received={}, down=[])
                last = time.time()
        err = p.stderr.read()
        if p.wait() != 0:
            raise SiteError("ffmpeg couldn't %s: %s" % (what, (err.strip().splitlines() or ["?"])[-1]))
    except KeyboardInterrupt:
        p.terminate()
        raise


def convert_file(src):
    """Makes an existing video open in QuickTime/Premiere. Writes a hidden temp file next to
    it; the app moves the original to the Trash and puts the new file in its place."""
    if not os.path.isfile(src):
        raise SiteError("The file isn't there any more.")
    c = probe_codecs(src)
    if c["v"] is None and c["a"] is None:
        raise SiteError("ffmpeg can't read this file.")
    base, ext = os.path.splitext(src)
    target = base + ".mp4"
    if not needs_convert(c) and ext.lower() in (".mp4", ".mov", ".m4v"):
        emit("done", path=src, original=src, target=src, size=os.path.getsize(src), already=True)
        return
    tmp = os.path.join(os.path.dirname(src), ".dualdl-convert-%s.mp4"
                       % hashlib.sha1(src.encode()).hexdigest()[:10])
    emit("work", path=tmp)
    emit("info", name=os.path.basename(target), path=src, size=None, ranges=False, resumed=0,
         quality="%dp" % c["height"] if c["height"] else "")
    vargs, aargs = compat_args(c)
    hw = ["-hwaccel", "videotoolbox"] if c["v"] and c["v"] not in EDIT_VIDEO else []
    ffmpeg_progress(hw + ["-i", src, "-map", "0:v:0?", "-map", "0:a:0?", "-map_metadata", "0"] + vargs + aargs
                    + ["-movflags", "+faststart", tmp], c["duration"], "Converting for Mac & Premiere…",
                    "convert the video")
    check_output(tmp, c)
    emit("done", path=tmp, original=src, target=target, size=os.path.getsize(tmp))


def check_output(path, src):
    """The new file must be friendly and as long as the source, or nothing gets replaced."""
    c = probe_codecs(path)
    if needs_convert(c) or abs(c["duration"] - src["duration"]) > max(1.0, src["duration"] * 0.02):
        try:
            os.remove(path)
        except OSError:
            pass
        raise SiteError("The converted file didn't check out (%s, %.1fs of %.1fs); the original is untouched."
                        % (c["v"], c["duration"], src["duration"]))


def clean_name(title):
    name = re.sub(r'[\x00-\x1f/\\:*?"<>|]+', " ", title).strip().strip(".")
    return re.sub(r"\s+", " ", name)[:150] or "video"


def meta_args(info):
    out = ["-metadata", "title=" + (info.get("title") or "")]
    if info.get("uploader"):
        out += ["-metadata", "artist=" + info["uploader"]]
    if info.get("webpage_url"):
        out += ["-metadata", "comment=" + info["webpage_url"]]
    return out


def download(url, folder, mode, quality, audio, lines, ips, labels, per_iface, cookies, keep_codec=False):
    fmt, sort = choose(mode, quality, audio)
    work = os.path.join(folder, ".dualdl-" + hashlib.sha1(("%s|%s|%s|%s" % (url, mode, quality, audio))
                                                          .encode()).hexdigest()[:12])
    os.makedirs(work, exist_ok=True)
    emit("work", path=work)              # so a cancel at any point can clean it up
    emit("stage", message="Reading the page on every line…")
    infos, primary = read_all(url, lines, ips, cookies, fmt, sort)
    info = infos[primary]
    title = info.get("title") or "video"
    info_file = os.path.join(work, "info.json")
    with open(info_file, "w") as f:
        json.dump(info, f)

    emit("stage", message="Finding the fastest links…")
    plan = plan_streams(infos, primary, lines)
    sizes = [e["size"] or human_size(info, e["fmt"]) for e in plan]
    total = sum(sizes) or None
    if mode == "audio":
        ext = "mp3" if audio == "mp3" else ("m4a" if plan[0]["fmt"].get("ext") == "m4a" else "opus")
    else:
        v = next((e["fmt"] for e in plan if e["fmt"].get("vcodec") not in (None, "none")), plan[0]["fmt"])
        friendly_container = (v.get("vcodec") or "").split(".")[0] in MP4_VIDEO
        ext = "mp4" if friendly_container or not keep_codec else "mkv"
    final = dualdl.unique_path(folder, clean_name(title) + "." + ext)
    height = max((e["fmt"].get("height") or 0) for e in plan)
    emit("info", name=os.path.basename(final), path=final, size=total, ranges=True, resumed=0, work=work,
         title=title, thumbnail=info.get("thumbnail") or "", duration=info.get("duration") or 0,
         quality=("MP3" if ext == "mp3" else "Audio") if mode == "audio" else ("%dp" % height if height else ""))

    files, offset, received = [], 0, {}
    t0 = time.time()
    for n, e in enumerate(plan):
        f = e["fmt"]
        out = os.path.join(work, "stream%d.%s" % (n, f.get("ext") or "bin"))
        if os.path.exists(out) and e["size"] and os.path.getsize(out) == e["size"]:
            pass                                   # finished on an earlier run
        elif e["urls"]:
            dualdl.HEADERS.clear()
            dualdl.HEADERS.update(f.get("http_headers") or {})
            dualdl.HEADERS["Accept-Encoding"] = "identity"
            job_info = dict(e["info"], urls=e["urls"], cookies={})
            dualdl.PROGRESS_OFFSET, dualdl.PROGRESS_TOTAL = offset, total
            dualdl.PROGRESS_RECEIVED = dict(received)
            job = dualdl.Job(job_info, list(e["urls"]), per_iface, out + ".dualdl-part", out + ".dualdl.json")
            job.run(labels)
            os.close(job.fd)
            if job.error or not job.finished():
                raise SiteError(job.error or "Download stopped")
            os.replace(out + ".dualdl-part", out)
            os.remove(out + ".dualdl.json")
            for k, v in job.received.items():
                received[k] = received.get(k, 0) + v
        else:
            got = native_download(info_file, f, ips[primary], out, offset, total, primary)
            received[primary] = received.get(primary, 0) + got
        offset += os.path.getsize(out)
        files.append((out, f))

    tmp = os.path.join(work, "out." + ext)
    if mode == "audio" and ext == "mp3":
        emit("stage", message="Making the MP3…")
        args = ["-i", files[0][0]]
        cover = fetch_cover(info, work)
        if cover:
            args += ["-i", cover, "-map", "0:a:0", "-map", "1:v:0", "-c:v", "mjpeg",
                     "-vf", "scale='min(800,iw)':-2", "-disposition:v:0", "attached_pic"]
        else:
            args += ["-map", "0:a:0"]
        ffmpeg(args + ["-c:a", "libmp3lame", "-q:a", "0", "-id3v2_version", "3"] + meta_args(info) + [tmp],
               "make the MP3")
    else:
        # Video: join video + audio, and unless asked to keep the site's codecs, make it open
        # in QuickTime and Premiere (VP9/AV1 → H.264/HEVC on the hardware encoder) in the same pass.
        vi = 0 if files[0][1].get("vcodec") not in (None, "none") else min(1, len(files) - 1)
        inputs = [files[vi][0]] + ([files[1 - vi][0]] if len(files) == 2 else [])
        maps = ["-map", "0:v:0?"] + (["-map", "1:a:0"] if len(files) == 2 else ["-map", "0:a:0?"])
        vc, ac = probe_codecs(inputs[0]), probe_codecs(inputs[-1])
        c = {"v": vc["v"], "height": vc["height"], "pix": vc["pix"], "a": ac["a"],
             "duration": max(vc["duration"], ac["duration"]) or info.get("duration") or 0}
        args = sum((["-i", f] for f in inputs), [])
        if mode == "video" and not keep_codec and needs_convert(c):
            vargs, aargs = compat_args(c)
            hw = ["-hwaccel", "videotoolbox"] if c["v"] not in EDIT_VIDEO else []
            ffmpeg_progress(hw + args + maps + vargs + aargs + meta_args(info) + ["-movflags", "+faststart", tmp],
                            c["duration"], "Converting for Mac & Premiere…", "convert the video")
            check_output(tmp, c)
        else:
            emit("stage", message="Joining video and audio…" if len(files) == 2 else "Finishing…")
            tag = ["-tag:v", "hvc1"] if c["v"] == "hevc" and ext == "mp4" else []
            ffmpeg(args + maps + ["-c", "copy"] + tag + meta_args(info) + [tmp], "join video and audio")
    os.replace(tmp, final)
    shutil.rmtree(work, ignore_errors=True)
    emit("done", path=final, elapsed=time.time() - t0, size=os.path.getsize(final), received=received)


def fetch_cover(info, work):
    url = info.get("thumbnail")
    if not url:
        return None
    path = os.path.join(work, "cover")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "DualDL"})
        with urllib.request.urlopen(req, timeout=15) as r, open(path, "wb") as f:
            f.write(r.read(8 << 20))
        return path
    except (OSError, ValueError):
        return None


def interrupt(*_):
    raise KeyboardInterrupt


def main():
    ap = argparse.ArgumentParser(description="Video/audio download over every line")
    ap.add_argument("url", nargs="?", help="video page link (YouTube or any site yt-dlp supports)")
    ap.add_argument("--convert", metavar="FILE", help="make an existing video open in QuickTime/Premiere")
    ap.add_argument("--keep-codec", action="store_true", help="keep VP9/AV1 as the site sends them")
    ap.add_argument("-o", "--out", default=os.path.expanduser("~/Downloads"), help="folder to save into")
    ap.add_argument("--mode", choices=["video", "audio"], default="video", help="a video file, or audio only")
    ap.add_argument("--quality", default="best", help="best, compatible, or a height like 1080")
    ap.add_argument("--audio", choices=["mp3", "original"], default="mp3",
                    help="audio mode: MP3 with cover art, or the site's own audio untouched")
    ap.add_argument("-n", "--connections", type=int, default=4, help="connections per line")
    ap.add_argument("-i", "--interfaces", help="only these interfaces, e.g. en0,en1")
    ap.add_argument("--cookies", help="Netscape cookies.txt (from the Chrome extension)")
    ap.add_argument("--browser-cookies", choices=["chrome", "safari", "firefox", "brave", "edge"],
                    help="use this browser's login when there's no cookies file")
    ap.add_argument("--limit", type=float, default=0, help="speed limit in MB/s (0 = none)")
    ap.add_argument("--preview", action="store_true", help="print title, thumbnail and qualities, then stop")
    ap.add_argument("--json", action="store_true", help="JSON lines output (always on; kept for symmetry)")
    args = ap.parse_args()
    dualdl.JSON_MODE = True
    signal.signal(signal.SIGTERM, interrupt)
    dualdl.LIMITER.rate = args.limit * 1024 * 1024
    global BROWSER
    BROWSER = args.browser_cookies
    try:
        if args.convert:
            convert_file(os.path.abspath(args.convert))
            return
        if not args.url:
            raise SiteError("No link given")
        if not tools.tool_path("yt-dlp"):
            raise SiteError("yt-dlp isn't installed yet. Open DualDL Settings → Video tools → Install.")
        found = dualdl.interface_list()
        ips = {l["iface"]: l["ip"] for l in found}
        lines = [i for i in (args.interfaces.split(",") if args.interfaces else ips) if i in ips]
        if not lines:
            raise SiteError("No active network line")
        hw = dualdl.hardware_names()
        labels = {i: hw.get(i, i).replace("Wi-Fi", "WiFi") for i in lines}
        emit("lines", lines=[{"iface": i, "label": labels[i]} for i in lines])
        if args.preview:
            preview(args.url, lines, ips, args.cookies)
        else:
            os.makedirs(args.out, exist_ok=True)
            download(args.url, args.out, args.mode, args.quality, args.audio, lines, ips, labels,
                     args.connections, args.cookies, args.keep_codec)
    except SiteError as e:
        emit("error", message=str(e))
        sys.exit(1)
    except KeyboardInterrupt:
        emit("paused")
        sys.stdout.flush()
        os._exit(130)
    except Exception as e:
        emit("error", message="%s: %s" % (type(e).__name__, e))
        sys.exit(1)


if __name__ == "__main__":
    main()
