/* Render Switcher WebUI — premium concept UI + skiactl backend */

const SKIACTL = "/data/adb/modules/render_switcher/bin/skiactl";
const APP_VERSION = "v1.0.2"; /* hard-coded; keep in sync with module.prop */
const LANG_KEY = "render_switcher_lang";
const DEFAULT_LANG = "uk";
const GPU_KEY = "render_switcher_force_gpu";

const store = {
  get(k) { try { return localStorage.getItem(k); } catch (_) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (_) { /* storage unavailable */ } },
};

const S = {
  page: "dashboard",
  renderer: "skiavk",
  forceGpu: false,
  filter: "user",
  q: "",
  lang: store.get(LANG_KEY) || DEFAULT_LANG,
  packages: [],
  targets: new Map(),
  logs: [],
  bridgeOk: false,
};

/* Translations live in locales/<lang>.js (one file per language); each file
 * registers itself in window.SKIA_LOCALES and is loaded by index.html. */
const LOCALES = window.SKIA_LOCALES || {};
/* label shown next to the language name; internal ids stay ISO ("uk") */
const LANG_CODE = { uk: "UA", en: "EN" };
let strings = {};

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);
/* Missing key in the active language -> default language -> the key itself. */
const t = (k) => strings[k] ?? (LOCALES[DEFAULT_LANG] || {})[k] ?? k;

function loadLocale(lang) {
  if (!LOCALES[lang]) {
    console.warn("locale '" + lang + "' not found, using " + DEFAULT_LANG);
    lang = DEFAULT_LANG;
  }
  strings = LOCALES[lang] || {};
  S.lang = lang;
  store.set(LANG_KEY, lang);
  document.documentElement.lang = lang === "uk" ? "uk" : "en";
  applyStaticI18n();
}

function renderBanner() {
  const banner = $("#no-bridge");
  if (!banner) return;
  const title = banner.querySelector(".banner-title");
  const text = banner.querySelector("p:not(.banner-title)");
  if (title) title.textContent = t("banner_title");
  if (text) text.textContent = t("banner_text");
  banner.classList.toggle("hidden", !!S.bridgeOk);
}

function applyStaticI18n() {
  renderBanner();
}

/* ── Bridge ───────────────────────────────────────────────────────────── */
let cbCounter = 0;

function getBridge() {
  if (typeof window.ksu !== "undefined" && typeof window.ksu.exec === "function") return window.ksu;
  if (typeof window.$ !== "undefined" && typeof window.$.exec === "function") return window.$;
  return null;
}

function setBridge(ok) {
  S.bridgeOk = ok;
  const dot = $("#bridge-dot");
  if (dot) {
    dot.classList.toggle("is-ok", ok);
    dot.classList.toggle("is-off", !ok);
  }
  renderBanner();
}

function execRaw(cmd) {
  const bridge = getBridge();
  if (!bridge) {
    setBridge(false);
    return Promise.resolve({ code: 1, stdout: "", stderr: "no bridge" });
  }
  setBridge(true);
  return new Promise((resolve) => {
    const cbName = "render_switcher_cb_" + Date.now() + "_" + (cbCounter++);
    window[cbName] = (errno, stdout, stderr) => {
      delete window[cbName];
      resolve({ code: errno, stdout: stdout || "", stderr: stderr || "" });
    };
    try {
      bridge.exec(cmd, "{}", cbName);
    } catch (e) {
      delete window[cbName];
      resolve({ code: 1, stdout: "", stderr: String(e) });
    }
  });
}

async function skiactl(...args) {
  const quoted = args.map((a) => {
    const s = String(a);
    if (/^[A-Za-z0-9._/=+-]+$/.test(s)) return s;
    return "'" + s.replace(/'/g, "'\\''") + "'";
  });
  const cmd = SKIACTL + " " + quoted.join(" ");
  const res = await execRaw(cmd);
  return (res.stdout || "").trim();
}

/* ── Data helpers ─────────────────────────────────────────────────────── */
function parseTargetList(out) {
  const targets = [];
  (out || "").split("\n").forEach((line) => {
    line = line.trim();
    if (!line || line === "(none)") return;
    let enabled = true;
    if (line.includes("(disabled)")) {
      enabled = false;
      line = line.replace(/\s*\(disabled\)\s*/g, "");
    }
    const eq = line.indexOf("=");
    if (eq < 0) return;
    const pkg = line.slice(0, eq).trim();
    const renderer = line.slice(eq + 1).trim();
    if (!pkg) return;
    targets.push({ pkg, renderer: renderer || "skiavk", enabled });
  });
  return targets;
}

/** Extract HH:MM or HH:MM:SS from various timestamp formats */
/** Normalize any HH:MM or HH:MM:SS (and pad hours) to HH:MM:SS. */
function normalizeTime(t) {
  const m = String(t || "").trim().match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (!m) return "";
  const hh = String(Math.min(23, parseInt(m[1], 10))).padStart(2, "0");
  const mm = m[2];
  const ss = m[3] != null ? m[3] : "00";
  return hh + ":" + mm + ":" + ss;
}

function extractTime(line) {
  // Prefer full HH:MM:SS; fall back to HH:MM (normalized to :00)
  const full = String(line || "").match(/\b(\d{1,2}:\d{2}:\d{2})\b/);
  if (full) return normalizeTime(full[1]);
  const short = String(line || "").match(/\b(\d{1,2}:\d{2})\b/);
  return short ? normalizeTime(short[1]) : "";
}

function nowTime() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
}

/**
 * Keep only meaningful user-facing events:
 * - target add/remove/set/enable/disable
 * - global renderer change
 * - GPU composition option change
 * Drop technical noise (boot, verify, applying props, etc.)
 */
/**
 * Parse a raw log line into a structured event (language-agnostic).
 * Message text is produced later by formatEvent() using the active locale.
 */
