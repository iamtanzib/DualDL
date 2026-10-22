// DualDL Grabber: hands Chrome downloads to the DualDL app (like FDM does).
// The app listens on 127.0.0.1:51977 and only answers requests with X-DualDL: 1.

const API = "http://127.0.0.1:51977";
const HEAD = { "X-DualDL": "1" };
const DEFAULTS = { enabled: true, minSizeMB: 2 };
const bypass = new Set(); // URLs we gave back to Chrome, so we don't grab them again

async function settings() {
  return { ...DEFAULTS, ...(await chrome.storage.local.get(Object.keys(DEFAULTS))) };
}

let lastPing = {};

async function ping() {
  try {
    const r = await fetch(`${API}/ping`, { headers: HEAD, signal: AbortSignal.timeout(800) });
    lastPing = r.ok ? await r.json() : {};
    return r.ok;
  } catch {
    lastPing = {};
    return false;
  }
}

// Cookies let the app open private files (your own Google Drive, logged-in sites).
// They only go to the local app, which sends them back to the same host only.
async function cookieHeader(url) {
  const urls = [url];
  if (/^https:\/\/(drive|docs)\.google\.com\//.test(url)) {
    urls.push("https://drive.usercontent.google.com/download");
  }
  const jar = new Map();
  for (const u of urls) {
    try {
      for (const c of await chrome.cookies.getAll({ url: u })) jar.set(c.name, c.value);
    } catch {}
  }
  return [...jar].map(([k, v]) => `${k}=${v}`).join("; ");
}

async function send(url, { referrer = "", filename = "" } = {}) {
  const body = { url, referer: referrer, filename, cookie: await cookieHeader(url) };
  const r = await fetch(`${API}/add`, {
    method: "POST",
    headers: { ...HEAD, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(3000),
  });
  if (!r.ok) throw new Error(`DualDL answered ${r.status}`);
}

// --- Video pages (yt-dlp in the app) ------------------------------------------

const VIDEO_SITES = [
  "youtube.com", "youtu.be", "vimeo.com", "facebook.com", "fb.watch", "instagram.com", "tiktok.com",
  "x.com", "twitter.com", "dailymotion.com", "twitch.tv", "reddit.com", "soundcloud.com", "bilibili.com",
  "bandcamp.com", "streamable.com", "ted.com",
];
const VIDEO_PATTERNS = VIDEO_SITES.flatMap((d) => [`*://${d}/*`, `*://*.${d}/*`]);

function isVideoPage(url) {
  try {
    const host = new URL(url).hostname.toLowerCase();
    return VIDEO_SITES.some((d) => host === d || host.endsWith("." + d));
  } catch {
    return false;
  }
}

// yt-dlp wants Netscape cookies.txt. Signed-in cookies avoid most "confirm you're not
// a bot", age and members-only errors. They only go to the local app.
async function netscapeCookies(url) {
  const host = new URL(url).hostname.replace(/^www\./, "");
  const domains = new Set([host.split(".").slice(-2).join(".")]);
  if (/(^|\.)(youtube\.com|youtu\.be)$/.test(host)) {
    domains.add("youtube.com");
    domains.add("google.com");
  }
  const lines = ["# Netscape HTTP Cookie File"];
  for (const domain of domains) {
    let list = [];
    try {
      list = await chrome.cookies.getAll({ domain });
    } catch {}
    for (const c of list) {
      const dom = c.hostOnly ? c.domain : c.domain.startsWith(".") ? c.domain : "." + c.domain;
      const expires = c.session ? 0 : Math.floor(c.expirationDate || 0);
      lines.push([dom, c.hostOnly ? "FALSE" : "TRUE", c.path, c.secure ? "TRUE" : "FALSE", expires,
                  c.name, c.value].join("\t"));
    }
  }
  return lines.join("\n") + "\n";
}

async function sendVideo(url, mode = "video", quality = "best", title = "") {
  if (!(await ping())) {
    notify("DualDL is not running", "Open the DualDL app, then try again.");
    flash("!", "#FF453A");
    return false;
  }
  try {
    const body = { kind: "video", url, mode, quality, audio: "mp3", title, cookiesTxt: await netscapeCookies(url) };
    const r = await fetch(`${API}/add`, {
      method: "POST",
      headers: { ...HEAD, "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(3000),
    });
    if (!r.ok) throw new Error(`DualDL answered ${r.status}`);
    flash("↓", "#0A84FF");
    return true;
  } catch (e) {
    notify("Could not send the video", String(e.message || e));
    flash("!", "#FF453A");
    return false;
  }
}

// --- "Use my Chrome login" (asked for by the app's setting) ---------------------
// macOS keeps other apps out of Chrome's cookie store, so the extension hands the
// app the login for video sites. Only while the app's setting is on, only to the
// local app, and the app keeps it in memory.

const LOGIN_SITES = ["youtube.com", "google.com", "instagram.com", "facebook.com", "tiktok.com", "x.com",
                     "twitter.com", "vimeo.com", "reddit.com", "twitch.tv"];

async function syncLogin() {
  if (!(await ping()) || !lastPing.wantCookies) return false;
  // The app says whether it already has a login; resend only if not, or every 30 minutes
  const { loginSentAt = 0 } = await chrome.storage.local.get("loginSentAt");
  if (lastPing.hasCookies && Date.now() - loginSentAt < 30 * 60 * 1000) return true;
  const parts = [];
  for (const site of LOGIN_SITES) parts.push((await netscapeCookies("https://" + site + "/")).split("\n").slice(1));
  const cookiesTxt = ["# Netscape HTTP Cookie File", ...new Set(parts.flat().filter(Boolean))].join("\n") + "\n";
  try {
    const r = await fetch(`${API}/cookies`, {
      method: "POST",
      headers: { ...HEAD, "Content-Type": "application/json" },
      body: JSON.stringify({ cookiesTxt }),
      signal: AbortSignal.timeout(3000),
    });
    if (r.ok) await chrome.storage.local.set({ loginSentAt: Date.now() });
    return r.ok;
  } catch {
    return false;
  }
}

chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create("sync-login", { periodInMinutes: 1 });
  syncTurbo().then(syncLogin);
});
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === "sync-login") syncTurbo().then(syncLogin);
  else if (a.name === "sync-login-soon") syncLogin();
});
chrome.cookies.onChanged.addListener(({ cookie }) => {
  const d = cookie.domain.replace(/^\./, "");
  if (LOGIN_SITES.some((s) => d === s || d.endsWith("." + s))) {
    chrome.alarms.create("sync-login-soon", { delayInMinutes: 0.5 }); // batch a burst of changes
  }
});

