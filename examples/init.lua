-- Sample ~/.hammerspoon/init.lua showing how to load xtermswitch.
-- Adjust the path if you cloned the repo somewhere other than ~/EXTRACTUM/.

-- Auto-reload Hammerspoon when any .lua in this dir changes.
hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function(files)
  for _, f in ipairs(files) do
    if f:match("%.lua$") then hs.reload(); return end
  end
end):start()

-- xtermswitch — iTerm session switcher with hotkey.
dofile(os.getenv("HOME") .. "/EXTRACTUM/xtermswitch/xtermswitch.lua")
