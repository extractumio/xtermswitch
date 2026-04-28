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
   │     🖥  ~/src/xtermswitch             claude  ●        │
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
- **Low idle cost** — the iTerm2 daemon updates on iTerm events; fallback
  AppleScript/SSH polling runs only while the picker is open
- **Glass UI** that floats over any app, dismisses on focus loss

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/) — `brew install --cask hammerspoon`
- [iTerm2](https://iterm2.com/) — `brew install --cask iterm2` —
  with Preferences → General → Magic → **Enable Python API** for event-based
  updates. AppleScript is still used as a fallback collector and for focusing
  selected sessions.
- `python3`, `osascript`, standard `bash` — preinstalled on macOS

`install.sh` checks for both apps and refuses to proceed if either is missing,
so a fresh machine gets clear next-step instructions instead of a silently
broken install.

## Install

```bash
git clone https://github.com/extractumio/xtermswitch.git ~/src/xtermswitch
~/src/xtermswitch/install.sh
```

You can clone into any directory; the installer records the absolute path to
that checkout in `~/.hammerspoon/init.lua`.

The installer is idempotent. Re-running it updates the wiring for the current
checkout and keeps existing user config intact. It:

1. checks required command-line tools
2. creates `~/.hammerspoon`, `~/.xtermswitch`, and `~/.cache/xtermswitch`
3. ensures `bin/list-iterms` and the iTerm2 daemon are executable
4. links the iTerm2 daemon into `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/`
5. appends a one-line loader to `~/.hammerspoon/init.lua` (or creates one)
6. seeds `~/.xtermswitch/config.lua` from the example if it does not exist

First-run app steps:

1. In iTerm2, enable Settings/Preferences → General → Magic → **Enable Python API**.
2. Restart iTerm2, or run `Scripts → AutoLaunch → xtermswitch_daemon.py`.
3. In Hammerspoon, choose **Reload Config** from the menubar.
4. If macOS prompts for Automation access, allow Hammerspoon to control iTerm2.
5. Press `⌘⌥⌃T`.

The daemon writes `~/.cache/xtermswitch/sessions.json`; Hammerspoon watches
that file while the picker is open and falls back to the bash collector if the
daemon cache is missing or stale.

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
./bin/list-iterms          # full YAML inventory
./bin/list-iterms json     # JSON for chooser UIs
./bin/list-iterms focus <session-uid>
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
- **Daemon cache is not updating** — enable iTerm2's Python API, then restart
  iTerm2 or run `Scripts → AutoLaunch → xtermswitch_daemon.py`.
- **Remote panes show no `cwd` or `last line`** — the host needs `tmux` and
  `python3`, and SSH needs to connect with `BatchMode=yes` (key auth, no
  password prompt). Set up `ssh-agent` or `ControlMaster`.
- **Hotkey conflicts** — change `hotkey` in `~/.xtermswitch/config.lua`.

## Author

**Gregory Zemskov** — [info@extractum.io](mailto:info@extractum.io) ·
[linkedin.com/in/gregzem](https://www.linkedin.com/in/gregzem/)

## License

GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later) —
see [LICENSE](LICENSE).

If you run a modified version of xtermswitch and let other users interact
with it over a network, the AGPL requires that you offer them the
corresponding source code of your modifications.