function parseEvent(raw) {
  const line = String(raw || "").trim();
  if (!line) return null;

  // Strip leading [timestamp] [LEVEL] prefixes from log file
  const body = line
    .replace(/^\[[\d\-:\s]+\]\s*/g, "")
    .replace(/^\[(INFO|WARN|ERROR)\]\s*/i, "")
    .trim();

  // Target: pkg -> renderer  |  target: pkg -> renderer
  let m = body.match(/^(?:target(?:\s+added)?:\s*|Target added:\s*)([^\s=]+)\s*->\s*(skiavk|skiagl)\b/i);
  if (m) {
    return {
      kind: "target_set",
      pkg: m[1],
      renderer: m[2],
      tag: m[2] === "skiavk" ? "VK" : "GL",
    };
  }

  // Updated: pkg -> renderer
  m = body.match(/^Updated:\s*([^\s=]+)\s*->\s*(skiavk|skiagl)\b/i);
  if (m) {
    return {
      kind: "target_upd",
      pkg: m[1],
      renderer: m[2],
      tag: m[2] === "skiavk" ? "VK" : "GL",
    };
  }

  // target removed / Removed:
  m = body.match(/^(?:target removed:\s*|Removed:\s*)(.+)$/i);
  if (m) {
    return { kind: "target_rm", pkg: m[1].trim(), tag: "" };
  }

  // target pkg enabled=0|1
  m = body.match(/^target\s+(\S+)\s+enabled=([01])\b/i);
  if (m) {
    return {
      kind: "target_en",
      pkg: m[1],
      on: m[2] === "1",
      tag: "",
    };
  }

  // Enabled: / Disabled:
  m = body.match(/^(Enabled|Disabled):\s*(.+)$/i);
  if (m) {
    return {
      kind: "target_en",
      pkg: m[2].trim(),
      on: /^enabled$/i.test(m[1]),
      tag: "",
    };
  }

  // Global renderer set to X  |  applying debug.hwui.renderer=X
  m = body.match(/^(?:Global renderer set to\s+|applying debug\.hwui\.renderer=)(skiavk|skiagl)\b/i);
  if (m) {
    const vk = m[1] === "skiavk";
    return {
      kind: "renderer",
      renderer: m[1],
      tag: vk ? "VK" : "GL",
    };
  }

  // GPU composition on/off (server or previously-written client lines)
  if (/GPU|компонуванн|composition/i.test(body) && /увімк|вимк|on|off|enabled|disabled/i.test(body)) {
    const on = /увімк|:\s*on\b|enabled/i.test(body);
    return { kind: "gpu", on, tag: "GPU" };
  }

  return null; // drop everything else
}

/** Localize a structured event for the active language. */
function formatEvent(ev) {
  if (!ev) return "";
  const uk = S.lang === "uk";
  const ren = (r) => (r === "skiavk" ? "Vulkan" : "OpenGL");
  switch (ev.kind) {
    case "target_set":
      return uk
        ? `Таргет: ${ev.pkg} → ${ren(ev.renderer)}`
        : `Target: ${ev.pkg} → ${ren(ev.renderer)}`;
    case "target_upd":
      return uk
        ? `Оновлено: ${ev.pkg} → ${ren(ev.renderer)}`
        : `Updated: ${ev.pkg} → ${ren(ev.renderer)}`;
    case "target_rm":
      return uk ? `Таргет знято: ${ev.pkg}` : `Target removed: ${ev.pkg}`;
    case "target_en":
      return uk
        ? (ev.on ? `Таргет увімкнено: ${ev.pkg}` : `Таргет вимкнено: ${ev.pkg}`)
        : (ev.on ? `Target enabled: ${ev.pkg}` : `Target disabled: ${ev.pkg}`);
    case "renderer":
      return uk
        ? `Глобальний рендерер: ${ren(ev.renderer)}`
        : `Global renderer: ${ren(ev.renderer)}`;
    case "gpu":
      return uk
        ? (ev.on ? "GPU-компонування екрана: увімкнено" : "GPU-компонування екрана: вимкнено")
        : (ev.on ? "GPU screen composition: on" : "GPU screen composition: off");
    default:
      return ev.msg || "";
  }
}

function parseLogs(out) {
  const rows = [];
  const seen = new Set();
  (out || "").split("\n").forEach((line) => {
    line = line.trim();
    if (!line || line === "(no logs)") return;
    const time = extractTime(line);
    const ev = parseEvent(line);
    if (!ev) return;
    const key = (time || "") + "|" + ev.kind + "|" + (ev.pkg || "") + "|" + (ev.renderer || "") + "|" + (ev.on === undefined ? "" : ev.on);
    if (seen.has(key)) return;
    seen.add(key);
    rows.push({ time: time || "—", tag: ev.tag || "", kind: ev.kind, pkg: ev.pkg, renderer: ev.renderer, on: ev.on });
  });
  return rows.slice(-30).reverse();
}

/** Push a structured local event (shown immediately after user action). */
function pushEvent(ev) {
  const time = nowTime();
  const row = Object.assign({ time, tag: "", source: "local" }, ev);
  if (!row.tag && row.kind === "renderer") row.tag = row.renderer === "skiavk" ? "VK" : "GL";
  if (!row.tag && row.kind === "gpu") row.tag = "GPU";
  if (!row.tag && (row.kind === "target_set" || row.kind === "target_upd") && row.renderer) {
    row.tag = row.renderer === "skiavk" ? "VK" : "GL";
  }
  S.logs.unshift(row);
  if (S.logs.length > 30) S.logs.length = 30;
}

async function refreshStatus() {
  const out = await skiactl("status");
  const m = out.match(/Global renderer\s*:\s*(\S+)/i);
  if (m && (m[1] === "skiavk" || m[1] === "skiagl")) S.renderer = m[1];
  return out;
}

