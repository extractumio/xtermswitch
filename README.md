# xtermswitch

Fast, fuzzy iTerm2 session switcher for macOS. Hammerspoon hotkey pops up a
glassy webview listing every iTerm session — local windows, SSH hosts, tmux-CC
panes — with cwd, running process, agent (claude/codex) detection, last-line
preview, and live-updating activity. Hit Enter to focus the chosen session.

```
                             ⌘⌥⌃T
   ┌────────────────────────────────────────────────────────┐
   │  Search sessions, hosts, paths…                        │
   ├────────────────────────────────────────────────────────┤
   │  LOCAL                                              7  │
   │   iTerm 17                                             │
   │     🖥  ~/EXTRACTUM/xtermswitch       claude  ●        │
   │     🖥  ~/concrete_jungle             zsh              │
   │   iTerm 18                                             │
   │     🖥  ~                             ssh              │
   │  SSH · prod-1                                       3  │
   │     🌐 logs                           tmux-CC          │
   │     ...                                                │
   │  ↑↓ navigate   ↵ focus   esc close                     │
   └────────────────────────────────────────────────────────┘
```

## Features

- **Single hotkey** (default `⌘⌥⌃T`) opens the picker over any app.
- **Grouped tree** — Local windows, SSH hosts, tmux-CC controllers.
- **Fuzzy search** across title, cwd, host, running command.
- **Agent detection** — flags `claude` / `codex` sessions, shows live %CPU.
- **Last-line preview** — the most recent meaningful line on each pane.
- **Remote tmux-CC enrichment** — one batched SSH round-trip, no polling.
- **Zero idle cost** — no background work while the picker is closed.

## Requirements

- macOS
- [iTerm2](https://iterm2.com/) (with AppleScript automation enabled)
- [Hammerspoon](https://www.hammerspoon.org/)
- `bash`, `python3`, `osascript`, `jq`-style helpers from coreutils

## Install

```bash
git clone <repo-url> ~/EXTRACTUM/xtermswitch
~/EXTRACTUM/xtermswitch/install.sh
```

The installer appends a `dofile(...)` line to `~/.hammerspoon/init.lua` (or
creates one). Reload Hammerspoon — done.

If you'd rather wire it up by hand, add this to `~/.hammerspoon/init.lua`:

```lua
dofile(os.getenv("HOME") .. "/EXTRACTUM/xtermswitch/xtermswitch.lua")
```

You can also clone elsewhere — the module finds its own `bin/list-iterms`
relative to itself. Just point `dofile` at the right path.

## Configuration

All defaults are sensible. To override, drop a Lua table at
`~/.xtermswitch/config.lua`:

```lua
return {
  hotkey = { mods = {"cmd", "alt", "ctrl"}, key = "T" },

  -- Override path to the bash script (default: <project>/bin/list-iterms)
  -- list_iterms = "/usr/local/bin/list-iterms",

  cache_interval_open = 5,    -- seconds between background refreshes
  width_max           = 900,
  width_factor        = 0.55, -- fraction of screen width
  height_factor       = 0.80,
  show_load_alert     = true,
}
```

See `config.example.lua` for the full set.

## Usage

- `⌘⌥⌃T` — open picker (configurable)
- `↑` `↓` — move selection
- type — fuzzy filter
- `Enter` — focus selected session
- `Esc` — close

The bash script is also useful directly:

```bash
~/EXTRACTUM/xtermswitch/bin/list-iterms          # YAML inventory
~/EXTRACTUM/xtermswitch/bin/list-iterms json     # JSON for chooser UIs
~/EXTRACTUM/xtermswitch/bin/list-iterms focus <session-uid>
```

## How it works

`bin/list-iterms` drives iTerm via AppleScript to enumerate every session and
its TTY, then walks `ps`/`lsof` to recover cwd, ssh target, agent processes,
and CPU. For tmux-CC virtual sessions it does one batched SSH round-trip per
controller host (`tmux list-panes` + `capture-pane`) so even 30+ remote panes
update in well under a second.

The Hammerspoon module renders the tree into a transparent webview, hands
`Enter`/click events back into Lua, and shells out to the same bash script
with `focus <uid>` to bring the matched session forward.

## Files

```
xtermswitch/
├── xtermswitch.lua          Hammerspoon entry — dofile this
├── bin/
│   └── list-iterms          Bash + AppleScript + Python data collector
├── examples/
│   └── init.lua             Sample ~/.hammerspoon/init.lua
├── config.example.lua       Sample ~/.xtermswitch/config.lua
├── install.sh               One-shot installer
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).
