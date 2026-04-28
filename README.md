# xtermswitch

**A Spotlight for your terminals.** One hotkey opens a glassy, fuzzy-searchable
list of every iTerm2 session you have open — local windows, SSH targets,
tmux-CC panes on remote hosts — with the cwd, the running process, and a live
preview of what's happening on screen. Hit Enter to jump there.

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

## Why

If you live in 30+ terminal sessions across local windows, `ssh` shells, and
tmux panes on remote hosts, finding the right one becomes a chore. iTerm's
own switcher only lists titles. xtermswitch shows you what you actually need
to recognize a session at a glance:

- **Where it is** — local window, which SSH host, which tmux-CC pane
- **What's running** — `claude`, `codex`, `vim`, `pytest`, plain shell
- **What you're doing** — current working directory
- **Whether it's busy** — live %CPU, "thinking…" detection, last meaningful
  output line

Type a few letters of a path or a hostname; press Enter; you're there.

## Highlights

- **One hotkey, one keypress to focus** — default `⌘⌥⌃T`, fully configurable
- **Grouped by location** — Local windows, then each SSH host, then tmux-CC
  controllers
- **Event-based iTerm2 cache** — optional iTerm2 Python daemon updates the
  picker cache on session, location, prompt, and screen events
- **Smart fuzzy search** across title, cwd, host, running command
- **Agent detection** — flags `claude` / `codex` sessions, shows live activity
- **Last-line preview** — strips ANSI/box-drawing noise, surfaces real output
- **Remote tmux-CC enrichment** — single batched SSH round-trip per host;
  works even with 30+ remote panes
- **Zero idle cost** — no polling, no background work while the picker is
  closed; the cache only refreshes while you're looking at it
- **Glass UI** that floats over any app, dismisses on focus loss

## Requirements

- macOS
- [iTerm2](https://iterm2.com/) with Preferences → General → Magic →
  **Enable Python API** for event-based updates. AppleScript is still used as
  a fallback collector and for focusing selected sessions.
- [Hammerspoon](https://www.hammerspoon.org/)
- `python3`, `osascript`, standard `bash` — preinstalled on macOS

## Install

```bash
git clone https://github.com/<you>/xtermswitch ~/EXTRACTUM/xtermswitch
~/EXTRACTUM/xtermswitch/install.sh
```

Then **Reload Config** from the Hammerspoon menubar icon. Press `⌘⌥⌃T`.

The installer is idempotent — re-running it just verifies the wiring. It:

1. ensures `bin/list-iterms` is executable
2. links the iTerm2 Python daemon into iTerm2's AutoLaunch scripts
3. appends a one-line loader to `~/.hammerspoon/init.lua` (or creates one)
4. seeds `~/.xtermswitch/config.lua` from the example

After installing, enable iTerm2's Python API and restart iTerm2, or run
`Scripts → AutoLaunch → xtermswitch_daemon.py` from iTerm2's menu. The daemon
writes `~/.cache/xtermswitch/sessions.json`; Hammerspoon watches that file
while the picker is open.

## Configuration

Edit `~/.xtermswitch/config.lua`. The most common knob is the hotkey:

```lua
return {
  hotkey = { mods = {"cmd", "alt", "ctrl"}, key = "T" },
  -- list_iterms = "/usr/local/bin/list-iterms",   -- override script path
  use_iterm_daemon     = true,
  iterm_daemon_cache   = os.getenv("HOME") .. "/.cache/xtermswitch/sessions.json",
  iterm_daemon_max_age = 10,
  cache_interval_open = 5,
  cache_interval_fast = 1.5,
  stale_ttl_seconds   = 15,
  stale_miss_limit    = 2,
  width_max     = 900,
  width_factor  = 0.55,
  height_factor = 0.80,
  show_load_alert = true,
}
```

See [`config.example.lua`](config.example.lua) for the full list.

## Keys

| Key                | Action                |
|--------------------|-----------------------|
| `⌘⌥⌃T`             | Open picker           |
| `↑` `↓`            | Move selection        |
| `Ctrl-N` `Ctrl-P`  | Move selection (vim)  |
| Type               | Fuzzy filter          |
| `↵`                | Focus selected        |
| `Esc`              | Close                 |
| Click on group     | Collapse / expand     |
| Click outside      | Close                 |

## Standalone CLI

The data collector is useful on its own:

```bash
~/EXTRACTUM/xtermswitch/bin/list-iterms          # full YAML inventory
~/EXTRACTUM/xtermswitch/bin/list-iterms json     # JSON for chooser UIs
~/EXTRACTUM/xtermswitch/bin/list-iterms focus <session-uid>
```

## Privacy

xtermswitch reads iTerm session metadata, screen text from local panes (via
AppleScript), and tmux pane snapshots from remote hosts you've configured.
Everything stays on your machines. No telemetry, no network calls beyond the
SSH connections to hosts you already trust. See
[CLAUDE.md](CLAUDE.md) for a full data-flow walk-through.

## Troubleshooting

- **Picker is empty** — make sure iTerm has at least one window open and
  AppleScript automation is allowed (System Settings → Privacy & Security →
  Automation → Hammerspoon → iTerm2).
- **Remote panes show no `cwd` or `last line`** — the host needs `tmux` and
  `python3`, and SSH needs to connect with `BatchMode=yes` (key auth, no
  password prompt). Set up `ssh-agent` or `ControlMaster`.
- **Hotkey conflicts** — change `hotkey` in `~/.xtermswitch/config.lua`.

## License

MIT — see [LICENSE](LICENSE).