async function setGlobalRenderer(val) {
  if (val !== "skiavk" && val !== "skiagl") return;
  await skiactl("renderer", "set", val);
  S.renderer = val;
  const vk = val === "skiavk";
  pushEvent({ kind: "renderer", renderer: val });
  await refreshStatus();
  render();
}

async function refreshTargets() {
  const out = await skiactl("target", "list");
  S.targets = new Map(
    parseTargetList(out).map(({ pkg, renderer, enabled }) => [pkg, { renderer, enabled }])
  );
}

/* Cheap fingerprint of what the package list shows; lets us skip a rebuild
 * (and the scroll reset it causes) when a background reload changed nothing. */
function pkgSig() {
  return S.packages.map((x) => x.pkg + (x.system ? "s" : "u")).join("|") + "#" +
    [...S.targets].map(([k, v]) => k + "=" + v.renderer + (v.enabled ? "1" : "0")).join("|");
}

/* ── Package source ───────────────────────────────────────────────────────
 * Fast path: the native KernelSU WebView API.
 *   ksu.listPackages(type)      -> JSON array of package names (no shell spawn)
 *   ksu.getPackagesInfo([...])  -> JSON array with appLabel in ONE batched call
 *   ksu://icon/<pkg>            -> app icon, loaded lazily
 * Fallback (Magisk / APatch / old KernelSU): `skiactl packages` via pm,
 * package name only, no label or icon. */
const LABEL_CHUNK = 60;
const labelCache = new Map();       /* pkg -> label ("" = resolved, no label) */
const labelDone = { user: false, system: false };
let labelJobs = {};
let pkgGen = 0;
let pkgLoad = null;

const tick = () => new Promise((res) => setTimeout(res, 0));

function parseJson(v) {
  if (typeof v !== "string") return v;
  try { return JSON.parse(v); } catch (_) { return null; }
}

function nativeList(type) {
  const k = window.ksu;
  if (!k || typeof k.listPackages !== "function") return null;
  try {
    const r = parseJson(k.listPackages(type));
    return Array.isArray(r) ? r.filter((p) => typeof p === "string" && p) : null;
  } catch (_) { return null; }
}

function nativeInfo(names) {
  const k = window.ksu;
  if (!k || typeof k.getPackagesInfo !== "function") return [];
  try {
    const r = parseJson(k.getPackagesInfo(JSON.stringify(names)));
    return Array.isArray(r) ? r : (r ? [r] : []);
  } catch (_) { return []; }
}

function iconsSupported() {
  return !!(window.ksu && typeof window.ksu.getPackagesInfo === "function");
}

/* Resolve app labels for one scope ("user" | "system") in small chunks so the
 * UI thread is never blocked for long. Results are cached for the session. */
function ensureLabels(scope) {
  if (labelJobs[scope]) return labelJobs[scope];
  const gen = pkgGen;
  const sys = scope === "system";
  labelJobs[scope] = (async () => {
    const todo = S.packages.filter((x) => x.system === sys && !labelCache.has(x.pkg));
    for (let i = 0; i < todo.length; i += LABEL_CHUNK) {
      const part = todo.slice(i, i + LABEL_CHUNK);
      const got = nativeInfo(part.map((x) => x.pkg));
      const byPkg = new Map(got.map((r) => [r && r.packageName, r]));
      for (const x of part) {
        const r = byPkg.get(x.pkg);
        if (!r) continue;
        const label = r.appLabel ? String(r.appLabel) : "";
        labelCache.set(x.pkg, label);
        x.label = label;
      }
      await tick();
    }
    if (gen === pkgGen) labelDone[scope] = true;
  })();
  return labelJobs[scope];
}

async function loadPackagesViaShell() {
  const [userOut, sysOut, allOut] = await Promise.all([
    skiactl("packages", "user"),
    skiactl("packages", "system"),
    skiactl("packages", "all"),
  ]);
  const sysSet = new Set(
    (sysOut || "").split("\n").map((p) => p.trim()).filter(Boolean)
  );
  S.packages = (allOut || "")
    .split("\n")
    .map((p) => p.trim())
    .filter(Boolean)
    .map((pkg) => ({ pkg, system: sysSet.has(pkg), label: "" }));
  if (!S.packages.length) {
    const toList = (out, system) =>
      (out || "").split("\n").map((p) => p.trim()).filter(Boolean)
        .map((pkg) => ({ pkg, system, label: "" }));
    S.packages = [...toList(userOut, false), ...toList(sysOut, true)];
  }
}

async function doLoadPackages() {
  S.pkgLoading = !S.packages.length;
  pkgGen++;
  labelJobs = {};
  try {
    const targetsP = refreshTargets();           /* runs in parallel */
    const user = nativeList("user");
    const sys = nativeList("system");
    if (user && sys && (user.length || sys.length)) {
      const seen = new Set();
      const list = [];
      const add = (arr, system) => arr.forEach((pkg) => {
        if (seen.has(pkg)) return;
        seen.add(pkg);
        list.push({ pkg, system, label: labelCache.get(pkg) || "" });
      });
      add(sys, true);     /* system first: an updated system app stays "system" */
      add(user, false);
      S.packages = list;
      S.native = true;
      for (const scope of ["user", "system"]) {
        const sysScope = scope === "system";
        labelDone[scope] = list.every((x) => x.system !== sysScope || labelCache.has(x.pkg));
      }
      /* user apps are what the screen opens on: resolve them first, then
       * warm the (much bigger) system set in the background */
      await Promise.all([targetsP, ensureLabels("user")]);
      setTimeout(() => ensureLabels("system"), 50);
    } else {
      S.native = false;
      await targetsP;
      await loadPackagesViaShell();
    }
  } finally {
    S.pkgLoading = false;
  }
}

/* One load at a time; concurrent callers share the same promise. */
function loadPackages() {
  if (!pkgLoad) pkgLoad = doLoadPackages().finally(() => { pkgLoad = null; });
  return pkgLoad;
}

