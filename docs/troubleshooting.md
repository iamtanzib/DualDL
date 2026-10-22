# Troubleshooting

### It's not faster than before
- Both lines must be **different internet connections**. The header shows each line's ISP; **"Same connection"** means both reach the internet through one provider/router, so there's nothing to add up. Use Wi-Fi from a different provider or a phone hotspot.
- The total can't beat the two lines together. `python3 engine/dualdl.py --check-lines` and a quick single-line test (`curl --interface en0 …`) show what each line can do.
- Some servers cap each connection or refuse ranged downloads; then one line does the work.

### "Google Drive's download limit for this file is used up"
Drive limits how often a public file can be downloaded. It resets within 24 hours and DualDL retries on its own. Faster: open the file in Drive → **Make a copy**, then download your copy (from Chrome, so your login comes along).

### A Drive folder link fails
The folder must be shared as **Anyone with the link**, or send it from Chrome with the extension (your login comes along). Google Docs/Sheets inside a folder can't be downloaded as files.

### "This zip has a password"
Click **Open** on the row (or double-click the zip in Finder) and type the password; DualDL can't unzip password-protected archives itself.

### YouTube: "confirm you're not a bot"
YouTube flags IPs that fetch a lot without being signed in. Turn on **Settings → Chrome → Use my Chrome login** (keep Chrome open with the extension), or send the video from Chrome. DualDL also tries every line, since each has its own IP.

### The video plays only audio / Premiere won't open it
That's VP9 or AV1. Keep **Settings → Video → Make videos open in QuickTime and Premiere** on, or right-click an existing file → **Convert for Mac & Premiere**.

### Video tools fail to install
They come from GitHub; check your connection and try **Settings → Video → Update Now**. ffmpeg isn't installed by DualDL: get it from [martin-riedl.de](https://ffmpeg.martin-riedl.de) or `brew install ffmpeg`.

### The Chrome extension says the app isn't running
Open DualDL. It listens on `127.0.0.1:51977`; if another program uses that port, the header shows **Chrome link off**.

### Turbo says another extension controls Chrome's proxy
A VPN or proxy extension is in charge of Chrome's proxy setting. Turn it off if you want Turbo; DualDL won't override it.

### Wi-Fi shows "WiFi" instead of the network name
Allow Location for DualDL (**Settings → Network → Show Wi-Fi Name…**). macOS only shares Wi-Fi names with apps that have Location access.

### Browsing is slow in general
**Settings → Network → Wi-Fi check** shows band, signal and link speed. 2.4 GHz with a weak signal is a common culprit; **Look for a Faster Band** finds your router's 5 GHz network.

### Starting fresh
Quit DualDL, then remove `~/Library/Application Support/DualDL/downloads.json` (the list) and/or run `defaults delete app.dualdl.mac` (settings). Downloaded files are never touched.
