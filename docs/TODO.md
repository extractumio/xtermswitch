# xtermswitch — TODO

Known gaps, ordered by impact. Items here are real (not nits) and not yet
implemented.

---

## Daemon ↔ collector consistency

### tmux pane variable name unverified across iTerm2 versions

`iterm/xtermswitch_daemon.py:254` tries multiple candidate variable names
when reading the tmux pane id from iTerm2's Python API:

```python
tmux_pane = await session_var(
    session, "tmux.pane", "tmuxPane", "user.tmux.pane", "tmux_pane"
)
```

If none of the candidates match the iTerm2 build the user is running, the
daemon silently writes empty `tmux_pane` and the bash collector falls back
to title matching. There is no log line saying "I tried these names and got
nothing," so a quietly-broken pane-id matcher looks the same as a working
one.

**Fix sketch:** when a session has empty `tty` (likely virtual) and empty
`tmux_pane` after N update cycles, log once with the list of variable
names attempted. Optionally enumerate `session.async_get_variable_names()`
if iTerm2's API exposes it, and dump the candidate set on first run.

### `analyze_text` (daemon) and `analyze_screen` (bash) regex drift

Both compute `last_line` and `processing` from screen text but with
slightly different regex sets and noise filters. The picker can flicker
`processing` / `agent` between daemon-sourced and bash-sourced rows
because each writes a different value for the same session.

Files:

- `iterm/xtermswitch_daemon.py:33-93` — `ANSI_RE`, `PROCESSING_RE`,
  `QUESTION_RE`, `NOISE_RE`, `analyze_text`.
- `bin/list-iterms` — inline `analyze_screen` Python heredoc with its
  own regex set.

**Fix sketch:** extract a shared `xtermswitch_analyze.py` module the
daemon imports directly and the bash collector invokes via
`python3 -m`. Keep one source of truth for the noise/processing
heuristics.

---

## Operability

### No way to reset accumulated state

If `sessionStore` drifts (a row stuck in the wrong group, a stale uid that
won't expire), there's no debug global to nuke it. Right now the only
recovery is `hs.reload()` from the Hammerspoon Console, which restarts
everything.

**Fix sketch:** add `_G.itermResetCache()` that clears `sessionStore`,
`sessionOrder`, `cache`, and `lastPushedJson`, then triggers a full
refresh.

### `mergeSessionSnapshot`'s `mode` parameter is unused

`xtermswitch.lua` defines `mergeSessionSnapshot(data, mode)` but never
reads `mode` inside the function. Dead arg from an earlier refactor.

**Fix sketch:** drop the parameter; update the three callers
(`refreshCache`, `loadDaemonCache`, the synchronous prime path in
`show()`).

---

## First-run UX

### Config drift between `config.example.lua` and the user's `~/.xtermswitch/config.lua`

`install.sh` seeds the user config once and never touches it again. When
new keys are added to `config.example.lua`, existing users don't see
them — they keep running on stale defaults baked into `xtermswitch.lua`.

**Fix sketch:** in `install.sh`, after the seed step, diff the
example against the user file. For each top-level key present in the
example but missing from the user file, print a one-line "new option
available: KEY = DEFAULT" hint without modifying the user file.

### No automated uninstall

A user wanting to remove xtermswitch has to manually:

1. Delete the `dofile(...)` line from `~/.hammerspoon/init.lua`.
2. Remove the `~/Library/Application Support/iTerm2/Scripts/AutoLaunch/xtermswitch_daemon.py` symlink.
3. Optionally delete `~/.xtermswitch/`, `~/.cache/xtermswitch/`.

**Fix sketch:** add `install.sh --uninstall` that walks the same paths
the installer wrote to and reverses each one. Skip removing user data
unless `--purge` is passed.

---

## Quality

### No tests, no CI, no smoke harness

The project crosses Lua / Python / bash / AppleScript. There is no
automated check for any of those layers. A typo in `xtermswitch.lua` is
discovered on the next `hs.reload()`; a typo in `bin/list-iterms` on the
next picker open; a typo in `xtermswitch_daemon.py` on the next iTerm2
restart.

**Fix sketch:** add `make smoke` that runs:

- `bash -n` on `install.sh` and `bin/list-iterms`.
- `python3 -m py_compile` on `iterm/xtermswitch_daemon.py`.
- `osascript -ss` against the AppleScript blocks extracted from
  `bin/list-iterms` (they don't need iTerm2 running to compile).
- `./bin/list-iterms json fast | jq -e 'type == "array"'` if iTerm2
  is available on the runner.

A GitHub Actions macOS runner can run all of this except the
iTerm2-dependent step.