async function loadLogs() {
  const fromServer = parseLogs(await skiactl("logs"));
  // Keep recent local (client-pushed) events that may not yet be in the log file
  const local = (S.logs || []).filter((r) => r.source === "local");
  const keyOf = (r) =>
    (r.time || "") + "|" + (r.kind || "") + "|" + (r.pkg || "") + "|" + (r.renderer || "") + "|" + (r.on === undefined ? "" : r.on);
  const seen = new Set(fromServer.map(keyOf));
  const merged = [...local.filter((r) => !seen.has(keyOf(r))), ...fromServer];
  S.logs = merged.slice(0, 30);
}

async function setTargetRenderer(pkg, val) {
  const cur = S.targets.get(pkg);
  const hasOv = cur && cur.enabled;
  if (val === "inherit") {
    if (!cur) return;
    await skiactl("target", "remove", pkg);
    S.targets.delete(pkg);
    pushEvent({ kind: "target_rm", pkg });
  } else if (val === "skiavk" || val === "skiagl") {
    if (hasOv && cur.renderer === val) return;
    if (cur) await skiactl("target", "set", pkg, val);
    else await skiactl("target", "add", pkg, val);
    S.targets.set(pkg, { renderer: val, enabled: true });
    const vk = val === "skiavk";
    pushEvent({ kind: "target_set", pkg, renderer: val });
  } else {
    return;
  }
  await refreshTargets();
  if ($(".list")) fillList(true); else packages(true);
}

/* ── Renderer dropdown (one shared menu, fixed-positioned so the row's
      overflow:hidden and the scrolling list never clip it) ───────────── */
let renMenu = null;
let renBtn = null;

function rendererName(v) {
  return v === "skiavk" ? t("renderer_vk") : t("renderer_gl");
}

function closeRenMenu(restoreFocus) {
  if (renMenu) { renMenu.remove(); renMenu = null; }
  if (renBtn) {
    renBtn.setAttribute("aria-expanded", "false");
    if (restoreFocus) renBtn.focus();
    renBtn = null;
  }
}

function openRenMenu(btn, pkg) {
  const same = renBtn === btn;
  closeRenMenu(false);
  if (same) return;

  const ov = S.targets.get(pkg);
  const cur = ov && ov.enabled ? ov.renderer : "inherit";
  const opts = [
    ["inherit", `${t("renderer_default")} (${rendererName(S.renderer)})`],
    ["skiavk", t("renderer_vk")],
    ["skiagl", t("renderer_gl")],
  ];

  const menu = document.createElement("div");
  menu.className = "ren-menu";
  menu.setAttribute("role", "listbox");
  menu.setAttribute("aria-label", `${t("renderer_pick")} ${pkg}`);
  opts.forEach(([val, label]) => {
    const o = document.createElement("button");
    o.type = "button";
    o.className = "ren-opt" + (val === cur ? " active" : "");
    o.setAttribute("role", "option");
    o.setAttribute("aria-selected", val === cur ? "true" : "false");
    o.setAttribute("data-val", val);
    o.textContent = label;
    o.addEventListener("click", async (e) => {
      e.stopPropagation();
      closeRenMenu(false);
      await setTargetRenderer(pkg, val);
    });
    menu.appendChild(o);
  });
  menu.addEventListener("keydown", (e) => {
    const items = [...menu.querySelectorAll(".ren-opt")];
    const i = items.indexOf(document.activeElement);
    if (e.key === "Escape") { e.preventDefault(); closeRenMenu(true); }
    else if (e.key === "ArrowDown") { e.preventDefault(); items[(i + 1) % items.length].focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); items[(i - 1 + items.length) % items.length].focus(); }
  });

  document.body.appendChild(menu);

  const r = btn.getBoundingClientRect();
  const w = Math.min(Math.max(r.width, 176), window.innerWidth - 16);
  const h = menu.offsetHeight;
  let left = Math.min(Math.max(8, r.right - w), window.innerWidth - w - 8);
  let top = r.bottom + 6;
  if (top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 6);
  menu.style.width = w + "px";
  menu.style.left = left + "px";
  menu.style.top = top + "px";

  btn.setAttribute("aria-expanded", "true");
  renMenu = menu;
  renBtn = btn;
  (menu.querySelector(".ren-opt.active") || menu.querySelector(".ren-opt")).focus();
}

async function loadGpuPref() {
  // Source of truth is the real system property, not WebView localStorage
  // (localStorage survives module removal and would show a stale state).
  S.forceGpu = false;
  if (getBridge()) {
    const r = await execRaw("getprop persist.skia.force_gpu");
    S.forceGpu = r.code === 0 && String(r.stdout).trim() === "1";
    store.set(GPU_KEY, S.forceGpu ? "1" : "0");
  } else {
    S.forceGpu = store.get(GPU_KEY) === "1";
  }
}

async function toggleGpu() {
  S.forceGpu = !S.forceGpu;
  store.set(GPU_KEY, S.forceGpu ? "1" : "0");
  const val = S.forceGpu ? "1" : "0";
  // val is strictly "0"|"1" — never interpolate untrusted input into shell
  if (val !== "0" && val !== "1") return;
  await execRaw("setprop persist.skia.force_gpu " + val);
  await execRaw("service call SurfaceFlinger 1008 i32 " + val);
  pushEvent({ kind: "gpu", on: S.forceGpu });
  dashboard();
}

function syncLangMenu() {
  $$("#langMenu button").forEach((btn) => {
    const on = btn.getAttribute("data-lang") === S.lang;
    btn.classList.toggle("active", on);
    btn.setAttribute("aria-selected", on ? "true" : "false");
  });
}

function toggleLang() {
  const menu = $("#langMenu");
  const btn = $("#langBtn");
  if (!menu) return;
  syncLangMenu();
  const open = menu.classList.toggle("open");
  if (btn) btn.setAttribute("aria-expanded", open ? "true" : "false");
}

