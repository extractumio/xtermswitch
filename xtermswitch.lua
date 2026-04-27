-- xtermswitch — iTerm2 session switcher for Hammerspoon
-- Hotkey-driven, glassy webview UI with grouping by local windows / SSH hosts,
-- agent (claude/codex) detection, last-line preview, live cache while open.
--
-- Default install: clone the repo, then add to ~/.hammerspoon/init.lua:
--     dofile(os.getenv("HOME") .. "/EXTRACTUM/xtermswitch/xtermswitch.lua")
--
-- User config (optional): ~/.xtermswitch/config.lua returning a table of
-- overrides, e.g.:
--     return {
--       hotkey = { mods = {"cmd","alt","ctrl"}, key = "T" },
--       list_iterms = nil,           -- override path to the bash script
--       cache_interval_open = 5,
--       width_max = 900,
--       width_factor = 0.55,
--       height_factor = 0.80,
--       show_load_alert = true,
--     }

hs.allowAppleScript(true)
require "hs.task"
require "hs.webview"
require "hs.json"
require "hs.timer"
require "hs.window"
require "hs.screen"
require "hs.drawing"
require "hs.application"

-- ============================================================
-- Self-location & config
-- ============================================================
local function script_dir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return src:match("(.*/)") or "./"
end

local DIR  = script_dir()
local HOME = os.getenv("HOME")

local config = {
  hotkey              = { mods = {"cmd", "alt", "ctrl"}, key = "T" },
  list_iterms         = DIR .. "bin/list-iterms",
  cache_interval_open = 5,
  width_max           = 900,
  width_factor        = 0.55,
  height_factor       = 0.80,
  show_load_alert     = true,
}

do
  local user_cfg = HOME .. "/.xtermswitch/config.lua"
  local f = io.open(user_cfg, "r")
  if f then
    f:close()
    local ok, user = pcall(dofile, user_cfg)
    if ok and type(user) == "table" then
      for k, v in pairs(user) do config[k] = v end
    else
      print("xtermswitch: failed to load " .. user_cfg .. ": " .. tostring(user))
    end
  end
end

local SCRIPT = config.list_iterms

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- Ensure the bash script is executable (no-op if already +x).
hs.execute("chmod +x " .. shq(SCRIPT) .. " 2>/dev/null")

-- ============================================================
-- Helpers
-- ============================================================
local function shell(cmd)
  local h = io.popen(cmd, "r"); if not h then return nil end
  local out = h:read("*a"); h:close(); return out
end
local function basename(p)
  if not p or p == "" then return "" end
  return p:match("([^/]+)/?$") or p
end
local function cleanTitle(t)
  if not t then return "" end
  t = t:gsub("^Default:%s*", "")
  t = t:gsub("^[%z\1-\127\194-\244][\128-\191]*%s+", "")
  t = t:gsub("%s+[—-]%s+[^—-]+$", "")
  t = t:gsub("%s*%([^)]*interactive%-bash[^)]*%)%s*", " ")
  return (t:gsub("%s+$", ""))
end
local function shortRun(s)
  if not s or s == "" then return "" end
  local first = s:match("^(%S+)") or s
  return basename(first):sub(1, 20)
end

