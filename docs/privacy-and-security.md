# Privacy & security

DualDL has no accounts, no servers of its own and no telemetry. Everything happens on your Mac.

## What goes over the network

| When | To | Why |
|---|---|---|
| You download something | That site | Obviously. |
| App start, every 5 min, network changes | `ipinfo.io` (fallback `api.ipify.org`), once per line | Each line's public IP and ISP, to tell whether they're really different connections. |
| Installing/updating video tools | `api.github.com`, `github.com` | yt-dlp and Deno releases (SHA-256 verified before install). Weekly update check unless you turn it off. |
| Turbo browsing starts (and every 30 min while you browse heavily) | `speed.cloudflare.com` | A 2 MB download per line to measure each line's speed. |
| Video previews/downloads | The video site, through yt-dlp | Reading the page. |

## Your logins (cookies)

- The Chrome extension only sends cookies to the **local** app (`127.0.0.1`).
- **Plain downloads:** cookies for that site go with the request, and are only ever sent back to the same host, even if the server redirects elsewhere.
- **"Use my Chrome login"** (off by default): while it's on, the extension hands over cookies for a fixed list of video sites. The app keeps them **in memory**; they touch disk only as a private (`0600`) temp file while yt-dlp runs, deleted right after (and the folder is wiped at every launch). Turning the setting off forgets them at once.

## The local link server

The app listens on `127.0.0.1:51977` (loopback only; nothing on your network can reach it). To stop web pages from talking to it:

- every request must carry the header `X-DualDL: 1`; a web page can't add a custom header to a cross-site request without a CORS preflight,
- preflights (`OPTIONS`) are refused,
- requests whose `Origin` isn't `chrome-extension://…` are refused.

`dualdl://add?url=…` only fills the link box; you still press Download.

## Turbo browsing

- Listens on `127.0.0.1:51978` only, and only relays HTTPS `CONNECT` tunnels. It can't see inside them: your traffic stays end-to-end encrypted.
- Tunnels to private/local addresses are refused.
- Chrome's PAC script sends local addresses, plain `http://` and `.local` names directly, and falls back to **DIRECT** if the app isn't running, so closing DualDL never breaks browsing.
- If another extension (e.g. a VPN) controls Chrome's proxy, Turbo leaves it alone.

## Files

- Unzipping never writes outside the target folder (entries with `..` or absolute paths are skipped) and never overwrites a different file.
- "Convert for Mac & Premiere" verifies the new file (codecs and duration) before the original goes to the **Trash** (recoverable).
- Cancel removes only DualDL's own partial files (`*.dualdl-part`, `*.dualdl.json`, `.dualdl-*`).

## Permissions macOS asks for

- **Location:** macOS only reveals Wi-Fi network names to apps with Location access. DualDL never reads your location.
- **Notifications:** download finished.
