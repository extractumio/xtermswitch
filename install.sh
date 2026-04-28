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
CACHE_DIR="$HOME/.cache/xtermswitch"

# iTerm2 ≥3.5 may store its support directory under either
#   ~/Library/Application Support/iTerm2          (default)
#   ~/.config/iterm2/AppSupport                   (XDG layout)
# Prefer whichever exists as a real directory (not a symlink to the other);
# fall back to the default. This is the path AutoLaunch scripts must live
# under for iTerm2 to discover them.
iterm_support_dir() {
  for p in "$HOME/.config/iterm2/AppSupport" "$HOME/Library/Application Support/iTerm2"; do
    [ -d "$p" ] && [ ! -L "$p" ] && { echo "$p"; return; }
  done
  echo "$HOME/Library/Application Support/iTerm2"
}
ITERM_SUPPORT=$(iterm_support_dir)
ITERM_AUTOLAUNCH="$ITERM_SUPPORT/Scripts/AutoLaunch"

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
  # iTerm2's Python API requires a bundled Python runtime that the user
  # accepts on first enable. Look for it under whichever support directory
  # iTerm2 is actually using on this machine.
  has_runtime=0
  for d in "$ITERM_SUPPORT"/iterm2env-*; do
    [ -d "$d" ] && { has_runtime=1; break; }
  done
  daemon_running=0
  if pgrep -f xtermswitch_daemon.py >/dev/null 2>&1; then
    daemon_running=1
  fi

  if [ "$has_runtime" -eq 0 ]; then
    echo
    echo "WARNING: iTerm2 Python API has never been enabled on this machine."
    echo "  iTerm2 has not downloaded its bundled Python runtime, so the"
    echo "  xtermswitch_daemon AutoLaunch script cannot run. The picker will"
    echo "  fall back to bash-only mode (slower, no per-event refresh)."
    echo
    echo "  To enable:"
    echo "    1. iTerm2 → Settings → General → Magic → Enable Python API"
    echo "    2. Accept the prompt to download the Python runtime (~10 MB)"
    echo "    3. Restart iTerm2"
    echo "    4. Verify: ls ~/Library/Application\\ Support/iTerm2/iterm2env-*"
  elif [ "$daemon_running" -eq 0 ]; then
    echo
    echo "WARNING: Python runtime is installed but xtermswitch_daemon is not"
    echo "  running. AutoLaunch fires only at iTerm2 startup, so a fresh"
    echo "  install needs an iTerm2 restart, or one-time launch via:"
    echo "    iTerm2 → Scripts → AutoLaunch → xtermswitch_daemon.py"
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