local function buildTreeFromSessions(data)
  if type(data) ~= "table" then return {groups = {}} end

  -- Note: iTerm hides the tmux-CC controller session from AppleScript, so no
  -- JSON entry has tmux_cc_controller=true. The host for a virtual session
  -- comes from bash (`bin/list-iterms` scans `ps` and writes it into ssh_host).
  -- Trust the JSON; don't re-derive here.

  local locWins, lwMap = {}, {}
  local remHosts, rhMap = {}, {}
  local function getRem(host)
    if not rhMap[host] then
      rhMap[host] = {host = host, sessions = {}}
      table.insert(remHosts, rhMap[host])
    end
    return rhMap[host]
  end
  local function entry(s)
    local title = cleanTitle(s.title)
    if title == "" then title = basename(s.cwd or "") end
    local hostLabel = ""
    if s.ssh_host and s.ssh_host ~= "" then
      if s.tmux_cc_virtual then
        hostLabel = "tmux-CC @ " .. s.ssh_host
      elseif s.tmux_cc_controller then
        hostLabel = "tmux-CC → " .. s.ssh_host
      else
        hostLabel = "ssh → " .. s.ssh_host
      end
    end
    local processing = (s.processing == true) or (tonumber(s.cpu) or 0) >= 5
    return {
      uid = s.uid,
      title = title ~= "" and title or "(untitled)",
      cwd = s.cwd or "",
      host = hostLabel,
      agent = s.agent or "",
      cpu = tonumber(s.cpu) or 0,
      processing = processing,
      lastLine = s.last_line or "",
      running = s.running or "",
      runShort = shortRun(s.running),
      kind = s.tmux_cc_virtual and "tmux"
             or (s.ssh_host and s.ssh_host ~= "") and "ssh"
             or "local",
    }
  end

  for _, s in ipairs(data) do
    if s.tmux_cc_virtual then
      local host = (s.ssh_host and s.ssh_host ~= "") and s.ssh_host or "tmux-CC"
      local r = getRem(host)
      table.insert(r.sessions, entry(s))
      r.tmuxCC = true
    elseif s.ssh_host and s.ssh_host ~= "" then
      local r = getRem(s.ssh_host)
      table.insert(r.sessions, entry(s))
      if s.tmux_cc_controller then r.tmuxCC = true end
    else
      if not lwMap[s.win] then
        lwMap[s.win] = {id = s.win, sessions = {}}
        table.insert(locWins, lwMap[s.win])
      end
      table.insert(lwMap[s.win].sessions, entry(s))
    end
  end
  table.sort(locWins, function(a,b) return a.id < b.id end)
  table.sort(remHosts, function(a,b) return (a.host or "") < (b.host or "") end)

  local groups = {}
  if #locWins > 0 then
    local count = 0; for _, w in ipairs(locWins) do count = count + #w.sessions end
    local windows = {}
    for _, w in ipairs(locWins) do
      table.insert(windows, {
        label = string.format("iTerm %d", w.id),
        sessions = w.sessions,
      })
    end
    table.insert(groups, {kind="local", label="Local", count=count, windows=windows})
  end
  for _, r in ipairs(remHosts) do
    table.insert(groups, {
      kind = r.tmuxCC and "tmux" or "ssh",
      label = (r.tmuxCC and "tmux-CC · " or "SSH · ") .. (r.host or "?"),
      count = #r.sessions,
      windows = {{label = nil, sessions = r.sessions}},
    })
  end
  return {groups = groups}
end

