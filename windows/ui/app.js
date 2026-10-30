"use strict";
const invoke = window.__TAURI__.core.invoke;
const $ = (s) => document.querySelector(s);

// MARK: 狀態

const S = {
  cwd: "",
  history: [],
  hi: -1,
  entries: [],
  sel: new Set(),
  anchor: null,
  sort: { key: "name", desc: false },
  showHidden: false,
  mode: "browse", // browse | search | duplicates | usage
  query: "",
  hits: [],
  searching: false,
  pathMatch: null,
  places: [],
  index: { crawling: true, count: 0 },
  dup: { running: false, groups: null, checked: new Set(), root: "" },
  usage: { running: false, rows: null, dir: "" },
  error: null,
};

// MARK: 小工具

const PLACE_NAMES = { home: "個人", desktop: "桌面", documents: "文件", downloads: "下載項目", pictures: "圖片", music: "音樂", videos: "影片" };
const PLACE_ICONS = { home: "⌂", desktop: "▭", documents: "▤", downloads: "⤓", pictures: "▣", music: "♪", videos: "▶", drive: "⛁" };

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
function baseName(p) {
  const s = p.replace(/[\\/]+$/, "");
  const i = Math.max(s.lastIndexOf("\\"), s.lastIndexOf("/"));
  return i >= 0 ? s.slice(i + 1) || p : s;
}
function dirName(p) {
  const s = p.replace(/[\\/]+$/, "");
  const i = Math.max(s.lastIndexOf("\\"), s.lastIndexOf("/"));
  if (i < 0) return s;
  const d = s.slice(0, i);
  return /^[A-Za-z]:$/.test(d) ? d + "\\" : d || "/";
}
function fmtBytes(n) {
  if (n < 1024) return `${n} B`;
  const u = ["KB", "MB", "GB", "TB"];
  let v = n / 1024, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${u[i]}`;
}
const dateFmt = () => new Intl.DateTimeFormat(LANG === "zh-Hant" ? "zh-TW" : LANG, { dateStyle: "medium", timeStyle: "short" });
function fmtDate(sec) { return sec > 0 ? dateFmt().format(new Date(sec * 1000)) : "—"; }
function kindOf(e) {
  if (e.is_dir) return t("資料夾");
  const m = /\.([^.\\/]+)$/.exec(e.name);
  return m ? t("{0} 檔案", m[1].toUpperCase()) : t("檔案");
}
function samePath(a, b) { return a.replace(/[\\/]+$/, "").toLowerCase() === b.replace(/[\\/]+$/, "").toLowerCase(); }

const FOLDER_SVG = `<svg class="icon" viewBox="0 0 24 24"><path fill="#e9a52c" d="M2 6a2 2 0 0 1 2-2h5l2 2h9a2 2 0 0 1 2 2v1H2z"/><path fill="var(--folder)" d="M2 8h20v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2z"/></svg>`;
function fileSvg(name) {
  const ext = (/\.([^.]+)$/.exec(name)?.[1] || "").slice(0, 4).toUpperCase();
  const colors = { PDF: "#d93025", DOC: "#2b579a", DOCX: "#2b579a", XLS: "#217346", XLSX: "#217346", PPT: "#d24726", PPTX: "#d24726", ZIP: "#8d6e63", RAR: "#8d6e63", "7Z": "#8d6e63", PSD: "#31a8ff", PNG: "#7b61ff", JPG: "#7b61ff", JPEG: "#7b61ff", HEIC: "#7b61ff", GIF: "#7b61ff", MP4: "#e8710a", MOV: "#e8710a", MP3: "#e91e63", EXE: "#455a64" };
  const c = colors[ext] || "#8a909c";
  return `<svg class="icon" viewBox="0 0 24 24"><path fill="var(--panel)" stroke="${c}" stroke-width="1.4" d="M5 2.7h9.3L19.3 7.7V21.3H5z"/><path fill="${c}" opacity=".35" d="M14 3v5h5"/>${ext ? `<rect x="3" y="13" width="18" height="6.5" rx="1.2" fill="${c}"/><text x="12" y="18" font-size="4.6" font-family="Segoe UI,sans-serif" font-weight="700" text-anchor="middle" fill="#fff">${esc(ext)}</text>` : ""}</svg>`;
}
const iconFor = (e) => (e.is_dir ? FOLDER_SVG : fileSvg(e.name));

let toastTimer;
function toast(msg) {
  const el = $("#toast");
  el.textContent = msg;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 2200);
}
function failed(e) {
  const map = { exists: "同名的項目已經存在", "invalid-name": "名稱不能包含 \\ / : * ? \" < > |" };
  toast(map[e] ? t(map[e]) : t("操作失敗:{0}", e));
}
async function copyText(s) {
  try { await navigator.clipboard.writeText(s); }
  catch {
    const ta = document.createElement("textarea");
    ta.value = s; document.body.appendChild(ta); ta.select(); document.execCommand("copy"); ta.remove();
  }
  toast(t("已拷貝路徑"));
}
function debounce(fn, ms) {
  let h;
  return (...a) => { clearTimeout(h); h = setTimeout(() => fn(...a), ms); };
}

// MARK: 導覽

async function navigate(path, { push = true, select = null } = {}) {
  if (S.mode !== "browse") leaveTool();
  clearSearch(false);
  try {
    S.entries = await invoke("list_dir", { path, showHidden: S.showHidden });
    S.error = null;
  } catch (e) {
    S.entries = [];
    S.error = String(e);
  }
  if (push && !(S.history[S.hi] && samePath(S.history[S.hi], path))) {
    S.history = S.history.slice(0, S.hi + 1);
    S.history.push(path);
    S.hi = S.history.length - 1;
  }
  S.cwd = path;
  S.sel = new Set(select ? [select] : []);
  S.anchor = select;
  try { localStorage.setItem("cwd", path); } catch {}
  await renderCrumbs();
  render();
  if (select) document.querySelector("tr.sel")?.scrollIntoView({ block: "center" });
}
const reload = () => navigate(S.cwd, { push: false, select: [...S.sel][0] || null });
const goBack = () => { if (S.hi > 0) navigate(S.history[--S.hi], { push: false }); };
const goForward = () => { if (S.hi < S.history.length - 1) navigate(S.history[++S.hi], { push: false }); };
async function goUp() {
  const p = await invoke("parent", { path: S.cwd });
  if (p) navigate(p, { select: S.cwd });
}
/// 資料夾 → 進入;檔案 → 到所在資料夾並選取
function reveal(path, isDir) {
  if (isDir) navigate(path);
  else navigate(dirName(path), { select: path });
}
function activate(path, isDir) {
  if (isDir) navigate(path);
  else invoke("open_path", { path }).catch(failed);
}

// MARK: 路徑列(可直接輸入不完整的路徑)

async function renderCrumbs() {
  const list = await invoke("crumbs", { path: S.cwd });
  const box = $("#crumbs");
  box.innerHTML = list.map((c, i) => `${i ? '<span class="sep">›</span>' : ""}<button class="crumb" data-path="${esc(c.path)}">${esc(c.name)}</button>`).join("");
  box.scrollLeft = box.scrollWidth;
  $("#back").disabled = S.hi <= 0;
  $("#forward").disabled = S.hi >= S.history.length - 1;
  document.querySelectorAll(".side-item[data-path]").forEach((b) => b.classList.toggle("active", S.mode === "browse" && samePath(b.dataset.path, S.cwd)));
}

function editPath() {
  const box = $("#pathbox"), input = $("#pathinput");
  box.classList.add("editing");
  box.classList.remove("notfound");
  input.value = S.cwd;
  input.focus();
  input.select();
}
function endEditPath() {
  $("#pathbox").classList.remove("editing", "notfound");
  showHint("");
}
function showHint(text, error = false) {
  const h = $("#pathhint");
  h.textContent = text;
  h.classList.toggle("show", !!text);
  h.classList.toggle("error", error);
}
const previewPath = debounce(async (text) => {
  if (!$("#pathbox").classList.contains("editing")) return;
  if (!text.trim() || samePath(text.trim(), S.cwd)) return showHint("");
  const r = await invoke("resolve_path", { input: text, base: S.cwd });
  if ($("#pathinput").value !== text) return;
  showHint(r ? `→ ${r.path}` : t("找不到這個位置"), !r);
}, 150);
async function commitPath() {
  const text = $("#pathinput").value;
  if (!text.trim()) return endEditPath();
  const r = await invoke("resolve_path", { input: text, base: S.cwd });
  if (!r) {
    $("#pathbox").classList.add("notfound");
    showHint(t("找不到這個位置"), true);
    return;
  }
  endEditPath();
  reveal(r.path, r.is_dir);
}

// MARK: 搜尋

function clearSearch(rerender = true) {
  S.query = "";
  S.hits = [];
  S.pathMatch = null;
  S.searching = false;
  $("#search").value = "";
  if (S.mode === "search") S.mode = "browse";
  if (rerender) render();
}
let searchSeq = 0;
const runSearch = debounce(async () => {
  const q = S.query;
  const seq = ++searchSeq;
  if (!q.trim()) return clearSearch();
  if (S.mode !== "search") { leaveTool(); S.mode = "search"; }
  S.searching = true;
  render();
  const scope = $("#scope").value === "folder" ? S.cwd : null;
  const [hits, match] = await Promise.all([
    invoke("search", { query: q, scope }),
    invoke("looks_like_path", { input: q }).then((yes) => (yes ? invoke("resolve_path", { input: q, base: S.cwd }) : null)),
  ]);
  if (seq !== searchSeq) return;
  S.hits = hits;
  S.pathMatch = match;
  S.searching = false;
  S.sel = new Set();
  render();
}, 120);

// MARK: 畫面

function render() {
  const c = $("#content");
  if (S.mode === "duplicates") return renderDuplicates(c);
  if (S.mode === "usage") return renderUsage(c);
  if (S.mode === "search") return renderSearch(c);
  renderBrowse(c);
}

function sortedEntries() {
  const { key, desc } = S.sort;
  const cmp = {
    name: (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }),
    modified: (a, b) => a.modified - b.modified,
    size: (a, b) => a.size - b.size,
    kind: (a, b) => kindOf(a).localeCompare(kindOf(b)) || a.name.localeCompare(b.name, undefined, { numeric: true }),
  }[key];
  return [...S.entries].sort((a, b) => (b.is_dir - a.is_dir) || (desc ? -cmp(a, b) : cmp(a, b)));
}

function header(cols) {
  return `<thead><tr>${cols.map(([k, label, w]) => `<th data-sort="${k}" style="${w ? `width:${w}` : ""}" class="${S.sort.key === k ? "sorted" + (S.sort.desc ? " desc" : "") : ""}">${t(label)}</th>`).join("")}</tr></thead>`;
}

function renderBrowse(c) {
  if (S.error) {
    c.innerHTML = `<div class="empty">${t("無法開啟這個資料夾")}<small>${esc(S.error)}</small></div>`;
  } else if (!S.entries.length) {
    c.innerHTML = `<div class="empty">${t("這個資料夾是空的")}</div>`;
  } else {
    const rows = sortedEntries().map((e) => `<tr data-path="${esc(e.path)}" data-dir="${e.is_dir ? 1 : ""}" class="${S.sel.has(e.path) ? "sel" : ""}"${e.hidden ? ' style="opacity:.6"' : ""}>
      <td><div class="name">${iconFor(e)}<span>${esc(e.name)}</span></div></td>
      <td class="muted">${fmtDate(e.modified)}</td>
      <td class="num">${e.is_dir ? "—" : fmtBytes(e.size)}</td>
      <td class="muted">${esc(kindOf(e))}</td></tr>`).join("");
    c.innerHTML = `<table>${header([["name", "名稱"], ["modified", "修改日期", "190px"], ["size", "大小", "90px"], ["kind", "種類", "130px"]])}<tbody>${rows}</tbody></table>`;
  }
  updateStatus();
}

function renderSearch(c) {
  const banner = S.pathMatch
    ? `<button class="banner" id="gomatch">→ ${t("前往")} <b>${esc(S.pathMatch.path)}</b><span class="key">Enter ↵</span></button>`
    : "";
  if (!S.hits.length) {
    const msg = S.searching ? `<div class="spinner"></div>${t("搜尋中…")}` : S.index.crawling ? t("索引建立中…") : t("找不到符合的項目");
    c.innerHTML = banner + `<div class="empty" style="${banner ? "top:36px" : ""}">${msg}</div>`;
  } else {
    const rows = S.hits.map((h) => `<tr data-path="${esc(h.path)}" data-dir="${h.is_dir ? 1 : ""}" class="${S.sel.has(h.path) ? "sel" : ""}">
      <td><div class="name">${iconFor(h)}<span>${esc(h.name)}</span></div></td>
      <td class="muted" title="${esc(h.path)}" style="direction:rtl;text-align:left">${esc(dirName(h.path))}</td>
      <td class="muted">${fmtDate(h.modified)}</td>
      <td class="num">${h.is_dir ? "—" : fmtBytes(h.size)}</td>
      <td class="num">${Math.round(h.score * 100)}%</td></tr>`).join("");
    c.innerHTML = banner + `<table><thead><tr><th>${t("名稱")}</th><th>${t("所在位置")}</th><th style="width:190px">${t("修改日期")}</th><th style="width:84px">${t("大小")}</th><th style="width:64px">${t("符合度")}</th></tr></thead><tbody>${rows}</tbody></table>`;
  }
  $("#gomatch")?.addEventListener("click", () => reveal(S.pathMatch.path, S.pathMatch.is_dir));
  updateStatus();
}

function renderDuplicates(c) {
  const d = S.dup;
  const root = d.root || S.cwd;
  let body = "";
  if (d.running) body = `<div class="row"><div class="spinner"></div>${t("掃描中…")} <button class="btn" id="stop">${t("停止")}</button></div>`;
  else if (d.groups && !d.groups.length) body = `<div class="sub">${t("沒有找到重複的檔案")}</div>`;
  else if (d.groups) {
    const wasted = d.groups.reduce((s, g) => s + g.wasted, 0);
    body = `<div class="row"><b>${t("{0} 組重複,可省下 {1}", d.groups.length, fmtBytes(wasted))}</b>
      <button class="btn danger" id="trashdups" ${d.checked.size ? "" : "disabled"}>${t("把勾選的 {0} 個移到資源回收筒", d.checked.size)}</button></div>
      <div class="sub">${t("每組預設保留最舊的一份")}</div>` +
      d.groups.slice(0, 500).map((g) => `<div class="group"><div class="group-head">${fmtBytes(g.size)} × ${g.files.length}</div>${g.files.map((f, i) => `
        <label class="dup"><input type="checkbox" data-path="${esc(f.path)}" ${d.checked.has(f.path) ? "checked" : ""}>
        ${fileSvg(f.name)}<span class="path" title="${esc(f.path)}">&lrm;${esc(f.path)}&lrm;</span>
        <span class="tag">${i === 0 ? t("保留") + " · " : ""}${fmtDate(f.modified)}</span></label>`).join("")}</div>`).join("");
  }
  c.innerHTML = `<div class="tool"><h2>${t("重複檔案")}</h2>
    <div class="row"><button class="btn primary" id="scan" ${d.running ? "disabled" : ""}>${esc(t("掃描「{0}」", baseName(root)))}</button></div>${body}</div>`;
  $("#scan").onclick = () => scanDuplicates(S.cwd);
  $("#stop")?.addEventListener("click", () => invoke("cancel_task"));
  $("#trashdups")?.addEventListener("click", async () => {
    const paths = [...d.checked];
    try {
      await invoke("trash_items", { paths });
      toast(t("已移到資源回收筒:{0} 個項目", paths.length));
      const gone = new Set(paths);
      d.groups = d.groups.map((g) => ({ ...g, files: g.files.filter((f) => !gone.has(f.path)) })).filter((g) => g.files.length > 1);
      d.checked = new Set();
      render();
    } catch (e) { failed(e); }
  });
  c.querySelectorAll(".dup input").forEach((cb) => cb.addEventListener("change", () => {
    cb.checked ? d.checked.add(cb.dataset.path) : d.checked.delete(cb.dataset.path);
    const b = $("#trashdups");
    b.disabled = !d.checked.size;
    b.textContent = t("把勾選的 {0} 個移到資源回收筒", d.checked.size);
  }));
  updateStatus();
}
async function scanDuplicates(root) {
  const d = S.dup;
  Object.assign(d, { running: true, groups: null, checked: new Set(), root });
  render();
  try {
    const groups = await invoke("find_duplicates", { root });
    if (d.root !== root) return;
    d.groups = groups;
    groups.forEach((g) => g.files.slice(1).forEach((f) => d.checked.add(f.path)));
  } catch (e) { failed(e); d.groups = null; }
  d.running = false;
  if (S.mode === "duplicates") render();
}

function renderUsage(c) {
  const u = S.usage;
  const dir = u.dir || S.cwd;
  let body = "";
  if (u.running) body = `<div class="row"><div class="spinner"></div>${t("掃描中…")} <button class="btn" id="stop">${t("停止")}</button></div>`;
  else if (u.rows) {
    const total = u.rows.reduce((s, r) => s + r.size, 0);
    const max = u.rows[0]?.size || 1;
    body = `<div class="row"><b>${esc(t("「{0}」佔用 {1}", baseName(dir), fmtBytes(total)))}</b></div>` +
      u.rows.slice(0, 300).map((r) => `<div class="usage-row" data-path="${esc(r.path)}" data-dir="${r.is_dir ? 1 : ""}" title="${esc(r.path)}">
        ${r.is_dir ? FOLDER_SVG : fileSvg(r.name)}<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(r.name)}${r.is_dir ? ` <small class="muted">· ${t("{0} 個檔案", r.files)}</small>` : ""}</span>
        <div class="bar"><i style="width:${Math.max(0.5, (r.size / max) * 100)}%"></i></div><span class="num" style="text-align:right">${fmtBytes(r.size)}</span></div>`).join("");
  } else body = `<div class="sub">${t("選一個資料夾,再按掃描")}</div>`;
  c.innerHTML = `<div class="tool"><h2>${t("空間分析")}</h2>
    <div class="row"><button class="btn" id="usageup">↑</button><button class="btn primary" id="scan" ${u.running ? "disabled" : ""}>${esc(t("掃描「{0}」", baseName(S.cwd)))}</button></div>${body}</div>`;
  $("#scan").onclick = () => scanUsage(S.cwd);
  $("#usageup").onclick = async () => { const p = await invoke("parent", { path: dir }); if (p) { await setCwdQuiet(p); scanUsage(p); } };
  $("#stop")?.addEventListener("click", () => invoke("cancel_task"));
  c.querySelectorAll(".usage-row").forEach((r) => r.addEventListener("dblclick", async () => {
    if (r.dataset.dir) { await setCwdQuiet(r.dataset.path); scanUsage(r.dataset.path); }
    else reveal(r.dataset.path, false);
  }));
  updateStatus();
}
async function scanUsage(dir) {
  const u = S.usage;
  Object.assign(u, { running: true, rows: null, dir });
  render();
  try {
    const rows = await invoke("disk_usage", { dir });
    if (u.dir !== dir) return;
    u.rows = rows;
  } catch (e) { failed(e); }
  u.running = false;
  if (S.mode === "usage") render();
}
/// 工具頁裡換資料夾:更新路徑列但不離開工具頁
async function setCwdQuiet(path) {
  S.cwd = path;
  await renderCrumbs();
}

function enterTool(mode) {
  clearSearch(false);
  S.mode = mode;
  document.querySelectorAll("#tools .side-item").forEach((b) => b.classList.toggle("active", b.dataset.mode === mode));
  renderCrumbs();
  render();
}
function leaveTool() {
  if (S.mode === "duplicates" || S.mode === "usage") invoke("cancel_task");
  S.mode = "browse";
  document.querySelectorAll("#tools .side-item").forEach((b) => b.classList.remove("active"));
}

function updateStatus() {
  let left = "";
  if (S.mode === "browse") left = t("{0} 個項目", S.entries.length);
  else if (S.mode === "search") left = t("{0} 個項目", S.hits.length);
  if (S.sel.size && (S.mode === "browse" || S.mode === "search")) left += " · " + t("已選取 {0} 個", S.sel.size);
  $("#status-left").textContent = left;
  $("#status-right").textContent = S.index.crawling
    ? t("建立索引中… 已找到 {0} 個項目", S.index.count.toLocaleString())
    : t("已索引 {0} 個項目", S.index.count.toLocaleString());
  $("#status-right").title = t("重建索引");
}
async function pollIndex() {
  const was = S.index.crawling;
  S.index = await invoke("index_status");
  updateStatus();
  if (was && !S.index.crawling && S.mode === "search") runSearch();
  setTimeout(pollIndex, S.index.crawling ? 700 : 5000);
}

// MARK: 選取

function rowPaths() {
  return [...document.querySelectorAll("#content tbody tr")].map((r) => r.dataset.path);
}
function paintSelection() {
  document.querySelectorAll("#content tbody tr").forEach((r) => r.classList.toggle("sel", S.sel.has(r.dataset.path)));
  updateStatus();
}
function clickRow(path, ev) {
  const order = rowPaths();
  if (ev.shiftKey && S.anchor && order.includes(S.anchor)) {
    const [a, b] = [order.indexOf(S.anchor), order.indexOf(path)].sort((x, y) => x - y);
    S.sel = new Set(order.slice(a, b + 1));
  } else if (ev.ctrlKey || ev.metaKey) {
    S.sel.has(path) ? S.sel.delete(path) : S.sel.add(path);
    S.anchor = path;
  } else {
    S.sel = new Set([path]);
    S.anchor = path;
  }
  paintSelection();
}
function moveSelection(delta, extend) {
  const order = rowPaths();
  if (!order.length) return;
  const cur = S.anchor && order.includes(S.anchor) ? order.indexOf(S.anchor) : delta > 0 ? -1 : order.length;
  const next = Math.min(order.length - 1, Math.max(0, cur + delta));
  if (!extend) S.sel = new Set();
  S.sel.add(order[next]);
  S.anchor = order[next];
  paintSelection();
  document.querySelectorAll("#content tbody tr")[next]?.scrollIntoView({ block: "nearest" });
}
/// 檔案全部用預設 App 開啟;資料夾只進入第一個
function openSelection() {
  const items = selectedItems();
  items.filter((i) => !i.isDir).forEach((i) => activate(i.path, false));
  const dir = items.find((i) => i.isDir);
  if (dir) navigate(dir.path);
}
function selectedItems() {
  return [...document.querySelectorAll("#content tbody tr")].filter((r) => S.sel.has(r.dataset.path)).map((r) => ({ path: r.dataset.path, isDir: !!r.dataset.dir }));
}

// MARK: 檔案操作

async function trashSelection() {
  const paths = [...S.sel];
  if (!paths.length) return;
  try {
    await invoke("trash_items", { paths });
    toast(t("已移到資源回收筒:{0} 個項目", paths.length));
    S.sel = new Set();
    if (S.mode === "search") { S.hits = S.hits.filter((h) => !paths.includes(h.path)); render(); }
    else reload();
  } catch (e) { failed(e); }
}
async function newFolder() {
  if (S.mode !== "browse") return;
  try {
    const p = await invoke("new_folder", { dir: S.cwd, baseName: t("未命名資料夾") });
    await navigate(S.cwd, { push: false, select: p });
    startRename(p);
  } catch (e) { failed(e); }
}
function startRename(path) {
  const row = [...document.querySelectorAll("#content tbody tr")].find((r) => r.dataset.path === path);
  const span = row?.querySelector(".name span");
  if (!span) return;
  const old = span.textContent;
  const input = document.createElement("input");
  input.value = old;
  span.replaceWith(input);
  input.focus();
  const dot = old.lastIndexOf(".");
  input.setSelectionRange(0, dot > 0 && !row.dataset.dir ? dot : old.length); // 不選副檔名
  let done = false;
  const finish = async (commit) => {
    if (done) return;
    done = true;
    if (commit && input.value.trim() && input.value !== old) {
      try {
        const np = await invoke("rename", { path, newName: input.value });
        if (S.mode === "search") { clearSearch(false); }
        return navigate(dirName(np), { push: S.mode !== "browse", select: np });
      } catch (e) { failed(e); }
    }
    render();
  };
  input.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Enter") finish(true);
    if (e.key === "Escape") finish(false);
  });
  input.addEventListener("blur", () => finish(true));
}

// MARK: 右鍵選單

function showMenu(x, y, items) {
  const m = $("#menu");
  m.innerHTML = items.map((it, i) => (it === "-" ? "<hr>" : `<button data-i="${i}" class="${it.danger ? "danger" : ""}">${esc(it.label)}</button>`)).join("");
  m.hidden = false;
  const r = m.getBoundingClientRect();
  m.style.left = Math.min(x, innerWidth - r.width - 4) + "px";
  m.style.top = Math.min(y, innerHeight - r.height - 4) + "px";
  m.onclick = (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    m.hidden = true;
    items[+b.dataset.i].run();
  };
}
function rowMenu(x, y) {
  const items = selectedItems();
  if (!items.length) return;
  const first = items[0];
  const menu = [
    { label: t("開啟"), run: openSelection },
    { label: t("在檔案總管中顯示"), run: () => invoke("reveal", { path: first.path }).catch(failed) },
  ];
  if (S.mode === "search") menu.push({ label: t("顯示所在位置"), run: () => reveal(first.path, false) });
  menu.push("-", { label: t("拷貝路徑"), run: () => copyText(items.map((i) => i.path).join("\r\n")) });
  if (items.length === 1) menu.push({ label: t("重新命名"), run: () => startRename(first.path) });
  menu.push("-", { label: t("移到資源回收筒"), danger: true, run: trashSelection });
  showMenu(x, y, menu);
}

// MARK: 事件

function bind() {
  $("#back").onclick = goBack;
  $("#forward").onclick = goForward;
  $("#up").onclick = goUp;
  $("#refresh").onclick = () => (S.mode === "search" ? runSearch() : reload());
  $("#newfolder").onclick = newFolder;
  $("#hidden").onclick = () => {
    S.showHidden = !S.showHidden;
    $("#hidden").classList.toggle("on", S.showHidden);
    reload();
  };
  $("#status-right").onclick = () => { invoke("rebuild_index"); S.index.crawling = true; setTimeout(pollIndex, 300); };

  $("#crumbs").addEventListener("click", (e) => {
    const c = e.target.closest(".crumb");
    // 點目前這一層(或空白處)就進入輸入模式,和檔案總管一樣
    if (c && !c.matches(":last-of-type")) navigate(c.dataset.path);
    else editPath();
  });
  const pi = $("#pathinput");
  pi.addEventListener("input", () => { $("#pathbox").classList.remove("notfound"); previewPath(pi.value); });
  pi.addEventListener("keydown", (e) => {
    e.stopPropagation();
    if (e.key === "Enter") commitPath();
    if (e.key === "Escape") endEditPath();
  });
  pi.addEventListener("blur", () => setTimeout(endEditPath, 120));

  const si = $("#search");
  si.addEventListener("input", () => { S.query = si.value; runSearch(); });
  si.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && S.pathMatch) { e.preventDefault(); reveal(S.pathMatch.path, S.pathMatch.is_dir); }
    if (e.key === "Escape") { clearSearch(); si.blur(); }
    if (e.key === "ArrowDown") { e.preventDefault(); si.blur(); moveSelection(1, false); }
  });
  $("#scope").onchange = () => S.query && runSearch();

  const c = $("#content");
  c.addEventListener("mousedown", (e) => {
    const tr = e.target.closest("tbody tr");
    if (e.target.closest("input")) return;
    if (!tr) {
      if (!e.target.closest("thead") && !e.target.closest(".tool") && e.button === 0) { S.sel = new Set(); paintSelection(); }
      return;
    }
    if (e.button === 2 && S.sel.has(tr.dataset.path)) return;
    clickRow(tr.dataset.path, e);
  });
  c.addEventListener("dblclick", (e) => {
    const tr = e.target.closest("tbody tr");
    if (tr) activate(tr.dataset.path, !!tr.dataset.dir);
  });
  c.addEventListener("click", (e) => {
    const th = e.target.closest("th[data-sort]");
    if (!th) return;
    const k = th.dataset.sort;
    S.sort = { key: k, desc: S.sort.key === k ? !S.sort.desc : false };
    render();
  });
  c.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    if (e.target.closest("tbody tr")) rowMenu(e.clientX, e.clientY);
    else if (S.mode === "browse") showMenu(e.clientX, e.clientY, [
      { label: t("新增資料夾"), run: newFolder },
      { label: t("重新整理"), run: reload },
      "-",
      { label: t("拷貝路徑"), run: () => copyText(S.cwd) },
    ]);
  });
  document.addEventListener("contextmenu", (e) => { if (!e.target.closest("input")) e.preventDefault(); });
  document.addEventListener("mousedown", (e) => { if (!e.target.closest("#menu")) $("#menu").hidden = true; });

  document.addEventListener("keydown", (e) => {
    const inField = e.target.matches("input, select");
    const ctrl = e.ctrlKey || e.metaKey;
    if ((ctrl && e.key.toLowerCase() === "l") || (e.altKey && e.key.toLowerCase() === "d") || (ctrl && e.shiftKey && e.key.toLowerCase() === "g")) {
      e.preventDefault(); return editPath();
    }
    if (ctrl && (e.key.toLowerCase() === "f" || e.key.toLowerCase() === "e")) { e.preventDefault(); si.focus(); si.select(); return; }
    if (ctrl && e.shiftKey && e.key.toLowerCase() === "n") { e.preventDefault(); return newFolder(); }
    if (e.key === "F5") { e.preventDefault(); return reload(); }
    if (e.altKey && e.key === "ArrowLeft") return goBack();
    if (e.altKey && e.key === "ArrowRight") return goForward();
    if (e.altKey && e.key === "ArrowUp") return goUp();
    if (inField) return;
    if (e.key === "Backspace") return goUp();
    if (e.key === "Escape") { $("#menu").hidden = true; if (S.mode === "search") clearSearch(); return; }
    if (S.mode !== "browse" && S.mode !== "search") return;
    if (e.key === "ArrowDown") { e.preventDefault(); return moveSelection(1, e.shiftKey); }
    if (e.key === "ArrowUp") { e.preventDefault(); return moveSelection(-1, e.shiftKey); }
    if (e.key === "Enter") return openSelection();
    if (e.key === "Delete") return trashSelection();
    if (e.key === "F2" && S.sel.size === 1) return startRename([...S.sel][0]);
    if (ctrl && e.key.toLowerCase() === "a") { e.preventDefault(); S.sel = new Set(rowPaths()); return paintSelection(); }
    if (ctrl && e.shiftKey && e.key.toLowerCase() === "c") { e.preventDefault(); return copyText([...S.sel].join("\r\n") || S.cwd); }
  });
  window.addEventListener("mousedown", (e) => {
    if (e.button === 3) goBack();
    if (e.button === 4) goForward();
  });

  document.querySelectorAll("#tools .side-item").forEach((b) => (b.onclick = () => enterTool(b.dataset.mode)));
  const lang = $("#lang");
  lang.onchange = () => { setLang(lang.value); applyTexts(); renderPlaces(); render(); };
}

function applyTexts() {
  document.documentElement.lang = LANG;
  document.querySelectorAll("[data-t]").forEach((el) => (el.textContent = t(el.dataset.t)));
  document.querySelectorAll("[data-title]").forEach((el) => (el.title = t(el.dataset.title)));
  $("#search").placeholder = t("搜尋");
  $("#pathinput").placeholder = t("輸入路徑,例如 /downloads 或 Backups\\資料夾");
  let saved = "";
  try { saved = localStorage.getItem("lang") || ""; } catch {}
  $("#lang").innerHTML = LANGS.map((l) => `<option value="${l.code}" ${l.code === saved ? "selected" : ""}>${esc(l.code ? l.name : t(l.name))}</option>`).join("");
}

function renderPlaces() {
  const item = (p) => `<button class="side-item" data-path="${esc(p.path)}" title="${esc(p.path)}"><span class="ico">${PLACE_ICONS[p.key] || "▪"}</span><span>${esc(p.key === "drive" ? p.name : t(PLACE_NAMES[p.key]))}</span></button>`;
  $("#places").innerHTML = S.places.filter((p) => p.key !== "drive").map(item).join("");
  $("#drives").innerHTML = S.places.filter((p) => p.key === "drive").map(item).join("");
  document.querySelectorAll("#places .side-item, #drives .side-item").forEach((b) => (b.onclick = () => navigate(b.dataset.path)));
  renderCrumbs();
}

async function main() {
  applyTexts();
  bind();
  S.places = await invoke("places");
  renderPlaces();
  let start = "";
  try { start = localStorage.getItem("cwd") || ""; } catch {}
  await navigate(start || (await invoke("home_dir")));
  if (S.error && start) await navigate(await invoke("home_dir"));
  pollIndex();
}
main();