// --- Turbo browsing ------------------------------------------------------------
// While the app's Turbo is on, Chrome sends https sites through the app's local proxy,
// which spreads them over both lines. "; DIRECT" means: if the app isn't there, browse
// directly, so closing DualDL never breaks browsing. Local addresses always go direct.

function turboPac(port) {
  return `function FindProxyForURL(url, host) {
  if (isPlainHostName(host) || host == "localhost" || dnsDomainIs(host, ".local") || host.indexOf(":") >= 0 ||
      shExpMatch(host, "127.*") || shExpMatch(host, "10.*") || shExpMatch(host, "192.168.*") ||
      shExpMatch(host, "169.254.*") || /^172\\.(1[6-9]|2[0-9]|3[01])\\./.test(host))
    return "DIRECT";
  if (url.substring(0, 6) == "https:" || url.substring(0, 4) == "wss:")
    return "PROXY 127.0.0.1:${port}; DIRECT";
  return "DIRECT";
}`;
}

async function applyTurbo(on, port) {
  const cur = await chrome.proxy.settings.get({ incognito: false });
  if (cur.levelOfControl === "controlled_by_other_extensions" || cur.levelOfControl === "not_controllable") {
    return { applied: false, blocked: true };
  }
  if (on) {
    await chrome.proxy.settings.set({ value: { mode: "pac_script", pacScript: { data: turboPac(port) } }, scope: "regular" });
  } else if (cur.levelOfControl === "controlled_by_this_extension") {
    await chrome.proxy.settings.clear({ scope: "regular" });
  }
  return { applied: on, blocked: false };
}

async function syncTurbo() {
  const ok = await ping();
  const st = await applyTurbo(ok && lastPing.turbo === true, lastPing.turboPort || 51978);
  if (ok) {
    try {
      await fetch(`${API}/ping?turbo=${st.applied ? 1 : 0}&blocked=${st.blocked ? 1 : 0}`,
                  { headers: HEAD, signal: AbortSignal.timeout(800) });
    } catch {}
  }
  return { ok, ...st };
}

async function setTurbo(on) {
  try {
    await fetch(`${API}/turbo`, {
      method: "POST",
      headers: { ...HEAD, "Content-Type": "application/json" },
      body: JSON.stringify({ on }),
      signal: AbortSignal.timeout(3000),
    });
  } catch {}
  // the proxy needs a moment to start
  for (let i = 0; i < 10; i++) {
    const st = await syncTurbo();
    if (!st.ok || st.blocked || st.applied === on) return st;
    await new Promise((r) => setTimeout(r, 400));
  }
  return syncTurbo();
}

function flash(text, color) {
  chrome.action.setBadgeBackgroundColor({ color });
  chrome.action.setBadgeText({ text });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 2500);
}

function notify(title, message) {
  chrome.notifications.create({ type: "basic", iconUrl: "icons/icon128.png", title, message });
}

