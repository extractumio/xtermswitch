# CLAUDE.md

Technical map of the project. Read this before changing anything — the
moving parts span Lua, AppleScript, bash, Python, and SSH-tunneled tmux.

## At a glance

```
xtermswitch/
├── xtermswitch.lua          Hammerspoon module — UI, hotkey, cache
├── bin/
│   └── list-iterms          Bash + AppleScript + Python data collector
├── config.example.lua       Default user config (copied to ~/.xtermswitch/)
├── examples/
│   └── init.lua             Sample ~/.hammerspoon/init.lua
├── install.sh               Idempotent installer
├── README.md                Product-facing docs
├── CLAUDE.md                This file
└── LICENSE                  MIT
```

Two processes, three handoffs:

```
   ┌──────────────────────────┐         ┌──────────────────────────┐
   │  Hammerspoon (Lua)       │         │  bin/list-iterms (bash)  │
   │  xtermswitch.lua         │ ──fork▶ │  (AppleScript + ps/lsof  │
   │  • hotkey                │         │   + Python ANSI parser   │
   │  • webview UI            │ ◀─JSON─ │   + ssh tmux capture)    │
   │  • cache                 │         │                          │
   └────────────┬─────────────┘         └──────────────────────────┘
                │
                │ user clicks/presses Enter
                ▼
        list-iterms focus <uid>  ──▶  AppleScript: select that session
```

## Components

### `xtermswitch.lua` — the Hammerspoon side

Loaded with `dofile(...)` from the user's `~/.hammerspoon/init.lua`.
Self-locating: `debug.getinfo(1, "S").source` resolves the project directory
so the bundled `bin/list-iterms` is found by relative path.

Top-level structure:

| Section                  | Lines (approx) | Purpose                                           |
|--------------------------|----------------|---------------------------------------------------|
| Self-location & config   | 1–60           | Resolves DIR, merges `~/.xtermswitch/config.lua`  |
| Helpers                  | 60–100         | `shell()`, `basename()`, `cleanTitle()`, etc.     |
| `buildTreeFromSessions`  | 100–180        | Flat JSON → grouped tree (Local / SSH / tmux-CC)  |
| `HTML` block             | 180–500        | The webview's HTML/CSS/JS, embedded as a string   |
| Cache + task             | 500–560        | `refreshCache`, `cacheTimer`, async `hs.task`     |
| `show()` / `close()`     | 560–620        | Webview lifecycle, app-watcher auto-hide          |
| Public API + hotkey      | 620–end        | `_G.itermShow/Close/RefreshCache`, `hs.hotkey`    |

Key invariants:

- **Idle cost is zero.** No timers run unless the picker is open. The
  `cacheTimer` is started in `show()` and stopped in `close()`. A single
  warm-cache refresh fires at module load so the first hotkey press is
  instant.
- **Picker is single-instance.** `show()` calls `close()` first; the user
  content controller, webview, and watcher are all torn down on close.
- **Auto-hide uses `hs.application.watcher`, not webview focus.** Borderless
  modal-panel webviews don't reliably receive `focusChange` callbacks. The
  watcher tracks "Hammerspoon was activated, then someone else activated";
  the `hasFocused` flag prevents an immediate close on the very first
  Hammerspoon-activated event during opening. **If you change this code,
  do not call `:isFocused()` on the watcher's app argument — earlier code
  did that and crashed; the boolean flag is the working pattern.**

#### Webview ↔ Lua bridge

JS calls
`window.webkit.messageHandlers["iterm-switcher"].postMessage(uid)`.
Lua's `hs.webview.usercontent.new("iterm-switcher")` callback receives
`msg.body` — either the string `"close"` or a session UID. UIDs are opaque
strings produced by iTerm (`unique id of session`); xtermswitch never
parses them, just round-trips them to `list-iterms focus <uid>`.

The tree data is injected two ways:

1. **Initial render**: `HTML:gsub("__TREE_JSON__", json)` → `webview:html(...)`.
2. **Live updates while open**: `webview:evaluateJavaScript("applyData('...')")`,
   with the JSON escaped for embedding in a single-quoted JS string.

#### Config merge

```lua
for k, v in pairs(user) do config[k] = v end
```

Shallow merge only. Nested tables (e.g. `hotkey`) are replaced wholesale.
If the user sets `hotkey = { mods = {"alt"}, key = "Space" }`, both fields
must be supplied.

### `bin/list-iterms` — the data collector

A bash script with three subcommands.

```
list-iterms                  # YAML inventory (human / debugging)
list-iterms json             # flat JSON array, one entry per session (UI)
list-iterms focus <uid>      # bring that session to front
```

Internally it does five things:

1. **Enumerate sessions** via `osascript`. iTerm's AppleScript dictionary
   exposes `windows → tabs → sessions`, each with `unique id`, `tty`,
   `name`. tmux-CC virtual sessions show up here too, but with `tty =
   "missing value"` — that's how we detect them.

