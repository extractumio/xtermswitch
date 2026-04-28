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

app_installed() {
  local name=$1 bundle_id=$2
  for dir in /Applications "$HOME/Applications" /System/Applications; do
    [ -d "$dir/$name.app" ] && return 0
  done
  if command -v mdfind >/dev/null 2>&1; then
    [ -n "$(mdfind "kMDItemCFBundleIdentifier == '$bundle_id'" 2>/dev/null | head -1)" ] && return 0
  fi
  return 1
}

require_app() {
  local name=$1 bundle_id=$2 cask=$3 url=$4
  if app_installed "$name" "$bundle_id"; then
    return 0
  fi
  echo "Missing app: $name is not installed." >&2
  echo "  Install:   brew install --cask $cask" >&2
  echo "  Download:  $url" >&2
  missing=1
}

require_app Hammerspoon org.hammerspoon.Hammerspoon hammerspoon https://www.hammerspoon.org/
require_app iTerm2      com.googlecode.iterm2     iterm2      https://iterm2.com/

if ! command -v hs >/dev/null 2>&1; then
  echo "Note: Hammerspoon CLI 'hs' is not on PATH (optional). After install,"
  echo "  enable it from Hammerspoon → Preferences → Advanced → Install command-line tool."
fi

if [ "$missing" -ne 0 ]; then
  echo >&2
  echo "Install the items above and re-run install.sh." >&2
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

# `application "X" is running` is a non-targeted query that does not
# require Automation permission, so it's safe before the user has granted it.
iterm_running=$(osascript -e 'application "iTerm2" is running' 2>/dev/null || echo false)

if [ "$iterm_running" = "true" ]; then
  # iTerm2 Python API. iTerm2 doesn't reliably expose the toggle state via
  # `defaults`, but it spawns a long-running iTermServer process when the
  # API server is up. Detect via process list — no permission required.
  if ! ps -axo command= 2>/dev/null | grep -q '/iTermServer-'; then
    echo
    echo "WARNING: iTerm2 Python API server is not running. The xtermswitch"
    echo "  daemon will exit silently and remote tmux-CC enrichment will fall"
    echo "  back to bash-only mode."
    echo "  Enable: Settings → General → Magic → Enable Python API"
    echo "  Then restart iTerm2 (or run Scripts → Manage → Install Python Runtime"
    echo "  if iTerm2 prompts for it on first use)."
  fi

  # Probe macOS Automation permission. The first AppleScript call targeting
  # iTerm2 from the controlling process surfaces the permission prompt;
  # doing it here makes the prompt appear during install, not on the first
  # hotkey press from Hammerspoon (which would silently fail).
  if ! osascript -e 'tell application "iTerm2" to count windows' >/dev/null 2>&1; then
    echo
    echo "WARNING: AppleScript probe of iTerm2 failed. xtermswitch needs"
    echo "  Automation permission for the controlling process."
    echo "  System Settings → Privacy & Security → Automation → allow"
    echo "  Hammerspoon (and Terminal/iTerm2 if you ran install.sh from one)"
    echo "  to control iTerm2. Then re-run install.sh to verify."
  fi
else
  echo
  echo "Note: iTerm2 is not running. Start it once before testing the picker so"
  echo "  macOS can prompt for Automation permission for Hammerspoon, and so the"
  echo "  AutoLaunch daemon (xtermswitch_daemon.py) starts."
fi

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
