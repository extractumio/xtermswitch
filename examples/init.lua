-- Sample ~/.hammerspoon/init.lua showing how to load xtermswitch.
-- Replace the placeholder with the absolute path to your checkout.
-- install.sh writes this line for you automatically; this file is here
-- for reference when wiring things up by hand.
local xtermswitch = "/absolute/path/to/xtermswitch/xtermswitch.lua"

-- Auto-reload Hammerspoon when any .lua in this dir changes.
hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function(files)
  for _, f in ipairs(files) do
    if f:match("%.lua$") then hs.reload(); return end
  end
end):start()

-- xtermswitch — iTerm session switcher with hotkey.
dofile(xtermswitch)
