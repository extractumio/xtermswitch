-- Sample ~/.hammerspoon/init.lua showing how to load xtermswitch.
-- Adjust this path to wherever you cloned the repo.
local xtermswitch = os.getenv("HOME") .. "/src/xtermswitch/xtermswitch.lua"

-- Auto-reload Hammerspoon when any .lua in this dir changes.
hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function(files)
  for _, f in ipairs(files) do
    if f:match("%.lua$") then hs.reload(); return end
  end
end):start()

-- xtermswitch — iTerm session switcher with hotkey.
dofile(xtermswitch)
