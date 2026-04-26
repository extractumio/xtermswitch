#!/usr/bin/env bash
# xtermswitch installer
#
# Idempotent. Wires xtermswitch.lua into ~/.hammerspoon/init.lua and reminds
# you to reload Hammerspoon. Safe to re-run.

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
HS_DIR="$HOME/.hammerspoon"
HS_INIT="$HS_DIR/init.lua"
LOAD_LINE="dofile(\"$DIR/xtermswitch.lua\")"

mkdir -p "$HS_DIR"
chmod +x "$DIR/bin/list-iterms"

if [ ! -f "$HS_INIT" ]; then
  cat > "$HS_INIT" <<EOF
-- Auto-reload on changes
hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", function(files)
  for _, f in ipairs(files) do
    if f:match("%.lua\$") then hs.reload(); return end
  end
end):start()

-- xtermswitch
$LOAD_LINE
EOF
  echo "Created $HS_INIT"
elif grep -qF "xtermswitch.lua" "$HS_INIT"; then
  echo "$HS_INIT already references xtermswitch — skipping."
else
  printf '\n-- xtermswitch\n%s\n' "$LOAD_LINE" >> "$HS_INIT"
  echo "Appended xtermswitch loader to $HS_INIT"
fi

mkdir -p "$HOME/.xtermswitch"
if [ ! -f "$HOME/.xtermswitch/config.lua" ]; then
  cp "$DIR/config.example.lua" "$HOME/.xtermswitch/config.lua"
  echo "Wrote default config to ~/.xtermswitch/config.lua"
fi

cat <<EOF

Done. Reload Hammerspoon (menu bar → Reload Config) and press ⌘⌥⌃T.

Files:
  module:  $DIR/xtermswitch.lua
  script:  $DIR/bin/list-iterms
  config:  $HOME/.xtermswitch/config.lua
  hammerspoon init: $HS_INIT
EOF