async function setLang(lang) {
  $("#langMenu")?.classList.remove("open");
  $("#langBtn")?.setAttribute("aria-expanded", "false");
  loadLocale(lang);
  syncLangMenu();
  render();
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escapeAttr(s) {
  return escapeHtml(s).replace(/'/g, "&#39;");
}

/* ── Render ───────────────────────────────────────────────────────────── */
/* ── Accessibility: roles, keyboard, state (idempotent, re-run after renders) ── */
function enhanceA11y() {
  $$(".choice").forEach((el) => {
    el.setAttribute("role", "radio");
    el.tabIndex = 0;
    el.setAttribute("aria-checked", el.classList.contains("active") ? "true" : "false");
  });
  const g = $("#gpuToggle");
  if (g) {
    g.setAttribute("role", "switch");
    g.tabIndex = 0;
    g.setAttribute("aria-checked", g.classList.contains("on") ? "true" : "false");
  }
  $$(".filter").forEach((el) => el.setAttribute("aria-pressed", el.classList.contains("active") ? "true" : "false"));
  $("#langBtn")?.setAttribute("aria-label", "Language");
}

document.addEventListener("keydown", (e) => {
  if (e.key !== "Enter" && e.key !== " ") return;
  const el = e.target.closest && e.target.closest('[role="radio"],[role="switch"]');
  if (el) { e.preventDefault(); el.click(); }
});

let a11yQueued = false;
new MutationObserver(() => {
  if (a11yQueued) return;
  a11yQueued = true;
  requestAnimationFrame(() => { a11yQueued = false; enhanceA11y(); });
}).observe(document.body, { childList: true, subtree: true });

function setAccent() {
  document.body.setAttribute("data-r", S.renderer === "skiagl" ? "gl" : "vk");
}

function render() {
  document.body.setAttribute("data-page", S.page);
  $("#logo").innerHTML = "Render <b>Switcher</b>";
  $("#langLabel").textContent = LANG_CODE[S.lang] || S.lang.toUpperCase();
  syncLangMenu();

  setAccent();
  $("#main").className = "page-" + S.page;
  const ICO = {
    dashboard: '<path d="M4 11l8-7 8 7v9H4z"/>',
    packages: '<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M12 4v16"/>',
  };
  $("#nav").innerHTML = [["dashboard", "tab_dashboard"], ["packages", "tab_packages"]].map(([p, k]) => `
    <button type="button" role="tab" aria-selected="${S.page === p}" class="${S.page === p ? "active" : ""}" data-page="${p}">
      <svg viewBox="0 0 24 24" aria-hidden="true">${ICO[p]}</svg>${t(k)}
    </button>`).join("");

  $$("#nav button").forEach((btn) => {
    btn.addEventListener("click", () => {
      S.page = btn.getAttribute("data-page");
      render();
      if (S.page === "packages") {
        const before = pkgSig();
        loadPackages().then(() => {
          /* rebuild only if the data changed and the user is still on this tab */
          if (S.page === "packages" && pkgSig() !== before) { if ($(".list")) fillList(true); else packages(true); }
        });
      } else {
        Promise.all([refreshStatus(), loadLogs()]).then(() => {
          if (S.page === "dashboard") dashboard();
        });
      }
    });
  });

  if (S.page === "dashboard") dashboard();
  else packages();
}

function dashboard() {
  setAccent();
  const vk = S.renderer === "skiavk";
  const gpu = S.forceGpu;

  const logHtml =
    S.logs.length > 0
      ? S.logs.map((r) => {
          const tag = r.tag || "";
          const msg = formatEvent(r);
          return `<div class="logrow"><time>${escapeHtml(r.time || "—")}</time><span>${escapeHtml(msg)}</span>${tag ? `<em class="${escapeAttr(tag.toLowerCase())}">${escapeHtml(tag)}</em>` : ""}</div>`;
        }).join("")
      : `<div class="log-empty">${t("empty_status")}</div>`;

  $("#main").innerHTML = `
    <section class="hero">
      <div class="hero-title">
        <strong>${vk ? "Vulkan" : "OpenGL"}</strong>
        <span class="badge">${APP_VERSION}</span>
      </div>
      <div class="hero-sub">${t("global_sub")}</div>
      <div class="renderer">
        <div class="choice ${vk ? "active" : ""}" data-ren="skiavk">
          <div class="choice-top">
            <span class="mark">VK</span>
            <span class="check"><svg viewBox="0 0 24 24"><circle class="ring" cx="12" cy="12" r="9"/><path class="tick" d="M7.5 12.5l3 3 6-6"/></svg></span>
          </div>
          <small>Vulkan · skiavk</small>
        </div>
        <div class="choice ${!vk ? "active" : ""}" data-ren="skiagl">
          <div class="choice-top">
            <span class="mark">GL</span>
            <span class="check"><svg viewBox="0 0 24 24"><circle class="ring" cx="12" cy="12" r="9"/><path class="tick" d="M7.5 12.5l3 3 6-6"/></svg></span>
          </div>
          <small>OpenGL · skiagl</small>
        </div>
      </div>
    </section>

    <section class="options">
      <div class="eyebrow">${t("options")}</div>
      <div class="toggle-row ${gpu ? "on" : ""}" id="gpuToggle">
        <div class="toggle-info">
          <div class="toggle-title">${t("gpu_title")}</div>
        </div>
        <div class="toggle-switch ${gpu ? "on" : ""}"><div class="knob"></div></div>
      </div>
    </section>

    <div class="section">
      <span>${t("events")}</span>
      <span>${S.logs.length ? S.logs.length + " " + t("records") : ""}</span>
    </div>
    <section class="log${S.logs.length ? "" : " is-empty"}">${logHtml}</section>
  `;

  $$(".choice").forEach((el) => {
    el.addEventListener("click", async () => {
      const val = el.getAttribute("data-ren");
      if (val === S.renderer) return;
      el.style.opacity = "0.6";
      await setGlobalRenderer(val);
    });
  });

  $("#gpuToggle")?.addEventListener("click", () => toggleGpu());
  installCustomScrollbar();
}

/* ── Packages page ────────────────────────────────────────────────────── */
const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });
const iconState = new Map();   /* pkg -> 1 (loaded) | 0 (failed for good) */
const iconTries = new Map();   /* pkg -> failed attempts so far */
const iconInflight = new Map();/* pkg -> { box, timer } */
let iconIO = null;
let iconQueue = [];            /* boxes waiting for a free slot */
const ICON_CONCURRENCY = 1000;  /* effectively unlimited */
const ICON_MAX_TRIES = 4;
const ICON_TIMEOUT = 10000;
let searchTimer = 0;