-- ============================================================
-- HTML / CSS / JS
-- ============================================================
local HTML = [==[
<!doctype html>
<html><head><meta charset="utf-8">
<style>
  :root {
    color-scheme: dark;
    --bg: rgba(22,22,24,0.96);
    --border: rgba(255,255,255,0.10);
    --divider: rgba(255,255,255,0.06);
    --fg: #f5f5f7;
    --muted: rgba(255,255,255,0.55);
    --dim: rgba(255,255,255,0.42);
    --c-local: #5b9eff;
    --c-ssh: #4dd693;
    --c-tmux: #ffa845;
    --c-agent: #c4a8ff;
    --c-pulse: #5fd57f;
    --sel-bg: linear-gradient(180deg, rgba(10,132,255,0.95), rgba(10,120,235,0.95));
    /* Shared horizontal rhythm — keeps icon columns aligned across group/window/row. */
    --pad-x: 22px;
    --col-icon: 32px;
    --col-icon-sm: 26px;
    --gap: 12px;
  }
  html, body {
    margin: 0; padding: 0; height: 100%;
    background: transparent; overflow: hidden;
    font-family: -apple-system, "SF Pro Text", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  #app {
    height: 100%;
    background: var(--bg);
    backdrop-filter: blur(40px) saturate(180%);
    -webkit-backdrop-filter: blur(40px) saturate(180%);
    border-radius: 14px;
    border: 0.5px solid var(--border);
    box-shadow: 0 24px 80px rgba(0,0,0,0.65);
    display: flex; flex-direction: column;
    color: var(--fg);
  }
  #search {
    padding: 18px var(--pad-x);
    border: 0; background: transparent; outline: none;
    color: #fff;
    font-size: 21px; font-weight: 600; letter-spacing: -0.01em;
    border-bottom: 0.5px solid var(--divider);
  }
  #search::placeholder { color: var(--dim); font-weight: 500; }
  #list { flex: 1; overflow-y: auto; padding: 6px 0 12px; }
  #list::-webkit-scrollbar { width: 8px; }
  #list::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14); border-radius: 4px; }
  #list::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.22); }

  /* Section header (Local / SSH · host / tmux-CC · host) */
  .group {
    display: flex; align-items: center; gap: 10px;
    padding: 16px var(--pad-x) 8px;
    font-size: 12px; font-weight: 800; letter-spacing: 0.12em; text-transform: uppercase;
    color: rgba(255,255,255,0.72);
    cursor: pointer; user-select: none;
  }
  .group .chev { width: 11px; height: 11px; transition: transform .15s; opacity: 0.7; flex-shrink: 0; }
  .group.collapsed .chev { transform: rotate(-90deg); }
  .group .icon-wrap {
    width: var(--col-icon-sm); height: var(--col-icon-sm);
    display: flex; align-items: center; justify-content: center;
    border-radius: 7px; flex-shrink: 0;
  }
  .group .icon-wrap svg { width: 16px; height: 16px; }
  .group .label { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .group .count {
    font-size: 11px; font-weight: 600; padding: 2px 9px; border-radius: 10px;
    letter-spacing: 0; flex-shrink: 0;
  }
  .group.local .icon-wrap { background: rgba(91,158,255,0.16);  color: var(--c-local); }
  .group.ssh   .icon-wrap { background: rgba(77,214,147,0.16);  color: var(--c-ssh); }
  .group.tmux  .icon-wrap { background: rgba(255,168,69,0.18);  color: var(--c-tmux); }
  .group.local .count { background: rgba(91,158,255,0.18); color: #87b9ff; }
  .group.ssh   .count { background: rgba(77,214,147,0.18); color: #6fdfb0; }
  .group.tmux  .count { background: rgba(255,168,69,0.20); color: #ffc27a; }

  /* Per-iTerm-window subheader (only for local groups). */
  .window {
    display: flex; align-items: center; gap: 8px;
    padding: 8px var(--pad-x) 4px 30px;
    font-size: 12.5px; color: rgba(255,255,255,0.62); font-weight: 600;
    letter-spacing: 0.02em;
    cursor: pointer; user-select: none;
  }
  .window .chev { width: 10px; height: 10px; transition: transform .15s; opacity: 0.50; flex-shrink: 0; }
  .window.collapsed .chev { transform: rotate(-90deg); }
  .window .meta { opacity: 0.55; font-weight: 500; }

  /* Session row — fixed icon column at 50px so every row icon snaps to the
     same vertical line regardless of nesting under a window subheader. */
  .row {
    display: flex; align-items: center; gap: var(--gap);
    padding: 10px 14px 10px 50px;
    margin: 1px 8px;
    border-radius: 9px;
    cursor: pointer;
    transition: background-color 0.08s;
  }
  .row .icon-wrap {
    width: var(--col-icon); height: var(--col-icon);
    display: flex; align-items: center; justify-content: center;
    border-radius: 8px;
    flex-shrink: 0;
  }
  .row .icon-wrap svg { width: 18px; height: 18px; }
  .row.local .icon-wrap { background: linear-gradient(135deg, rgba(91,158,255,0.24), rgba(91,158,255,0.10)); color: var(--c-local); }
  .row.ssh   .icon-wrap { background: linear-gradient(135deg, rgba(77,214,147,0.24), rgba(77,214,147,0.10)); color: var(--c-ssh); }
  .row.tmux  .icon-wrap { background: linear-gradient(135deg, rgba(255,168,69,0.26), rgba(255,168,69,0.12)); color: var(--c-tmux); }
  .row .text { flex: 1; min-width: 0; }
  .row .title {
    font-size: 15px; font-weight: 700; color: #fff;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    line-height: 1.25;
  }
  /* Path/cwd line — same size as title; weight a notch lower for hierarchy. */
  .row .sub {
    font-size: 15px; color: var(--muted); font-weight: 500;
    font-family: "SF Mono", ui-monospace, Menlo, monospace;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    line-height: 1.3; margin-top: 3px;
    display: flex; gap: 10px; align-items: center;
  }
  .row .cwd  { color: #e6cd9a; font-weight: 600; }
  .row .host { color: rgba(135,180,255,0.85); font-weight: 600; font-size: 12.5px; }
  .row .sep  { opacity: 0.32; }
  .row .last {
    font-size: 12px; color: rgba(255,255,255,0.55); font-weight: 500;
    font-style: italic;
    font-family: -apple-system, "SF Pro Text", system-ui, sans-serif;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
    line-height: 1.4; margin-top: 3px;
  }

  .pulse {
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--c-pulse);
    box-shadow: 0 0 0 0 rgba(95,213,127,0.7);
    animation: pulse 1.4s infinite;
    flex-shrink: 0;
  }
  .pulse.idle { background: rgba(255,255,255,0.22); animation: none; box-shadow: none; }
  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 rgba(95,213,127,0.55); }
    70%  { box-shadow: 0 0 0 8px rgba(95,213,127,0); }
    100% { box-shadow: 0 0 0 0 rgba(95,213,127,0); }
  }

  .row .badge {
    font-size: 11.5px; font-weight: 700;
    padding: 3px 8px; border-radius: 5px;
    background: rgba(255,255,255,0.12); color: rgba(255,255,255,0.85);
    flex-shrink: 0;
    font-family: "SF Mono", ui-monospace, monospace;
  }
  .row.has-claude .badge { background: rgba(157,122,255,0.22); color: var(--c-agent); }

  .row.sel { background: var(--sel-bg); }
  .row.sel .title { color: #fff; }
  .row.sel .sub   { color: rgba(255,255,255,0.85); }
  .row.sel .last  { color: rgba(255,255,255,0.85); }
  .row.sel .badge { background: rgba(255,255,255,0.22); color: #fff; }
  .row.sel .icon-wrap { background: rgba(255,255,255,0.22); color: #fff; }
  .row.sel .cwd   { color: #ffe9b8; }
  .row.sel .host  { color: #cfe1ff; }

  .hidden { display: none !important; }

  #footer {
    padding: 9px 18px;
    border-top: 0.5px solid var(--divider);
    font-size: 11.5px; color: var(--dim);
    display: flex; gap: 18px; justify-content: flex-end;
    font-family: "SF Mono", ui-monospace, monospace;
  }
  #footer kbd {
    padding: 1px 6px; border-radius: 4px;
    background: rgba(255,255,255,0.10); color: rgba(255,255,255,0.78);
    font-family: inherit; font-size: 11px;
  }
</style></head>
<body>
<div id="app">
  <input id="search" placeholder="Search sessions, hosts, paths…" autofocus spellcheck="false" />
  <div id="list"></div>
  <div id="footer">
    <span><kbd>↑↓</kbd> navigate</span>
    <span><kbd>↵</kbd> focus</span>
    <span><kbd>esc</kbd> close</span>
  </div>
</div>
<script>
const TREE = __TREE_JSON__;
const send = m => window.webkit.messageHandlers["iterm-switcher"].postMessage(m);
const esc = s => String(s||'').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

const list = document.getElementById('list');
const search = document.getElementById('search');

let rows = [];
let leafIdx = [];
let cursor = 0;

// Heroicons-outline 24×24 (MIT, https://github.com/tailwindlabs/heroicons),
// mirrored on svgrepo. Inner markup only — wrapped with currentColor.
const ICON_PATHS = {
  local: '<path stroke-linecap="round" stroke-linejoin="round" d="M9 17.25v1.007a3 3 0 0 1-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0 1 15 18.257V17.25m6-12V15a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 15V5.25m18 0A2.25 2.25 0 0 0 18.75 3H5.25A2.25 2.25 0 0 0 3 5.25m18 0V12a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 12V5.25"/>',
  ssh:   '<path stroke-linecap="round" stroke-linejoin="round" d="M5.25 14.25h13.5m-13.5 0a3 3 0 0 1-3-3m3 3a3 3 0 1 0 0 6h13.5a3 3 0 1 0 0-6m-16.5-3a3 3 0 0 1 3-3h13.5a3 3 0 0 1 3 3m-19.5 0a4.5 4.5 0 0 1 .9-2.7L5.737 5.1a3.375 3.375 0 0 1 2.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 0 1 .9 2.7m0 0a3 3 0 0 1-3 3m0 3h.008v.008h-.008v-.008Zm0-6h.008v.008h-.008v-.008Zm-3 6h.008v.008h-.008v-.008Zm0-6h.008v.008h-.008v-.008Z"/>',
  tmux:  '<path stroke-linecap="round" stroke-linejoin="round" d="M6 6.878V6a2.25 2.25 0 0 1 2.25-2.25h7.5A2.25 2.25 0 0 1 18 6v.878m-12 0c.235-.083.487-.128.75-.128h10.5c.263 0 .515.045.75.128m-12 0A2.25 2.25 0 0 0 4.5 9v.878m13.5-3A2.25 2.25 0 0 1 19.5 9v.878m0 0a2.246 2.246 0 0 0-.75-.128H5.25c-.263 0-.515.045-.75.128m15 0A2.25 2.25 0 0 1 21 12v6a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 18v-6c0-.98.626-1.813 1.5-2.122"/>',
};
function svgIcon(kind) {
  const inner = ICON_PATHS[kind] || ICON_PATHS.local;
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6">${inner}</svg>`;
}

function render() {
  list.innerHTML = '';
  rows = [];
  TREE.groups.forEach(g => {
    const ge = document.createElement('div');
    ge.className = `group ${g.kind}`;
    ge.innerHTML = `
      <svg class="chev" viewBox="0 0 10 10" width="11" height="11"><path fill="currentColor" d="M2 3l3 4 3-4z"/></svg>
      <span class="icon-wrap">${svgIcon(g.kind)}</span>
      <span class="label">${esc(g.label)}</span>
      <span class="count">${g.count}</span>`;
    list.appendChild(ge);
    const grec = {el: ge, group: g, children: []};
    rows.push(grec);
    ge.addEventListener('click', () => toggle(grec));

    g.windows.forEach(w => {
      let wrec = grec;
      if (w.label) {
        const we = document.createElement('div');
        we.className = 'window';
        we.innerHTML = `
          <svg class="chev" viewBox="0 0 10 10" width="10" height="10"><path fill="currentColor" d="M2 3l3 4 3-4z"/></svg>
          <span>${esc(w.label)}</span>
          <span class="meta">·  ${w.sessions.length} session${w.sessions.length===1?'':'s'}</span>`;
        list.appendChild(we);
        wrec = {el: we, win: w, parent: grec, children: []};
        rows.push(wrec);
        grec.children.push(wrec);
        we.addEventListener('click', () => toggle(wrec));
      }
      w.sessions.forEach(s => {
        const r = document.createElement('div');
        const isAgent = !!s.agent;
        const active = !!s.processing;
        r.className = `row ${s.kind} ${isAgent?'has-claude':''}`;
        // Host context lives in the group header (e.g. "tmux-CC · 10.195.48.28"),
        // so the row only needs to show its cwd.
        const sub = s.cwd ? `<span class="cwd">${esc(s.cwd)}</span>` : '';
        const cpuStr = (s.cpu >= 5) ? ` ${s.cpu.toFixed(0)}%` : '';
        const badge = s.agent
          ? `<span class="badge">${esc(s.agent)}${cpuStr}</span>`
          : (s.runShort ? `<span class="badge">${esc(s.runShort)}</span>` : '');
        const dot = isAgent ? `<div class="pulse ${active?'':'idle'}"></div>` : '';
        const lastLine = s.lastLine ? `<div class="last">${esc(s.lastLine)}</div>` : '';
        r.innerHTML = `
          <div class="icon-wrap">${svgIcon(s.kind)}</div>
          <div class="text">
            <div class="title">${esc(s.title)}</div>
            <div class="sub">${sub}</div>
            ${lastLine}
          </div>
          ${dot}${badge}`;
        r.addEventListener('click', () => send(s.uid));
        r.addEventListener('mouseenter', () => {
          const li = leafIdx.indexOf(rows.length);
          if (li >= 0) { cursor = li; updateSel(); }
        });
        list.appendChild(r);
        const lrec = {el: r, leaf: s, parent: wrec};
        rows.push(lrec);
        wrec.children.push(lrec);
      });
    });
  });
  applyFilter();
}

function toggle(rec) {
  rec.el.classList.toggle('collapsed');
  const collapsed = rec.el.classList.contains('collapsed');
  rec.children.forEach(c => setVis(c, !collapsed));
  refreshLeafIdx();
}
function setVis(rec, vis) {
  rec.el.classList.toggle('hidden', !vis);
  if (rec.children) rec.children.forEach(c => setVis(c, vis && !rec.el.classList.contains('collapsed')));
}

function applyFilter() {
  const q = search.value.trim().toLowerCase();
  rows.forEach(r => r.el.classList.remove('hidden'));
  if (q) {
    rows.forEach(r => {
      if (r.leaf) {
        const hay = (r.leaf.title + ' ' + (r.leaf.cwd||'') + ' ' + (r.leaf.host||'') + ' ' + (r.leaf.running||'')).toLowerCase();
        if (!hay.includes(q)) r.el.classList.add('hidden');
      }
    });
    rows.forEach(r => {
      if (r.group || r.win) {
        const any = r.children.some(c => !c.el.classList.contains('hidden'));
        if (!any) r.el.classList.add('hidden');
      }
    });
  }
  refreshLeafIdx();
}

function refreshLeafIdx() {
  leafIdx = [];
  rows.forEach((r,i) => { if (r.leaf && !r.el.classList.contains('hidden')) leafIdx.push(i); });
  if (cursor >= leafIdx.length) cursor = Math.max(0, leafIdx.length-1);
  updateSel();
}
function updateSel() {
  rows.forEach(r => r.el.classList.remove('sel'));
  if (!leafIdx.length) return;
  const r = rows[leafIdx[cursor]];
  r.el.classList.add('sel');
  r.el.scrollIntoView({block:'nearest'});
}

document.addEventListener('keydown', e => {
  if (e.key === 'Escape') { send('close'); return; }
  if (e.key === 'Enter') {
    if (leafIdx.length) send(rows[leafIdx[cursor]].leaf.uid);
    return;
  }
  if (e.key === 'ArrowDown' || (e.ctrlKey && e.key.toLowerCase() === 'n')) {
    e.preventDefault();
    if (leafIdx.length) { cursor = (cursor+1) % leafIdx.length; updateSel(); }
  } else if (e.key === 'ArrowUp' || (e.ctrlKey && e.key.toLowerCase() === 'p')) {
    e.preventDefault();
    if (leafIdx.length) { cursor = (cursor-1+leafIdx.length) % leafIdx.length; updateSel(); }
  }
});
search.addEventListener('input', () => { cursor = 0; applyFilter(); });

window.applyData = function(jsonStr) {
  try {
    const fresh = JSON.parse(jsonStr);
    const q = search.value;
    const oldCursor = cursor;
    TREE.groups = fresh.groups;
    render();
    search.value = q;
    cursor = Math.min(oldCursor, leafIdx.length - 1);
    if (cursor < 0) cursor = 0;
    applyFilter();
  } catch (e) { console.error(e); }
};

render();
search.focus();
</script></body></html>
]==]

local webview, ucc, appWatcher, hasFocused

-- ============================================================
-- Cache: zero work while idle. Refresh only on demand.
-- ============================================================
local cache = nil
local cacheTimer = nil

local function rebuildAndPushToWebview()
  if not cache or not webview then return end
  local treeJson = hs.json.encode(cache)
  treeJson = treeJson:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n")
  webview:evaluateJavaScript("if(window.applyData) applyData('" .. treeJson .. "')")
end

local activeTask = nil
local function refreshCache(onDone)
  if activeTask then return end
  activeTask = hs.task.new(SCRIPT, function(exitCode, stdout, stderr)
    activeTask = nil
    if exitCode ~= 0 or not stdout or stdout == "" then
      print("xtermswitch refreshCache: rc=" .. tostring(exitCode) ..
            " err=" .. tostring(stderr):sub(1, 200))
      return
    end
    local ok, data = pcall(hs.json.decode, stdout)
    if not ok or type(data) ~= "table" then
      print("xtermswitch refreshCache: json decode failed")
      return
    end
    cache = buildTreeFromSessions(data)
    _G.itermCache = cache
    if webview then rebuildAndPushToWebview() end
    if onDone then onDone() end
  end, {"json"})
  activeTask:start()
end

local function startCacheTimer(interval)
  if cacheTimer then cacheTimer:stop() end
  cacheTimer = hs.timer.doEvery(interval, function() refreshCache() end)
end
local function stopCacheTimer()
  if cacheTimer then cacheTimer:stop(); cacheTimer = nil end
end

local function close()
  if appWatcher then appWatcher:stop(); appWatcher = nil end
  if webview then
    webview:hide(); webview:delete(); webview = nil
  end
  ucc = nil
  hasFocused = false
  stopCacheTimer()
end

local function focusUid(uid)
  hs.task.new(SCRIPT, function() end, {"focus", uid}):start()
  close()
end

local function show()
  close()
  local screen = hs.screen.mainScreen():frame()
  local W = math.min(config.width_max, math.floor(screen.w * config.width_factor))
  local H = math.floor(screen.h * config.height_factor)
  local rect = {
    x = screen.x + (screen.w - W) / 2,
    y = screen.y + (screen.h - H) / 2,
    w = W, h = H,
  }

  ucc = hs.webview.usercontent.new("iterm-switcher")
  ucc:setCallback(function(msg)
    local body = msg and msg.body
    if type(body) ~= "string" then return end
    if body == "close" then close()
    else focusUid(body) end
  end)

  webview = hs.webview.new(rect, {
    developerExtrasEnabled = true,
    suppressesIncrementalRendering = true,
  }, ucc)
  webview:windowStyle({"borderless", "closable"})
  webview:level(hs.drawing.windowLevels.modalPanel)
  webview:closeOnEscape(true)
  webview:transparent(true)
  webview:bringToFront(true)
  webview:allowTextEntry(true)
  webview:shadow(true)

  if not cache then
    local raw = shell(shq(SCRIPT) .. " json 2>/dev/null") or "[]"
    local ok, data = pcall(hs.json.decode, raw)
    cache = buildTreeFromSessions(ok and data or {})
  end

  local treeJson = hs.json.encode(cache)
  local html = HTML:gsub("__TREE_JSON__", function() return treeJson end)
  webview:html(html)
  webview:show()
  hs.timer.doAfter(0.05, function()
    if webview and webview:hswindow() then webview:hswindow():focus() end
  end)

  startCacheTimer(config.cache_interval_open)
  hs.timer.doAfter(0.1, refreshCache)

  -- Auto-hide when any other app activates.
  hasFocused = false
  appWatcher = hs.application.watcher.new(function(name, eventType, _app)
    if eventType ~= hs.application.watcher.activated then return end
    if name == "Hammerspoon" then
      hasFocused = true
    elseif hasFocused then
      close()
    end
  end)
  appWatcher:start()
end

-- ============================================================
-- Public API + hotkey
-- ============================================================
_G.itermShow         = show
_G.itermClose        = close
_G.itermRefreshCache = refreshCache

if config.hotkey and config.hotkey.mods and config.hotkey.key then
  hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, show)
end

-- One-shot cache warm so the first hotkey press is instant.
refreshCache()

if config.show_load_alert then
  local label = "⌘⌥⌃" .. (config.hotkey and config.hotkey.key or "?")
  hs.alert.show("xtermswitch loaded — " .. label)
end
