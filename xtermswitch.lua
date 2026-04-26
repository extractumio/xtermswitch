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

  local soleHost, n = nil, 0
  for _, s in ipairs(data) do
    if s.tmux_cc_controller then n = n + 1; soleHost = s.ssh_host end
  end
  if n ~= 1 then soleHost = nil end

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
      kind = (s.tmux_cc_virtual or (s.ssh_host and s.ssh_host ~= "")) and "remote" or "local",
    }
  end

  for _, s in ipairs(data) do
    if s.tmux_cc_virtual then
      table.insert(getRem(soleHost or "tmux-CC").sessions, entry(s))
    elseif s.ssh_host and s.ssh_host ~= "" then
      local r = getRem(s.ssh_host)
      table.insert(r.sessions, entry(s))
      if s.tmux_cc_controller then r.controller = true end
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
      kind = "remote",
      label = (r.controller and "tmux-CC · " or "SSH · ") .. (r.host or "?"),
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
  :root { color-scheme: dark; }
  html,body { margin:0; padding:0; height:100%; background:transparent; overflow:hidden;
              font-family:-apple-system, "SF Pro Text", system-ui, sans-serif;
              -webkit-font-smoothing:antialiased; }
  #app {
    height:100%;
    background: rgba(22,22,24,0.95);
    backdrop-filter: blur(40px) saturate(180%);
    -webkit-backdrop-filter: blur(40px) saturate(180%);
    border-radius:14px;
    border: 0.5px solid rgba(255,255,255,0.12);
    box-shadow: 0 24px 80px rgba(0,0,0,0.65);
    display:flex; flex-direction:column;
    color:#f5f5f7;
  }
  #search {
    padding:18px 22px;
    border:0; background:transparent; outline:none;
    color:#fff; font-size:20px; font-weight:600; letter-spacing:-0.01em;
    border-bottom: 0.5px solid rgba(255,255,255,0.10);
  }
  #search::placeholder { color: rgba(255,255,255,0.40); font-weight:500; }
  #list { flex:1; overflow-y:auto; padding:8px 0 12px; }
  #list::-webkit-scrollbar { width:8px; }
  #list::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.14); border-radius:4px; }
  #list::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.22); }

  .group {
    display:flex; align-items:center; gap:10px;
    padding:14px 22px 6px;
    font-size:11px; font-weight:800; letter-spacing:0.12em; text-transform:uppercase;
    color: rgba(255,255,255,0.70);
    cursor:pointer; user-select:none;
  }
  .group .chev { width:10px; transition:transform .15s; opacity:0.7; }
  .group.collapsed .chev { transform:rotate(-90deg); }
  .group .icon { font-size:14px; opacity:0.85; }
  .group .count {
    font-size:10px; font-weight:500; padding:2px 7px; border-radius:9px;
    background: rgba(255,255,255,0.08); color: rgba(255,255,255,0.55);
    letter-spacing:0;
  }
  .group.local .count { background: rgba(64,156,255,0.18); color:#7ab8ff; }
  .group.remote .count { background: rgba(255,159,90,0.18); color:#ffb37a; }

  .window {
    display:flex; align-items:center; gap:8px;
    padding:6px 22px 4px 38px;
    font-size:12px; color: rgba(255,255,255,0.70); font-weight:700;
    cursor:pointer; user-select:none;
  }
  .window .chev { width:9px; transition:transform .15s; opacity:0.55; }
  .window.collapsed .chev { transform:rotate(-90deg); }

  .row {
    display:flex; align-items:center; gap:12px;
    padding:9px 14px;
    margin: 1px 8px;
    border-radius:8px;
    cursor:pointer;
    transition: background-color 0.08s;
  }
  .row.indent { padding-left:46px; }
  .row.indent2 { padding-left:62px; }
  .row .icon {
    width:28px; height:28px; flex-shrink:0;
    display:flex; align-items:center; justify-content:center;
    border-radius:7px;
    font-size:14px;
    background: rgba(255,255,255,0.06);
  }
  .row.local .icon { background: linear-gradient(135deg, rgba(64,156,255,0.22), rgba(64,156,255,0.10)); color:#7ab8ff; }
  .row.remote .icon { background: linear-gradient(135deg, rgba(255,159,90,0.22), rgba(255,159,90,0.10)); color:#ffb37a; }
  .row .text { flex:1; min-width:0; }
  .row .title {
    font-size:14px; font-weight:700; color:#fff;
    white-space:nowrap; overflow:hidden; text-overflow:ellipsis;
    line-height:1.25;
  }
  .row .sub {
    font-size:11.5px; color: rgba(255,255,255,0.55); font-weight:500;
    font-family: "SF Mono", ui-monospace, Menlo, monospace;
    white-space:nowrap; overflow:hidden; text-overflow:ellipsis;
    line-height:1.4; margin-top:2px;
    display:flex; gap:10px; align-items:center;
  }
  .row .cwd { color:#e6cd9a; font-weight:700; }
  .row .host { color: rgba(135,180,255,0.85); font-weight:600; }
  .row .sep { opacity:0.35; }
  .row.sel .cwd  { color:#ffe9b8; }
  .row.sel .host { color:#cfe1ff; }
  .row .last {
    font-size:11px; color: rgba(255,255,255,0.50); font-weight:500;
    font-style: italic;
    font-family: -apple-system, "SF Pro Text", system-ui, sans-serif;
    white-space:nowrap; overflow:hidden; text-overflow:ellipsis;
    line-height:1.4; margin-top:3px;
  }
  .row.sel .last { color: rgba(255,255,255,0.85); }

  .pulse {
    width:8px; height:8px; border-radius:50%;
    background:#5fd57f;
    box-shadow: 0 0 0 0 rgba(95,213,127,0.7);
    animation: pulse 1.4s infinite;
    flex-shrink:0;
  }
  .pulse.idle { background: rgba(255,255,255,0.20); animation:none; box-shadow:none; }
  @keyframes pulse {
    0%   { box-shadow: 0 0 0 0 rgba(95,213,127,0.55); }
    70%  { box-shadow: 0 0 0 8px rgba(95,213,127,0); }
    100% { box-shadow: 0 0 0 0 rgba(95,213,127,0); }
  }
  .row .badge {
    font-size:10.5px; font-weight:700;
    padding:3px 8px; border-radius:5px;
    background: rgba(255,255,255,0.12); color: rgba(255,255,255,0.85);
    flex-shrink:0;
    font-family:"SF Mono", ui-monospace, monospace;
  }
  .row.has-claude .badge { background: rgba(140,90,255,0.22); color:#c4a8ff; }

  .row.sel { background: linear-gradient(180deg, rgba(10,132,255,0.92), rgba(10,120,235,0.92)); }
  .row.sel .title { color:#fff; }
  .row.sel .sub   { color: rgba(255,255,255,0.85); }
  .row.sel .badge { background: rgba(255,255,255,0.22); color:#fff; }
  .row.sel .icon  { background: rgba(255,255,255,0.20); color:#fff; }

  .hidden { display:none !important; }

  #footer {
    padding:8px 18px;
    border-top: 0.5px solid rgba(255,255,255,0.06);
    font-size:10.5px; color: rgba(255,255,255,0.40);
    display:flex; gap:18px; justify-content:flex-end;
    font-family:"SF Mono", ui-monospace, monospace;
  }
  #footer kbd {
    padding:1px 6px; border-radius:4px;
    background: rgba(255,255,255,0.10); color: rgba(255,255,255,0.75);
    font-family:inherit; font-size:10px;
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

function makeIcon(kind) {
  return kind === 'local' ? '🖥' : '🌐';
}

function render() {
  list.innerHTML = '';
  rows = [];
  TREE.groups.forEach(g => {
    const ge = document.createElement('div');
    ge.className = `group ${g.kind}`;
    ge.innerHTML = `
      <svg class="chev" viewBox="0 0 10 10" width="10" height="10"><path fill="currentColor" d="M2 3l3 4 3-4z"/></svg>
      <span class="icon">${makeIcon(g.kind)}</span>
      <span>${esc(g.label)}</span>
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
          <svg class="chev" viewBox="0 0 10 10" width="9" height="9"><path fill="currentColor" d="M2 3l3 4 3-4z"/></svg>
          <span>${esc(w.label)}</span>
          <span style="opacity:.55">·  ${w.sessions.length} session${w.sessions.length===1?'':'s'}</span>`;
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
        r.className = `row ${s.kind} ${w.label ? 'indent2' : 'indent'} ${isAgent?'has-claude':''}`;
        const subParts = [];
        if (s.cwd)  subParts.push(`<span class="cwd">${esc(s.cwd)}</span>`);
        if (s.host) subParts.push(`<span class="host">${esc(s.host)}</span>`);
        const sub = subParts.join('<span class="sep">·</span>');
        const cpuStr = (s.cpu >= 5) ? ` ${s.cpu.toFixed(0)}%` : '';
        const badge = s.agent
          ? `<span class="badge">${esc(s.agent)}${cpuStr}</span>`
          : (s.runShort ? `<span class="badge">${esc(s.runShort)}</span>` : '');
        const dot = isAgent ? `<div class="pulse ${active?'':'idle'}"></div>` : '';
        const lastLine = s.lastLine ? `<div class="last">${esc(s.lastLine)}</div>` : '';
        r.innerHTML = `
          <div class="icon">${makeIcon(s.kind)}</div>
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
        const hay = (r.leaf.title + ' ' + r.leaf.sub + ' ' + (r.leaf.running||'')).toLowerCase();
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