function scrollState() {
  return {
    main: $("#main")?.scrollTop || 0,
    pkgs: $(".packages")?.scrollTop || 0,
    list: $(".list")?.scrollTop || 0,
  };
}

function restoreScroll(s) {
  if (!s) return;
  const l = $(".list"); if (l) l.scrollTop = s.list;
  const p = $(".packages"); if (p) p.scrollTop = s.pkgs;
  const m = $("#main"); if (m) m.scrollTop = s.main;
}

function initialOf(name) {
  const m = String(name).match(/[\p{L}\p{N}]/u);
  return (m ? m[0] : "?").toUpperCase();
}

/* Compositor-friendly custom scrollbar.
 * The thumb is NOT a child of the scrolling list and never changes top/height
 * while scrolling. Its position is updated once per animation frame via
 * translate3d(), so fling scrolling does not force layout/repaint of the list.
 */
let customScroll = null;
let customScrollRAF = 0;
let customScrollHideTimer = 0;
let customScrollDrag = null;
let customScrollRect = null;

function customScrollHost() {
  /* Active page scroll container: packages list or dashboard events log. */
  if (S.page === "dashboard") {
    return document.querySelector(".log:not(.is-empty)");
  }
  return document.querySelector(".list:not(.is-empty)");
}

function customScrollMeasure() {
  const el = customScrollHost();
  if (!el) return null;
  const r = el.getBoundingClientRect();
  const inset = 14;
  const top = Math.round(r.top + inset);
  const bottom = Math.round(r.bottom - inset);
  const track = Math.max(0, bottom - top);
  const max = Math.max(0, el.scrollHeight - el.clientHeight);
  if (track <= 0 || max <= 0) return null;
  const thumb = Math.max(28, Math.min(track, Math.round(track * el.clientHeight / el.scrollHeight)));
  return { el, top, track, thumb, max, x: Math.round(r.right - 8) };
}

function customScrollRender(show = false) {
  customScrollRAF = 0;
  if (!customScroll) return;
  const m = customScrollMeasure();
  customScrollRect = m;
  if (!m) {
    customScroll.classList.remove("is-visible");
    return;
  }
  const ratio = m.max ? m.el.scrollTop / m.max : 0;
  const y = m.top + (m.track - m.thumb) * ratio;
  customScroll.style.height = m.thumb + "px";
  customScroll.style.transform = `translate3d(${m.x}px,${Math.round(y)}px,0)`;
  if (show) {
    customScroll.classList.add("is-visible");
    clearTimeout(customScrollHideTimer);
    customScrollHideTimer = setTimeout(() => {
      if (!customScrollDrag) customScroll.classList.remove("is-visible");
    }, 700);
  }
}

function customScrollSchedule(show = true) {
  if (show && customScroll) {
    customScroll.classList.add("is-visible");
    clearTimeout(customScrollHideTimer);
  }
  if (!customScrollRAF) customScrollRAF = requestAnimationFrame(() => customScrollRender(show));
}

function installCustomScrollbar() {
  if (!customScroll) {
    customScroll = document.createElement("div");
    customScroll.className = "custom-scroll-thumb";
    customScroll.setAttribute("aria-hidden", "true");
    document.body.appendChild(customScroll);

    customScroll.addEventListener("pointerdown", (e) => {
      const m = customScrollRect || customScrollMeasure();
      if (!m) return;
      e.preventDefault();
      customScrollDrag = { el: m.el, startY: e.clientY, startScroll: m.el.scrollTop, track: m.track, thumb: m.thumb, max: m.max };
      customScroll.classList.add("is-dragging", "is-visible");
      customScroll.setPointerCapture?.(e.pointerId);
    });
    customScroll.addEventListener("pointermove", (e) => {
      const d = customScrollDrag;
      if (!d) return;
      const span = Math.max(1, d.track - d.thumb);
      d.el.scrollTop = d.startScroll + (e.clientY - d.startY) * d.max / span;
      customScrollSchedule(true);
    });
    const endDrag = () => {
      customScrollDrag = null;
      customScroll.classList.remove("is-dragging");
      customScrollSchedule(false);
    };
    customScroll.addEventListener("pointerup", endDrag);
    customScroll.addEventListener("pointercancel", endDrag);
  }

  const list = customScrollHost();
  if (!list) {
    customScroll.classList.remove("is-visible");
    customScrollRect = null;
    return;
  }
  if (customScroll._list === list) {
    customScrollSchedule(false);
    return;
  }
  if (customScroll._onScroll) customScroll._list?.removeEventListener("scroll", customScroll._onScroll);
  customScroll._list = list;
  customScroll._onScroll = () => customScrollSchedule(true);
  list.addEventListener("scroll", customScroll._onScroll, { passive: true });
  customScrollSchedule(false);
}

window.addEventListener("resize", () => customScrollSchedule(false), { passive: true });
window.visualViewport?.addEventListener("resize", () => customScrollSchedule(false), { passive: true });


/* Lazy icon loading with retries.
 * - load/error are handled by delegated capture listeners, so events of <img>
 *   elements that were thrown away by a list rebuild are ignored and never
 *   leak a concurrency slot.
 * - every request has a timeout; a hung ksu://icon request can't stall the queue.
 * - a failure is retried (ICON_MAX_TRIES) before the letter placeholder is
 *   shown for good, and "failed" is forgotten when the Packages page opens. */
