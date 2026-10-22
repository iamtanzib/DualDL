# Customizing DualDL

Everything is plain source. Change it, run `tests/run.sh`, then `./build.sh`. Below is where each knob lives.

## Download behaviour (`engine/dualdl.py`, top of the file)

| Constant | Default | What it changes |
|---|---|---|
| `CHUNK` | 4 MB | Size of each ranged request. Bigger = fewer requests; smaller = finer work stealing. |
| `BLOCK` | 256 KB | Read size inside a chunk. |
| `TIMEOUT` | 20 s | A connection with no data for this long is dropped and retried. |
| `STALL_LIMIT` | 120 s | No data on any line for this long → fetch a fresh link. |
| `REFRESH_AT` | 6 | Refused requests in a row before fetching a fresh link. |
| `MAX_REFRESHES` | 4 | Fresh links in a row that still fail before handing back to the app. |
| `SKIP_PREFIXES` | `lo, utun, bridge, …` | Interfaces never used as "lines" (VPN tunnels, bridges…). |

Connections per line are a setting (**Settings → General**, 1–8). Google Drive is capped at 3 per line in `download()` (`per_iface = min(per_iface, 3)`) because Drive limits sooner with many parallel requests.

## Automatic retries (`mac/Sources/Manager.swift`)

`retryDelays` (default `60,180,600,1800,3600` seconds). The count starts over whenever a retry made real progress, so long downloads can keep going for hours.

## Which lines and ISPs

- Line checks ask `https://ipinfo.io/json` through each line (`check_line()` in `dualdl.py`), falling back to `api.ipify.org`. Swap in any service that returns your public IP.
- Lines with the same public IP are treated as one connection (`check_lines()`), and only one is used.

## Video (`engine/video.py`)

- **Format choice:** `choose()` builds yt-dlp's `-f`/`-S` strings. The default is highest resolution first, preferring H.264/AAC at equal resolution.
- **Mac/Premiere conversion:** `compat_args()` decides what to re-encode: H.264 up to 1080p, HEVC (`hvc1`) above, AAC audio, quality `-q:v 65` on VideoToolbox. Change the encoder or quality there. `EDIT_VIDEO`/`EDIT_AUDIO` list what's left untouched.
- **Turn conversion off:** **Settings → Video → Make videos open in QuickTime and Premiere**.
- **Recognised video sites** (shows the video card automatically): `isVideoURL()` in `mac/Sources/Preview.swift`, `VIDEO_SITES` in `extension/background.js` and `VIDEO_HOSTS` in `extension/popup.js`. Any other site still works through the 🎞 button.

## Turbo browsing (`engine/turbo.py`)

- `FAMILIES`: domains of one company that must share a line (logins and IP-tied video links stay valid). Add your own.
- `HEAVY`: families that always use the fastest line.
- `STICKY`: how long a site keeps its line after its last connection.
- Spill-over rule in `Lines.pick()`: the fastest line takes everything until it reaches 80 % of what it has shown it can do.
- The PAC script Chrome uses is `turboPac()` in `extension/background.js` (which hosts go direct).

## Unzip (`engine/unzip.py`)

- `DRIVE_PART`: the pattern for Drive's "Download all" pieces.
- Existing files with the same size are skipped; others are kept side by side as `name (1).ext` (`free_name()`).

## Look and feel

- **Line colors and icons:** `lineColor()` / `lineSymbol()` in `mac/Sources/Views.swift`.
- **App icon:** drawn in code by `mac/make_icon.swift` (gradient colours, the two streams, the arrow). `build.sh` regenerates the `.icns` and the extension icons from it.
- **Window size:** `.frame(minWidth:minHeight:)` and `.defaultSize` in `mac/Sources/App.swift`.

## Identity and ports

- **Bundle id / name:** `mac/Info.plist` (`CFBundleIdentifier`, `CFBundleName`). Changing the id gives the app fresh settings and permissions.
- **Link server port:** `LinkServer.port` (`mac/Sources/Server.swift`) **and** `API` in `extension/background.js`.
- **Turbo port:** `TurboManager.port` (`mac/Sources/Turbo.swift`); the extension learns it from the app's ping.
- **URL scheme:** `dualdl://` in `Info.plist` (`dualdl://add?url=…` fills the link box).

## Building for Intel Macs

`build.sh` targets `arm64-apple-macos14.0`. For Intel, change the `-target` to `x86_64-apple-macos14.0` (or build both and `lipo` them). Note that `tools.py` downloads Deno's `aarch64` build; switch to `deno-x86_64-apple-darwin.zip` too.
