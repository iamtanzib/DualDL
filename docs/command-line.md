# Command line

The engines work without the app. They need only the macOS system Python (`/usr/bin/python3`). Add `--json` to get the machine-readable events the app uses ([event reference](architecture.md#json-events-engine--app)).

## `engine/dualdl.py`: download a file over every line

```bash
python3 engine/dualdl.py "https://example.com/big.iso"
python3 engine/dualdl.py -o ~/Desktop "https://drive.google.com/file/d/FILE_ID/view"
python3 engine/dualdl.py -n 6 -i en0,en1 --limit 5 "https://example.com/big.iso"
```

| Option | Meaning |
|---|---|
| `-o, --out DIR` | Folder to save into (default `~/Downloads`). |
| `-n, --connections N` | Connections per line (default 4; Google Drive uses at most 3). |
| `-i, --interfaces en0,en1` | Only these interfaces. |
| `--limit MB` | Speed cap in MB/s. |
| `--name NAME` | Save under this name. |
| `--cookie "a=b; c=d"` | Cookie header for private files (or set `DUALDL_COOKIE` to keep it out of `ps`). |
| `--referer URL` | Referer header. |
| `--skip-existing` | Finish at once if the file is already there in full. |
| `--list-interfaces` | Print the active lines. |
| `--check-lines` | Each line's public IP and ISP; flags lines that share one connection. |
| `--list-folder URL` | List every file in a shared Google Drive folder (with subfolders). |

Press **Ctrl-C** to stop; run the same command again to resume.

## `engine/video.py`: video and audio (needs yt-dlp; ffmpeg for joining/MP3)

```bash
python3 engine/video.py "https://www.youtube.com/watch?v=VIDEO_ID"                # best quality
python3 engine/video.py --quality 1080 "https://…"                                # up to 1080p
python3 engine/video.py --quality compatible "https://…"                          # H.264, plays everywhere
python3 engine/video.py --mode audio "https://…"                                  # MP3 with cover art
python3 engine/video.py --mode audio --audio original "https://…"                 # the site's audio, untouched
python3 engine/video.py --preview "https://…"                                     # title, thumbnail, qualities
python3 engine/video.py --convert ~/Movies/clip.webm                              # make it QuickTime/Premiere-ready
```

| Option | Meaning |
|---|---|
| `--mode video\|audio` | A video file or audio only. |
| `--quality best\|compatible\|HEIGHT` | `best` = highest resolution; `compatible` = H.264 first; a number caps the height. |
| `--audio mp3\|original` | For audio mode. |
| `--keep-codec` | Don't convert VP9/AV1; keep what the site sends. |
| `--cookies FILE` | Netscape `cookies.txt` (signed-in downloads, "not a bot" checks). |
| `--browser-cookies chrome` | Let yt-dlp read a browser's cookies itself (macOS may block this for Chrome). |
| `-n`, `-i`, `--limit`, `-o` | As in `dualdl.py`. |

yt-dlp and Deno are looked up in `~/Library/Application Support/DualDL/tools` (install them with `python3 engine/tools.py --install` or from the app); ffmpeg in that folder, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.

## `engine/unzip.py`

```bash
python3 engine/unzip.py "Holiday Videos -20260101T120000Z-1-001.zip"
python3 engine/unzip.py big.zip.003          # unzips once .001 … .003 are all present
```

## `engine/turbo.py`

```bash
python3 engine/turbo.py --port 51978 -i en0,en1
curl -x http://127.0.0.1:51978 https://api.ipify.org      # which line did this site get?
```

Only HTTPS `CONNECT` tunnels are proxied; private/local addresses are refused.

## `engine/tools.py`

```bash
python3 engine/tools.py --status      # versions and paths
python3 engine/tools.py --install     # install or update yt-dlp and Deno (SHA-256 checked)
```
