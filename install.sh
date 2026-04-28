#!/usr/bin/env bash
# xtermswitch installer
# Copyright (C) 2026 Gregory Zemskov <info@extractum.io>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Idempotent. Wires Hammerspoon, installs the iTerm2 AutoLaunch daemon, seeds
# config, and prints the remaining app permission steps. Safe to re-run.

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
HS_DIR="$HOME/.hammerspoon"
HS_INIT="$HS_DIR/init.lua"
LOAD_LINE="dofile(\"$DIR/xtermswitch.lua\")"
ITERM_AUTOLAUNCH="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch"
CACHE_DIR="$HOME/.cache/xtermswitch"

missing=0
for cmd in osascript python3 awk grep sed lsof ps mktemp base64 pgrep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    missing=1
  fi
done
if ! command -v hs >/dev/null 2>&1; then
  echo "Note: Hammerspoon CLI 'hs' is not on PATH. This is OK, but reload Hammerspoon manually."
fi
if [ "$missing" -ne 0 ]; then
  echo "Install missing dependencies and re-run install.sh." >&2
  exit 1
fi

mkdir -p "$HS_DIR"
mkdir -p "$HOME/.xtermswitch" "$CACHE_DIR" "$ITERM_AUTOLAUNCH"
chmod +x "$DIR/bin/list-iterms"
chmod +x "$DIR/iterm/xtermswitch_daemon.py"

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
elif grep -qE 'dofile\([^)]*xtermswitch\.lua' "$HS_INIT"; then
  if grep -qF "$LOAD_LINE" "$HS_INIT"; then
    echo "$HS_INIT already loads this checkout — skipping."
  else
    # A dofile(...) for a different xtermswitch checkout exists. Rewrite it
    # in place so the active loader points at this checkout.
    replacement=$(printf '%s' "$LOAD_LINE" | sed 's/[\&~]/\\&/g')
    sed -i '' -E "s~dofile\\(\"[^\"]*xtermswitch\\.lua\"\\)~$replacement~" "$HS_INIT"
    echo "Updated xtermswitch loader path in $HS_INIT"
  fi
else
  printf '\n-- xtermswitch\n%s\n' "$LOAD_LINE" >> "$HS_INIT"
  echo "Appended xtermswitch loader to $HS_INIT"
fi

if [ ! -f "$HOME/.xtermswitch/config.lua" ]; then
  cp "$DIR/config.example.lua" "$HOME/.xtermswitch/config.lua"
  echo "Wrote default config to ~/.xtermswitch/config.lua"
fi

ln -sfn "$DIR/iterm/xtermswitch_daemon.py" "$ITERM_AUTOLAUNCH/xtermswitch_daemon.py"
echo "Linked iTerm2 daemon into AutoLaunch scripts."

cat <<EOF

Done. xtermswitch is installed for this checkout.

Files:
  module:  $DIR/xtermswitch.lua
  script:  $DIR/bin/list-iterms
  daemon:  $ITERM_AUTOLAUNCH/xtermswitch_daemon.py
  config:  $HOME/.xtermswitch/config.lua
  cache:   $CACHE_DIR/sessions.json
  hammerspoon init: $HS_INIT

Required first-run app steps:
  1. iTerm2: enable Settings/Preferences → General → Magic → Enable Python API.
  2. Restart iTerm2, or run Scripts → AutoLaunch → xtermswitch_daemon.py.
  3. Hammerspoon: Reload Config.
  4. macOS Automation: allow Hammerspoon to control iTerm2 if prompted.

Then press ⌘⌥⌃T.
EOF