2. **Per-TTY inspection** (`inspect_tty`) — given a TTY basename, walks
   `ps -t` to find the foreground PID, `lsof -d cwd` for the cwd, greps
   the process tree for `ssh ... [-CC] host` to detect remote shells, and
   detects `claude` / `codex` agent processes. CPU is summed over the
   agent and all its descendants in a Python helper inlined as a heredoc.

3. **Batched screen capture** (`collect_texts` + `prefetch_texts`) — one
   AppleScript call dumps the visible text of every iTerm session into a
   tempdir, keyed by UID. The Python heredoc `analyze_screen` strips ANSI
   sequences and box-drawing noise to find the most recent meaningful line
   and a "processing" boolean (matches `esc to interrupt`, `thinking…`,
   etc.).

4. **Remote tmux-CC enrichment** (`fetch_remote_panes`) — when a session
   is a tmux-CC virtual pane, we need data from the *remote* host. One
   SSH round-trip per host runs `tmux list-panes -a` + `tmux capture-pane`
   + agent detection, base64-encodes the captures, and pipes the lot back.
   Subsequent calls reuse `ControlMaster` so it's near-instant.

5. **Emit** — JSON for the picker, YAML for human inspection, AppleScript
   `select` for `focus`.

Performance tricks:

- **One osascript call** for `collect_texts` instead of N — saves ~50% on
  workspaces with many sessions.
- **Skip screen analysis for boring shells.** `analyze_screen` only runs
  on sessions with a detected agent or non-shell foreground process.
- **SSH `ControlMaster=auto` + `ControlPersist=300`** — the first remote
  call sets up a multiplex socket at `/tmp/cm-list-iterms-%r@%h:%p`;
  subsequent calls within 5 minutes reuse it.

### Data shape (JSON)

The `json` subcommand emits an array of:

```jsonc
{
  "win": 1,                 // iTerm window index (1-based, AppleScript)
  "tab": 1,                 // iTerm tab index within window
  "sess": 1,                // iTerm session index within tab
  "iterm_window_id": 4993,  // iTerm's stable window id
  "uid": "B52A...86",       // session unique id (used for focus)
  "tty": "ttys002",         // basename, or "" for tmux-CC virtual
  "title": "Default: ...",  // raw iTerm session name
  "cwd": "/Users/...",      // resolved working directory
  "ssh_host": "prod-1",     // hostname if this is an ssh session
  "tmux_cc_controller": false,
  "tmux_cc_virtual": false,
  "running": "vim file.py", // "interesting" non-shell foreground
  "agent": "claude",        // "claude" | "codex" | ""
  "cpu": 12.3,              // agent + descendants %CPU
  "last_line": "...",       // most recent meaningful screen line
  "processing": true        // detected "interrupt"/"thinking" prompt
}
```

`buildTreeFromSessions` in Lua transforms this into:

```lua
{
  groups = {
    { kind = "local",  label = "Local",       count = N, windows = {...} },
    { kind = "remote", label = "SSH · host",  count = M, windows = {...} },
    ...
  }
}
```

Each `windows[i]` has `label` (or `nil` for remote groups) and `sessions`.
Each session has its kind (`"local"`/`"remote"`), display fields, and the
opaque `uid` for round-tripping back to `list-iterms focus`.

## Lifecycle

### Module load (Hammerspoon `hs.reload()` or first start)

1. `~/.hammerspoon/init.lua` runs. It starts a pathwatcher that reloads
   on any `*.lua` change in `~/.hammerspoon/`. **Note:** changes inside
   `~/EXTRACTUM/xtermswitch/` do *not* trigger reload; this is intentional
   to avoid surprise reloads while editing project files. To pick up
   changes there, edit `~/.hammerspoon/init.lua` (touch it) or use the
   menubar's Reload Config.
2. `dofile("/Users/.../xtermswitch.lua")` runs. The module:
   - resolves its own dir, loads optional user config
   - `chmod +x`'s `bin/list-iterms` (idempotent, safe)
   - binds the global hotkey
   - kicks off `refreshCache()` once (warm cache)
   - shows a single `hs.alert` confirming load (suppressible)

### Picker open (`itermShow` / hotkey)

1. `close()` — defensive teardown if a picker is somehow already up.
2. Compute screen geometry; build webview at `modalPanel` level,
   borderless, transparent, with shadow.
3. If `cache == nil` (no warm cache yet), do a synchronous `shell()` call
   to populate it before rendering.
4. Inject `__TREE_JSON__` placeholder; show webview; focus its window.
5. Start `cacheTimer` (every `cache_interval_open` seconds) and fire one
   immediate async refresh after 100ms.
6. Start `hs.application.watcher` for auto-hide.

### Picker close

Triggered by Esc in JS (`send('close')`), Enter or click on a session
(implicit close after `focusUid`), or another app activating.

`close()` stops the watcher, deletes the webview, clears the user content
controller, stops the cache timer. Idle state restored.

### Focus