const iconUrl = (pkg) => "ksu://icon/" + pkg;

function startIcon(box) {
  const pkg = box.getAttribute("data-pkg");
  const img = box.firstElementChild;
  if (!pkg || !img) return;
  const timer = setTimeout(() => iconFail(pkg, box), ICON_TIMEOUT);
  iconInflight.set(pkg, { box, timer });
  img.src = iconUrl(pkg);
}

function iconDone(pkg) {
  const f = iconInflight.get(pkg);
  if (f) clearTimeout(f.timer);
  iconInflight.delete(pkg);
}

function iconOk(pkg, box) {
  iconDone(pkg);
  iconState.set(pkg, 1);
  iconTries.delete(pkg);
  box.classList.remove("noico");
  box.classList.add("is-ok");
  pumpIcons();
}

function iconFail(pkg, box) {
  iconDone(pkg);
  const img = box.firstElementChild;
  if (img) img.removeAttribute("src");
  box.classList.remove("is-ok");
  if (!box.isConnected) { pumpIcons(); return; }   /* row was rebuilt: new row retries itself */
  const n = (iconTries.get(pkg) || 0) + 1;
  iconTries.set(pkg, n);
  if (n >= ICON_MAX_TRIES) {
    iconState.set(pkg, 0);
    box.classList.add("noico");
  } else {
    setTimeout(() => {
      if (box.isConnected && !box.classList.contains("is-ok") && !box.classList.contains("noico")) {
        iconQueue.push(box);
        pumpIcons();
      }
    }, 300 * n);
  }
  pumpIcons();
}

function pumpIcons() {
  while (iconInflight.size < ICON_CONCURRENCY && iconQueue.length) {
    const box = iconQueue.shift();
    if (!box || !box.isConnected || box.classList.contains("is-ok") ||
        box.classList.contains("noico")) continue;
    const pkg = box.getAttribute("data-pkg");
    if (!pkg || iconInflight.has(pkg)) continue;
    startIcon(box);
  }
}

function queueIcon(box) {
  const pkg = box.getAttribute("data-pkg");
  if (!pkg) return;
  const st = iconState.get(pkg);
  if (st === 0) { box.classList.add("noico"); return; }
  if (st === 1) {   /* known good: just attach it to the (new) row */
    const img = box.firstElementChild;
    if (img && img.getAttribute("src") !== iconUrl(pkg)) img.src = iconUrl(pkg);
    box.classList.add("is-ok");
    return;
  }
  iconQueue.push(box);
  pumpIcons();
}

function onIconEvent(e) {
  const img = e.target;
  if (!(img instanceof HTMLImageElement)) return;
  const box = img.parentElement;
  if (!box || !box.classList.contains("appico")) return;
  const pkg = box.getAttribute("data-pkg");
  if (!pkg || !img.getAttribute("src")) return;
  if (e.type === "load") { iconOk(pkg, box); return; }
  iconState.delete(pkg);   /* an icon that was OK before can fail too */
  iconFail(pkg, box);
}
document.addEventListener("load", onIconEvent, true);
document.addEventListener("error", onIconEvent, true);

function observeIcons() {
  if (iconIO) { iconIO.disconnect(); iconIO = null; }
  iconQueue = [];
  /* old rows are gone: drop their in-flight requests so no slot stays busy */
  iconInflight.forEach((f) => clearTimeout(f.timer));
  iconInflight.clear();

  const pending = $$(".appico:not(.is-ok):not(.noico)");
  if (!pending.length) return;
  if (!iconsSupported() || typeof IntersectionObserver === "undefined") {
    pending.forEach((el) => el.classList.add("noico"));
    return;
  }

  const list = $(".list");
  iconIO = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      iconIO.unobserve(e.target);
      queueIcon(e.target);
    }
  }, {
    root: null,            /* viewport */
    rootMargin: "100px",
    threshold: 0.1
  });
  pending.forEach((el) => iconIO.observe(el));
}

function skeletonRows() {
  let h = "";
  for (let i = 0; i < 10; i++) {
    h += '<div class="app-row sk"><div class="appico sk-b"></div>' +
      '<div class="apptext"><div class="sk-b sk-l1"></div><div class="sk-b sk-l2"></div></div>' +
      '<div class="ren-dd"><div class="sk-b sk-btn"></div></div></div>';
  }
  return h;
}

function rowHtml(x) {
  const ov = S.targets.get(x.pkg);
  const hasOv = ov && ov.enabled;
  const eff = hasOv ? ov.renderer : S.renderer;
  const name = x.label || x.pkg;
  const st = iconState.get(x.pkg);
  const icoCls = "appico" + (st === 1 ? " is-ok" : st === 0 ? " noico" : "");
  const src = st === 1 ? ` src="ksu://icon/${escapeAttr(x.pkg)}"` : "";
  return `<div class="app-row" data-pkg="${escapeAttr(x.pkg)}">` +
    `<div class="${icoCls}" data-pkg="${escapeAttr(x.pkg)}" data-l="${escapeAttr(initialOf(name))}"><img alt="" decoding="async"${src}></div>` +
    `<div class="apptext"><div class="appname">${escapeHtml(name)}</div>` +
    (x.label ? `<div class="apppkg">${escapeHtml(x.pkg)}</div>` : "") + `</div>` +
    `<div class="ren-dd"><button type="button" class="ren-dd-btn ${hasOv ? "is-set" : "is-inherit"}" aria-haspopup="listbox" aria-expanded="false">` +
    `<span class="ren-dd-label">${rendererName(eff)}</span><span class="chev" aria-hidden="true">⌄</span></button></div>` +
    `</div>`;
}

/* (Re)fill only the list + counters. The search box and filter chips stay
 * untouched, so typing no longer rebuilds the whole screen. */