async function sendOrWarn(url, referrer = "") {
  if (!(await ping())) {
    notify("DualDL is not running", "Open the DualDL app, then try again.");
    flash("!", "#FF453A");
    return false;
  }
  try {
    await send(url, { referrer });
    flash("↓", "#0A84FF");
    return true;
  } catch (e) {
    notify("Could not send the link", String(e.message || e));
    flash("!", "#FF453A");
    return false;
  }
}

// --- Automatic capture -------------------------------------------------------

async function grab(item) {
  const url = item.finalUrl || item.url;
  if (bypass.has(url) || bypass.has(item.url)) {
    bypass.delete(url);
    bypass.delete(item.url);
    return;
  }
  if (!/^https?:/i.test(url) || item.byExtensionId === chrome.runtime.id) return;
  if (/^https?:\/\/(127\.0\.0\.1|localhost)[:/]/i.test(url)) return;

  const s = await settings();
  if (!s.enabled) return;
  const size = item.totalBytes > 0 ? item.totalBytes : item.fileSize;
  if (size > 0 && size < s.minSizeMB * 1024 * 1024) return;
  if (!(await ping())) return; // app closed: Chrome keeps the download

  try {
    await chrome.downloads.cancel(item.id);
    await chrome.downloads.erase({ id: item.id });
  } catch {}

  const filename = (item.filename || "").split(/[\\/]/).pop();
  try {
    await send(url, { referrer: item.referrer, filename });
    flash("↓", "#0A84FF");
  } catch {
    bypass.add(url); // give it back to Chrome
    chrome.downloads.download({ url });
    flash("!", "#FF453A");
  }
}

// onDeterminingFilename fires before Chrome writes anything or shows a Save dialog,
// and already knows the real file name.
chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  grab(item).finally(() => {
    try {
      suggest();
    } catch {}
  });
  return true;
});

// --- Right-click menu ---------------------------------------------------------

chrome.runtime.onInstalled.addListener(async () => {
  // A local check once a minute: the app may have just switched the login setting on, or restarted
  chrome.alarms.create("sync-login", { periodInMinutes: 1 });
  syncTurbo().then(syncLogin);
  await chrome.contextMenus.removeAll(); // an update keeps the old menus; recreating them would clash
  chrome.contextMenus.create({ id: "link", title: "Download with DualDL", contexts: ["link"] });
  chrome.contextMenus.create({ id: "media", title: "Download with DualDL", contexts: ["video", "audio"] });
  chrome.contextMenus.create({
    id: "video-link",
    title: "Download video with DualDL",
    contexts: ["link"],
    targetUrlPatterns: VIDEO_PATTERNS,
  });
  chrome.contextMenus.create({
    id: "mp3-link",
    title: "Download MP3 with DualDL",
    contexts: ["link"],
    targetUrlPatterns: VIDEO_PATTERNS,
  });
  chrome.contextMenus.create({
    id: "video-page",
    title: "Download this video with DualDL",
    contexts: ["page", "video"],
    documentUrlPatterns: VIDEO_PATTERNS,
  });
  chrome.contextMenus.create({
    id: "mp3-page",
    title: "Download this as MP3 with DualDL",
    contexts: ["page", "video"],
    documentUrlPatterns: VIDEO_PATTERNS,
  });
  chrome.contextMenus.create({
    id: "drive",
    title: "Download this from Drive with DualDL",
    contexts: ["page"],
    documentUrlPatterns: ["https://drive.google.com/file/*", "https://drive.google.com/open*",
                          "https://drive.google.com/drive/folders/*", "https://drive.google.com/drive/u/*"],
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "video-link" || info.menuItemId === "mp3-link") {
    sendVideo(info.linkUrl, info.menuItemId === "mp3-link" ? "audio" : "video");
    return;
  }
  if (info.menuItemId === "video-page" || info.menuItemId === "mp3-page") {
    // Page URL, not the <video> src: those are blob: or IP-locked stream links
    sendVideo(info.pageUrl, info.menuItemId === "mp3-page" ? "audio" : "video", "best", tab?.title || "");
    return;
  }
  const url = info.linkUrl || info.srcUrl || info.pageUrl;
  if (url) sendOrWarn(url, tab?.url || "");
});

// --- Popup messages -----------------------------------------------------------

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg.type === "ping") ping().then((ok) => { if (ok) syncLogin(); reply(ok); });
  else if (msg.type === "turbo-status") syncTurbo().then((st) => reply({ ...st, on: lastPing.turbo === true }));
  else if (msg.type === "turbo") setTurbo(msg.on).then(reply);
  else if (msg.type === "send") sendOrWarn(msg.url, msg.referrer || "").then(reply);
  else if (msg.type === "video") sendVideo(msg.url, msg.mode, msg.quality, msg.title || "").then(reply);
  else return false;
  return true;
});
