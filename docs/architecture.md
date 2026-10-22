# Architecture

DualDL is two halves that talk over JSON lines:

```
mac/Sources/        the app (SwiftUI): list, UI, settings, local link server
engine/             the engines (Python 3, standard library only): all network work
extension/          the Chrome extension (Manifest V3)
tests/              the test suite (see README → Tests)
```

## The app (`mac/Sources`)

| File | What it does |
|---|---|
| `App.swift` | App entry, window, Settings scene, menu commands, Dock reopen. |
| `Manager.swift` | `DownloadManager`: the download list, queue, one engine process per job, unzip queue, automatic retries, Drive folder expansion, line checks, sleep prevention, persistence. |
| `Engine.swift` | Starts `python3 <script>.py …` and turns its JSON lines into events on the main actor. |
| `Server.swift` | Tiny HTTP server on `127.0.0.1:51977` for the Chrome extension. |
| `Turbo.swift` | Starts/stops the Turbo proxy (`turbo.py`) and tracks its stats. |
| `Tools.swift` | Installs, checks and updates yt-dlp, Deno and finds ffmpeg (`tools.py`). |
| `Preview.swift` | Recognises video links and reads the preview (title, thumbnail, qualities). |
| `WiFi.swift` | Wi-Fi network name, band, signal and the "faster band" scan (CoreWLAN). |
| `Views.swift` | Everything you see: main window, rows, video card, header pills, Settings tabs. |

The app is compiled with `swiftc` directly (no Xcode project) by `build.sh`.

## The engines (`engine/`)

| Script | Job |
|---|---|
| `dualdl.py` | The download engine: probe, 4 MB ranged chunks over every line, resume, fresh links, Drive confirm pages and folder listing, line checks. |
| `video.py` | Video/audio: yt-dlp reads the page on every line in parallel, `dualdl.py`'s `Job` downloads the streams, ffmpeg joins/converts. Also `--convert` for existing files. |
| `unzip.py` | Unzips Drive pieces into one folder, split archives once complete; refuses entries that try to leave the folder. |
| `turbo.py` | Turbo browsing: an asyncio HTTPS CONNECT proxy that assigns each site to a line. |
| `tools.py` | Finds/installs yt-dlp (unpacked build), Deno, ffmpeg with SHA-256 checks. |

### How one download works

1. **Probe:** one `Range: bytes=0-0` request (following redirects and Google Drive's confirm page) gives the final URL, size and file name.
2. **Plan:** the file is split into 4 MB chunks in a queue. Each line runs *N* worker threads (4 by default, 3 for Google Drive).
3. **Pinned sockets:** every worker's socket is bound to its interface with `setsockopt(IPPROTO_IP, IP_BOUND_IF, ifindex)`, so traffic leaves through that line regardless of the default route.
4. **Work stealing:** workers keep taking the next missing chunk, so the faster line naturally does more.
5. **Writing:** chunks are written in place with `pwrite` into `<file>.dualdl-part`; completed chunk numbers are saved to `<file>.dualdl.json` every 2 s. A chunk only counts once it is complete, so resuming after a pause, quit or crash is always safe.
6. **Trouble:** a line that keeps failing backs off (up to 30 s) and the other line takes its chunks. If the server keeps refusing (expired link, 403/429) or no data arrives for 120 s, the engine fetches a **fresh link** with a new probe and carries on. Only after several fresh links fail does it stop with `retry: true`, and the app schedules an automatic retry.
7. **Finish:** the part file is renamed to its real name.

### JSON events (engine → app)

Each line on stdout is one JSON object with an `event` field:

| Event | Fields | Meaning |
|---|---|---|
| `lines` | `lines[{iface,label}]` | Which lines this job uses. |
| `info` | `name, path, size, resumed, …` | The real file name/size are known. |
| `progress` | `done, size, speeds{iface:B/s}, received{iface:bytes}, down[]` | Twice a second. |
| `stage` | `message` | "Reading the page…", "Converting for Mac & Premiere… 42%". |
| `log` | `message` | Informational ("Getting a fresh download link…"). |
| `work` | `path` | A temp folder/file to clean up if the job is cancelled. |
| `done` | `path, size, elapsed, received, skipped?` | Finished. |
| `error` | `message, retry` | Stopped; `retry: true` means trying later may work. |
| `paused` | | Stopped by request; progress is saved. |

Other events: `folder` (Drive folder listing), `preview` (video info), `stats`/`probe`/`ready` (Turbo), `status`/`installed` (tools), `waiting` (unzip of incomplete split archives).

## Storage

| Where | What |
|---|---|
| `~/Library/Application Support/DualDL/downloads.json` | The list (read field by field, so updates never make it unreadable; unreadable entries are skipped and the original is kept as `downloads.unreadable-*.json`). |
| `~/Library/Application Support/DualDL/tools/` | yt-dlp (unpacked build) and Deno. |
| `~/Library/Caches/DualDL/info/` | Video preview info, reused for 20 minutes so a download doesn't read the page twice. |
| `~/Library/Caches/DualDL/cookies/` | Temporary `0600` cookie files while yt-dlp runs; wiped at launch. |
| next to each download | `*.dualdl-part`, `*.dualdl.json`, `.dualdl-*` (video work folders): removed when done or cancelled. |
| `defaults read app.dualdl.mac` | Settings. |

## Ports

| Port | Who listens | Used by |
|---|---|---|
| `127.0.0.1:51977` | the app | the Chrome extension (requires header `X-DualDL: 1`) |
| `127.0.0.1:51978` | `turbo.py` | Chrome, through the extension's PAC script, while Turbo is on |

## Test hooks (environment variables)

These exist so the test suite never touches a real install:

| Variable | Effect |
|---|---|
| `DUALDL_HOME` | Store the list, caches and "Trash" under this folder instead of `~/Library`. |
| `DUALDL_PORT`, `DUALDL_TURBO_PORT` | Other ports for the link server and Turbo. |
| `DUALDL_DRIVE_BASE` | Where Drive folder pages and file links point (a local server in tests). |
| `DUALDL_RETRY_DELAYS` | Automatic retry delays in seconds, e.g. `3,3,3`. |
| `DUALDL_SNAP_OUT`, `DUALDL_ICON` | Output folder and app icon for the screenshot renderer. |
