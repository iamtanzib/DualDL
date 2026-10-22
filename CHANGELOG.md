# Changelog

## 1.0.0 — first public release

- Downloads split into 4 MB ranges over every network line at once (Ethernet + Wi-Fi), with work stealing, resume after pause/quit/crash, and line failover.
- Line checks: ISP and public IP per line, "same connection" detection, Wi-Fi name, band and signal.
- Google Drive: file links, large-file confirm pages, shared **folder links** (with subfolders), skip files already downloaded.
- Survives trouble: fresh links when they expire, waits out busy servers (`Retry-After`), automatic retries (1 → 3 → 10 → 30 → 60 min).
- Auto-unzip of Drive "Download all" pieces into one folder, and of split archives once complete.
- Video & audio via yt-dlp (+ Deno for YouTube's best formats): previews, quality presets, MP3 with cover art, each line fetching its own stream links, page reading on all lines in parallel.
- Mac/Premiere-ready output: VP9/AV1 → H.264/HEVC on the hardware encoder; convert existing files from the list or File menu.
- Chrome extension: download capture, right-click menus, video buttons, Drive folder button, optional login hand-off, Turbo browsing.
- Turbo browsing: local HTTPS proxy that keeps each site on one line, uses the fastest line first and spills over when it's full.
- Settings in tabs (General, Network, Video, Chrome), speed limit, keep-awake, notifications.
- Test suite with 150+ checks, including a misbehaving local server and screenshots of every screen.
