// The real background.js under Deno with a fake Chrome and a fake app (no network).
//   deno run --allow-read tests/extension_test.js extension/background.js
let failures = 0;
const check = (ok, name, detail = "") => {
  console.log((ok ? "PASS " : "FAIL ") + name + (ok || !detail ? "" : " — " + detail));
  if (!ok) failures++;
};

// --- fake Chrome
const anything = () => new Proxy(function () {}, { get: (_, k) => (k === "then" ? undefined : anything()), apply: () => anything() });
const store = {};
const proxyState = { levelOfControl: "controllable_by_this_extension", value: null, sets: 0, clears: 0 };
globalThis.chrome = new Proxy({}, {
  get: (_, k) => ({
    storage: { local: { get: async (key) => ({ [key]: store[key] }), set: async (o) => Object.assign(store, o) } },
    cookies: {
      getAll: async ({ domain }) => domain === "youtube.com"
        ? [{ domain: ".youtube.com", hostOnly: false, path: "/", secure: true, session: false,
             expirationDate: 1893456000, name: "LOGIN_INFO", value: "x" }] : [],
      onChanged: { addListener() {} },
    },
    proxy: { settings: {
      get: async () => ({ levelOfControl: proxyState.levelOfControl, value: proxyState.value }),
      set: async ({ value }) => { proxyState.value = value; proxyState.sets++; proxyState.levelOfControl = "controlled_by_this_extension"; },
      clear: async () => { proxyState.value = null; proxyState.clears++; proxyState.levelOfControl = "controllable_by_this_extension"; },
    } },
  }[k] ?? anything()),
});

// --- fake app on 127.0.0.1:51977
const app = { up: true, turbo: false, wantCookies: false, hasCookies: false, posts: [], reported: null };
globalThis.fetch = async (url, opts = {}) => {
  if (!app.up) throw new TypeError("connection refused");
  const u = new URL(url);
  if (u.pathname === "/ping") {
    if (u.searchParams.has("turbo")) app.reported = { applied: u.searchParams.get("turbo"), blocked: u.searchParams.get("blocked") };
    return new Response(JSON.stringify({ ok: true, app: "DualDL", wantCookies: app.wantCookies,
      hasCookies: app.hasCookies, turbo: app.turbo, turboPort: 51978 }));
  }
  app.posts.push(u.pathname);
  if (u.pathname === "/cookies") app.hasCookies = true;
  if (u.pathname === "/turbo") app.turbo = JSON.parse(opts.body).on;
  return new Response('{"ok":true}');
};

const src = await Deno.readTextFile(Deno.args[0]);
const ext = new Function(src + "\nreturn { syncLogin, syncTurbo, setTurbo, turboPac };")();

// --- PAC routing (the PAC helper functions Chrome provides)
const pac = new Function("isPlainHostName", "dnsDomainIs", "shExpMatch",
  ext.turboPac(51978) + "\nreturn FindProxyForURL;")(
  (h) => !h.includes("."), (h, d) => h.endsWith(d),
  (s, p) => new RegExp("^" + p.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$").test(s));
const viaTurbo = "PROXY 127.0.0.1:51978; DIRECT";
for (const [url, host, want] of [
  ["https://www.youtube.com/", "www.youtube.com", viaTurbo],
  ["wss://chat.example.com/", "chat.example.com", viaTurbo],
  ["https://172.32.0.1/", "172.32.0.1", viaTurbo],
  ["http://example.com/", "example.com", "DIRECT"],
  ["https://192.168.0.1/", "192.168.0.1", "DIRECT"],
  ["https://10.1.2.3/", "10.1.2.3", "DIRECT"],
  ["https://172.20.1.1/", "172.20.1.1", "DIRECT"],
  ["https://printer.local/", "printer.local", "DIRECT"],
  ["https://intranet/", "intranet", "DIRECT"],
  ["https://[::1]/", "::1", "DIRECT"],
]) check(pac(url, host) === want, `PAC: ${url} → ${want === "DIRECT" ? "direct" : "Turbo"}`, pac(url, host));

// --- Turbo follows the app
let st = await ext.syncTurbo();
check(!st.applied && proxyState.sets === 0, "Turbo off in the app: Chrome's proxy untouched");
app.turbo = true;
st = await ext.syncTurbo();
check(st.applied && proxyState.value?.pacScript?.data.includes("127.0.0.1:51978"), "Turbo on: Chrome gets the PAC script");
check(app.reported?.applied === "1", "the extension tells the app Chrome took it", JSON.stringify(app.reported));
app.up = false;
st = await ext.syncTurbo();
check(!st.applied && proxyState.clears === 1 && proxyState.value === null, "app closed: Chrome goes back to direct");
app.up = true;
st = await ext.syncTurbo();
check(st.applied && proxyState.value !== null, "app back: Turbo returns");
st = await ext.setTurbo(false);
check(!app.turbo && !st.applied && proxyState.value === null, "switching off from the popup turns the app off and clears Chrome");
proxyState.levelOfControl = "controlled_by_other_extensions";
app.turbo = true;
const setsBefore = proxyState.sets;
st = await ext.syncTurbo();
check(st.blocked && proxyState.sets === setsBefore && app.reported?.blocked === "1",
      "another extension (a VPN) holds the proxy: left alone and reported");
proxyState.levelOfControl = "controllable_by_this_extension";

// --- login sync
app.wantCookies = false;
await ext.syncLogin();
check(!app.posts.includes("/cookies"), "login not sent while the app's setting is off");
app.wantCookies = true;
await ext.syncLogin();
check(app.posts.filter((p) => p === "/cookies").length === 1, "login sent once the setting is on");
await ext.syncLogin();
check(app.posts.filter((p) => p === "/cookies").length === 1, "not resent while the app already has it");

Deno.exit(failures ? 1 : 0);