JS sends the UID; Lua calls `hs.task.new(SCRIPT, ..., {"focus", uid})`,
fires the close, and returns. The bash invocation runs AppleScript that
walks every window/tab/session, matches `unique id`, and calls `select`
on the session, tab, and window in order, then `activate`.

## Configuration

Resolution order (later wins):

1. Defaults baked into `xtermswitch.lua`
2. `~/.xtermswitch/config.lua` (returns a table; merged shallow)

Recognized keys:

| Key                   | Type    | Default                                    | Notes                                       |
|-----------------------|---------|--------------------------------------------|---------------------------------------------|
| `hotkey.mods`         | array   | `{"cmd","alt","ctrl"}`                     | `hs.hotkey.bind` modifiers                  |
| `hotkey.key`          | string  | `"T"`                                      | single key                                  |
| `list_iterms`         | string  | `<DIR>/bin/list-iterms`                    | absolute path to data collector             |
| `cache_interval_open` | number  | `5`                                        | seconds, while picker open                  |
| `width_max`           | number  | `900`                                      | px cap                                      |
| `width_factor`        | number  | `0.55`                                     | fraction of main screen width               |
| `height_factor`       | number  | `0.80`                                     | fraction of main screen height              |
| `show_load_alert`     | bool    | `true`                                     | suppress the "loaded" toast on reload       |

To disable the hotkey entirely (e.g. you bind it from your own init):

```lua
return { hotkey = nil }
```

Then call `_G.itermShow()` from wherever you want.

## Public Lua API

After load, three globals are available (mainly for debugging from the
Hammerspoon Console):

```lua
_G.itermShow()         -- open the picker
_G.itermClose()        -- force-close (in case of stuck webview)
_G.itermRefreshCache() -- async refetch; populates _G.itermCache
_G.itermCache          -- the most recent grouped tree (for inspection)
```

## Adding features

Common change targets:

- **New hotkey for a filtered view** — e.g. only remote sessions. Bind a
  second hotkey that calls `show()` then sets `search.value` via
  `evaluateJavaScript` to a prefix that narrows results.
- **New badge** — see the JS `render()` function. Anything you put on the
  session entry in `entry()` (Lua, line ~75) becomes available as `s.x`
  in JS.
- **Per-host display tweaks** — the group label is built in Lua at
  ~line 121: `(r.controller and "tmux-CC · " or "SSH · ") .. (r.host or "?")`.
- **Different screen-text heuristic** — `analyze_screen` in
  `bin/list-iterms` is a self-contained Python heredoc; the noise
  patterns and processing regex live in the same place.

## Testing locally

There's no test harness. The fast feedback loop is:

```bash
# In one terminal, watch JSON output:
~/EXTRACTUM/xtermswitch/bin/list-iterms json | jq .

# In Hammerspoon Console:
hs.reload()              -- after editing xtermswitch.lua
itermRefreshCache()      -- after editing list-iterms
itermShow()              -- visual check
```

If the picker stays empty after `itermShow()`, run
`return _G.itermCache` in the Console — `nil` means the script failed to
emit JSON (run the bash script directly to see stderr).

## Common failure modes

| Symptom                                        | Cause                                                          |
|------------------------------------------------|----------------------------------------------------------------|
| Picker empty, no error                         | iTerm not running, or AppleScript permission denied            |
| Remote group shows but rows have no cwd        | SSH `BatchMode=yes` failed (password prompt, key not loaded)   |
| `attempt to call a nil value (method '...')`   | Old code in the appWatcher callback — see invariant in §1.1    |
| Hotkey doesn't fire                            | Conflict with another global hotkey; check `hs.hotkey.showHotkeys()` |
| Webview opens behind the active app            | macOS Stage Manager interaction; reload Hammerspoon            |
| Two `ssh -CC` tunnels open, virtuals show under "tmux-CC" placeholder | Not supported. `bin/list-iterms` only attributes a host to virtuals when exactly one tmux-CC controller is running (`cc_count == 1`). With multiple, virtual sessions still appear but are bundled under a generic `"tmux-CC"` group. |

## Files written outside the project

| Path                              | When                                  |
|-----------------------------------|---------------------------------------|
| `~/.hammerspoon/init.lua`         | `install.sh` creates or appends to it |
| `~/.xtermswitch/config.lua`       | `install.sh` seeds from the example   |
| `/tmp/list-iterms-texts.XXXXXX/`  | Per-run screen-text cache; cleaned on script exit (`trap`) |
| `/tmp/cm-list-iterms-*`           | SSH ControlMaster sockets; auto-expire after 5 min idle |

Nothing else. No state under `~/.config`, no logs.

## Dependencies (assumed present)

- macOS-bundled: `bash`, `awk`, `grep`, `sed`, `osascript`, `python3`,
  `lsof`, `ps`, `mktemp`, `base64`, `pgrep`
- iTerm2 (any recent version)
- Hammerspoon (any recent version)
- For remote enrichment: `ssh`, plus `tmux` and `python3` on each remote host

## License

MIT.