function fillList(keepScroll) {
  const listEl = $(".list");
  if (!listEl) return;
  const saved = keepScroll ? scrollState() : null;
  closeRenMenu(false);

  const overrides = [...S.targets.values()].filter((v) => v.enabled).length;
  const ovEl = $("#ovCnt");
  if (ovEl) ovEl.textContent = String(overrides);

  /* label resolution still running for what the current filter shows? */
  const scopes = S.filter === "user" ? ["user"] : S.filter === "sys" ? ["system"] : ["user", "system"];
  const waiting = S.native ? scopes.filter((s) => !labelDone[s]) : [];
  const loadingNow = (S.pkgLoading && !S.packages.length) || waiting.length > 0;

  let base = S.packages;
  if (S.q) {
    const q = S.q.toLowerCase();
    base = base.filter((x) => x.pkg.toLowerCase().includes(q) || (x.label && x.label.toLowerCase().includes(q)));
  }
  let cUser = 0, cSys = 0;
  for (const x of base) { if (x.system) cSys++; else cUser++; }
  const counts = { user: cUser, sys: cSys, all: base.length };
  $$(".filter").forEach((btn) => {
    const c = btn.querySelector(".cnt");
    if (c) c.textContent = String(counts[btn.getAttribute("data-filter")] ?? 0);
  });

  if (loadingNow) {
    listEl.className = "list";
    listEl.innerHTML = skeletonRows();
    if (waiting.length) {
      Promise.all(waiting.map(ensureLabels)).then(() => {
        if (S.page === "packages" && $(".list")) fillList(true);
      });
    }
    restoreScroll(saved);
    installCustomScrollbar();
    return;
  }

  const list = base.filter((x) => S.filter === "all" || (S.filter === "sys" ? x.system : !x.system));
  const isOv = (x) => { const o = S.targets.get(x.pkg); return o && o.enabled ? 1 : 0; };
  list.sort((a, b) => {
    const d = isOv(b) - isOv(a);
    return d || collator.compare(a.label || a.pkg, b.label || b.pkg);
  });

  listEl.className = "list" + (list.length ? "" : " is-empty");
  listEl.innerHTML = list.length
    ? list.map(rowHtml).join("")
    : `<div class="list-empty">${t("empty_title")}</div>`;
  restoreScroll(saved);
  observeIcons();
  installCustomScrollbar();
}

function packages(keepScroll) {
  const saved = keepScroll ? scrollState() : null;
  for (const [k, v] of iconState) if (v === 0) iconState.delete(k);
  iconTries.clear();
  setAccent();
  closeRenMenu(false);
  $("#logo").innerHTML = "Render <b>Switcher</b>";

  $("#main").innerHTML = `
    <section class="packages">
      <div class="search">
        <span>⌕</span>
        <input id="q" type="search" placeholder="${escapeAttr(t("search_placeholder"))}" value="${escapeAttr(S.q)}" autocomplete="off" spellcheck="false">
      </div>
      <div class="filters">
        <button type="button" class="filter ${S.filter === "user" ? "active" : ""}" data-filter="user">${t("filter_user")}<span class="cnt">0</span></button>
        <button type="button" class="filter ${S.filter === "sys" ? "active" : ""}" data-filter="sys">${t("filter_system")}<span class="cnt">0</span></button>
        <button type="button" class="filter ${S.filter === "all" ? "active" : ""}" data-filter="all">${t("filter_all")}<span class="cnt">0</span></button>
      </div>
      <div class="group">
        <span>${t("overrides")}</span>
        <span id="ovCnt">0</span>
      </div>
      <div class="list"></div>
    </section>
  `;

  fillList(false);
  restoreScroll(saved);
  installCustomScrollbar();

  const qInput = $("#q");
  if (qInput) {
    qInput.addEventListener("input", () => {
      S.q = qInput.value;
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => fillList(false), 60);
    });
    if (document.activeElement === qInput || S.q) {
      qInput.focus();
      try { qInput.setSelectionRange(qInput.value.length, qInput.value.length); } catch (_) {}
    }
  }

  $$(".filter").forEach((btn) => {
    btn.addEventListener("click", () => {
      S.filter = btn.getAttribute("data-filter");
      $$(".filter").forEach((b) => b.classList.toggle("active", b === btn));
      fillList(false);
      const l = $(".list"); if (l) l.scrollTop = 0;
    });
  });

  /* one delegated handler instead of a listener per row */
  $(".list").addEventListener("click", (e) => {
    const btn = e.target.closest(".ren-dd-btn");
    if (!btn) return;
    e.stopPropagation();
    const pkg = btn.closest(".app-row")?.getAttribute("data-pkg");
    if (pkg) openRenMenu(btn, pkg);
  });
}

window.addEventListener("scroll", () => {
  if (renMenu) closeRenMenu(false);
}, { capture: true, passive: true });
window.addEventListener("resize", () => {
  if (renMenu) closeRenMenu(false);
});

/* ── Boot ─────────────────────────────────────────────────────────────── */
document.addEventListener("click", (e) => {
  if (!e.target.closest(".ren-menu")) closeRenMenu(false);
  if (!e.target.closest(".lang-wrap")) {
    $("#langMenu")?.classList.remove("open");
    $("#langBtn")?.setAttribute("aria-expanded", "false");
  }
});

$("#langBtn")?.addEventListener("click", (e) => {
  e.stopPropagation();
  toggleLang();
});

$$("#langMenu button").forEach((btn) => {
  btn.addEventListener("click", () => setLang(btn.getAttribute("data-lang")));
});

(async function init() {
  await loadGpuPref();
  loadLocale(S.lang);
  setBridge(!!getBridge());
  try {
    await Promise.all([refreshStatus(), loadLogs()]);
  } catch (e) {
    console.warn("init status/logs:", e);
  }
  render();
  loadPackages().catch((e) => console.warn("preload packages:", e));
})();
