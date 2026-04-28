-- xtermswitch user config — copy to ~/.xtermswitch/config.lua and edit.
-- Anything you don't set falls back to the defaults baked into xtermswitch.lua.

return {
  -- Global hotkey to open the picker.
  hotkey = { mods = {"cmd", "alt", "ctrl"}, key = "T" },

  -- Override the data-collector script. Defaults to <project>/bin/list-iterms,
  -- discovered relative to xtermswitch.lua. Set this if you symlinked it
  -- elsewhere on PATH.
  -- list_iterms = "/usr/local/bin/list-iterms",

  -- Prefer the iTerm2 Python daemon cache. The daemon writes this file on
  -- iTerm2 events; the bash collector remains a fallback if it is stale.
  use_iterm_daemon     = true,
  iterm_daemon_cache   = os.getenv("HOME") .. "/.cache/xtermswitch/sessions.json",
  iterm_daemon_max_age = 10,

  -- Fallback refresh cadence (seconds) while the picker is open.
  cache_interval_open = 5,
  cache_interval_fast = 1.5,
  stale_ttl_seconds   = 15,
  stale_miss_limit    = 2,

  -- Picker window sizing.
  width_max     = 900,   -- px cap
  width_factor  = 0.55,  -- fraction of main screen width
  height_factor = 0.80,  -- fraction of main screen height

  -- Show "xtermswitch loaded — ⌘⌥⌃T" alert on Hammerspoon load.
  show_load_alert = true,
}
