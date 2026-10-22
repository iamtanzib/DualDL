const $ = (id) => document.getElementById(id);
const DEFAULTS = { enabled: true, minSizeMB: 2 };
const VIDEO_HOSTS = /(^|\.)(youtube\.com|youtu\.be|vimeo\.com|facebook\.com|fb\.watch|instagram\.com|tiktok\.com|x\.com|twitter\.com|dailymotion\.com|twitch\.tv|reddit\.com|soundcloud\.com|bilibili\.com|bandcamp\.com|streamable\.com|ted\.com)$/i;

function toast(text, kind = "") {
  $("toast").textContent = text;
  $("toast").className = `toast ${kind}`;
}

function showTurbo(st) {
  $("turbo").checked = !!st.on;
  $("turbo").disabled = !st.ok;
  const note = $("turboNote");
  note.className = "note" + (st.blocked ? " err" : "");
  note.textContent = !st.ok ? "needs the app" : st.blocked ? "another extension controls Chrome's proxy"
    : st.on ? (st.applied ? "both lines in use" : "starting…") : "use both lines for browsing";
}

async function refresh() {
  const ok = await chrome.runtime.sendMessage({ type: "ping" });
  $("status").className = ok ? "on" : "off";
  $("statusText").textContent = ok ? "Connected to the app" : "DualDL app is not running";
  $("open").hidden = ok;
  showTurbo(await chrome.runtime.sendMessage({ type: "turbo-status" }));
}

async function sendUrl(url, referrer = "") {
  if (!url) return;
  toast("Sending…");
  const ok = await chrome.runtime.sendMessage({ type: "send", url, referrer });
  toast(ok ? "Added to DualDL ✓" : "Couldn't reach DualDL", ok ? "ok" : "err");
  return ok;
}

async function init() {
  const s = { ...DEFAULTS, ...(await chrome.storage.local.get(Object.keys(DEFAULTS))) };
  $("enabled").checked = s.enabled;
  $("minSize").value = s.minSizeMB;
  $("enabled").onchange = () => chrome.storage.local.set({ enabled: $("enabled").checked });
  $("minSize").onchange = () =>
    chrome.storage.local.set({ minSizeMB: Math.max(0, Number($("minSize").value) || 0) });

  $("send").onclick = async () => {
    if (await sendUrl($("link").value.trim())) $("link").value = "";
  };
  $("link").onkeydown = (e) => e.key === "Enter" && $("send").click();
  $("open").onclick = () => chrome.tabs.create({ url: "dualdl://open" });
  $("turbo").onchange = async () => {
    const want = $("turbo").checked;
    $("turboNote").textContent = want ? "starting…" : "turning off…";
    const st = await chrome.runtime.sendMessage({ type: "turbo", on: want });
    showTurbo({ ...st, on: want && st.applied });
  };

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (tab?.url && VIDEO_HOSTS.test(new URL(tab.url).hostname)) {
    $("video").hidden = false;
    $("videoTitle").textContent = tab.title || "This page has a video";
    for (const btn of document.querySelectorAll(".video-buttons button")) {
      btn.onclick = async () => {
        toast("Sending…");
        const ok = await chrome.runtime.sendMessage({
          type: "video", url: tab.url, mode: btn.dataset.mode, quality: btn.dataset.quality, title: tab.title,
        });
        toast(ok ? "Added to DualDL ✓" : "Couldn't reach DualDL", ok ? "ok" : "err");
      };
    }
  }
  if (tab?.url && /^https:\/\/drive\.google\.com\/drive\/(u\/\d+\/)?folders\//.test(tab.url)) {
    $("driveFolder").hidden = false;
    $("driveFolder").onclick = () => sendUrl(tab.url, tab.url);
  }
  if (tab?.url && /^https:\/\/drive\.google\.com\/(file\/d\/|open\?)/.test(tab.url)) {
    $("drive").hidden = false;
    $("drive").onclick = () => sendUrl(tab.url, tab.url);
  }
  refresh();
}

init();
