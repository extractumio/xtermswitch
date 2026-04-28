#!/usr/bin/env python3
# Copyright (C) 2026 Gregory Zemskov <info@extractum.io>
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Event-based iTerm2 state cache for xtermswitch.

Install through iTerm2's Scripts menu or symlink into:
  ~/Library/Application Support/iTerm2/Scripts/AutoLaunch/

The daemon keeps a JSON cache at ~/.cache/xtermswitch/sessions.json. The
Hammerspoon picker reads that file and falls back to bin/list-iterms if it is
missing or stale.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import tempfile
import time
from pathlib import Path
from typing import Any

import iterm2

CACHE_PATH = Path(os.environ.get(
    "XTERMSWITCH_CACHE",
    Path.home() / ".cache" / "xtermswitch" / "sessions.json",
))
WRITE_DEBOUNCE_SECONDS = 0.08
SCREEN_DEBOUNCE_SECONDS = 0.25
SCREEN_MIN_INTERVAL_SECONDS = 1.0

ANSI_RE = re.compile(
    r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*(?:\x07|\x1b\\)|"
    r"\x1b[()][AB012]|\x1b[=>NOM]"
)
PROCESSING_RE = re.compile(
    r"esc to interrupt|press\s+(?:ctrl[-+\s]?c|esc)\s+to\s+"
    r"(?:stop|interrupt|cancel)|thinking[\u2026\.\s]|generating[\u2026\.\s]",
    re.I | re.M,
)
QUESTION_RE = re.compile(
    r"\b(approve|allow|confirm|continue|proceed|yes/no|y/n|permission)\b|[?]\s*$",
    re.I,
)
NOISE_RE = re.compile(
    r"^⏵|^\?\s+for\b.*shortcuts|shift\+tab to cycle|"
    r"to (select|navigate|cancel|quit|kill|jump|exit|continue|cycle)|"
    r"^[<>?]\s|^[\s│┃║|╭╮╰╯─━═┌┐└┘┏┓┗┛<>?·\.•◦○●]+$|^[─━═]{3,}",
    re.I,
)


def now() -> float:
    return time.time()


def basename(path: str) -> str:
    return path.rstrip("/").rsplit("/", 1)[-1] if path else ""


def clean_title(title: str) -> str:
    title = title or ""
    title = re.sub(r"^Default:\s*", "", title)
    title = re.sub(r"^[^\w/~.\-]+\s+", "", title)
    title = re.sub(r"\s+[—-]\s+[^—-]+$", "", title)
    title = re.sub(r"\s*\([^)]*interactive-bash[^)]*\)\s*", " ", title)
    return title.rstrip()


def trim_box(line: str) -> str:
    line = re.sub(r"^[│┃║|╭╰─\s]+", "", line)
    line = re.sub(r"[│┃║|╮╯─\s]+$", "", line)
    return line


def analyze_text(text: str) -> tuple[str, bool, bool]:
    text = ANSI_RE.sub("", text or "")[-6000:]
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    lines = [line.rstrip() for line in text.splitlines()]
    tail = "\n".join(lines[-15:])
    processing = bool(PROCESSING_RE.search(tail))
    question = bool(QUESTION_RE.search(tail))
    useful = ""
    for line in reversed(lines[-50:]):
        s = trim_box(line)
        if len(s.strip()) < 3:
            continue
        if NOISE_RE.search(s):
            continue
        useful = s[:240]
        break
    return useful, processing, question


def infer_agent(*parts: str) -> str:
    text = " ".join(part or "" for part in parts).lower()
    if re.search(r"(^|[^a-z0-9_/.-])claude([^a-z0-9_.-]|$)", text):
        return "claude"
    if re.search(r"(^|[^a-z0-9_/.-])codex([^a-z0-9_.-]|$)", text):
        return "codex"
    return ""


def first_attr(obj: Any, names: list[str]) -> Any:
    for name in names:
        value = getattr(obj, name, None)
        if value not in (None, ""):
            return value
    return None


def notification_session_id(notification: Any) -> str | None:
    direct = first_attr(notification, ["session_id", "sessionId", "identifier"])
    if direct:
        return str(direct)
    for child_name in [
        "session",
        "new_session",
        "terminated_session",
        "screen_update",
        "prompt",
        "custom_escape_sequence",
        "location_change",
    ]:
        child = getattr(notification, child_name, None)
        if child is None:
            continue
        child_id = first_attr(child, ["session_id", "sessionId", "identifier"])
        if child_id:
            return str(child_id)
    return None


async def session_var(session: iterm2.Session, *names: str) -> str:
    for name in names:
        try:
            value = await session.async_get_variable(name)
        except Exception:
            value = None
        if value not in (None, ""):
            return str(value)
    return ""


async def screen_text(session: iterm2.Session) -> str:
    try:
        contents = await session.async_get_screen_contents()
    except Exception:
        return ""
    lines = []
    start = max(0, contents.number_of_lines - 80)
    for i in range(start, contents.number_of_lines):
        try:
            lines.append(contents.line(i).string)
        except Exception:
            pass
    return "\n".join(lines)


class State:
    def __init__(self, connection: iterm2.Connection):
        self.connection = connection
        self.app: iterm2.App | None = None
        self.sessions: dict[str, dict[str, Any]] = {}
        self.custom_status: dict[str, dict[str, Any]] = {}
        self.last_screen_update: dict[str, float] = {}
        self.pending_screen: dict[str, asyncio.Task] = {}
        self.pending_write: asyncio.Task | None = None
        self.last_payload_key: str | None = None

    async def refresh_app(self) -> iterm2.App:
        if self.app is None:
            self.app = await iterm2.async_get_app(self.connection)
        else:
            await self.app.async_refresh(self.connection)
        return self.app

    async def snapshot_all(self, include_screen: bool = False) -> None:
        app = await self.refresh_app()
        seen: set[str] = set()
        for widx, window in enumerate(app.terminal_windows, start=1):
            for tidx, tab in enumerate(window.tabs, start=1):
                for sidx, session in enumerate(tab.sessions, start=1):
                    seen.add(session.session_id)
                    await self.update_session(session, window, tab, widx, tidx, sidx, include_screen=include_screen)
        for sid in list(self.sessions):
            if sid not in seen:
                self.sessions.pop(sid, None)
                self.custom_status.pop(sid, None)
                self.last_screen_update.pop(sid, None)
                pending = self.pending_screen.pop(sid, None)
                if pending and not pending.done():
                    pending.cancel()
        self.schedule_write()

    async def update_by_id(self, session_id: str, include_screen: bool = False) -> None:
        app = await self.refresh_app()
        session = app.get_session_by_id(session_id)
        if session is None:
            self.sessions.pop(session_id, None)
            self.schedule_write()
            return
        window, tab = app.get_window_and_tab_for_session(session)
        if window is None or tab is None:
            await self.snapshot_all()
            return
        widx, tidx, sidx = self.indices_for(app, window, tab, session)
        await self.update_session(session, window, tab, widx, tidx, sidx, include_screen=include_screen)
        self.schedule_write()

    def indices_for(self, app: iterm2.App, window: iterm2.Window, tab: iterm2.Tab, session: iterm2.Session):
        widx = 1
        for idx, candidate in enumerate(app.terminal_windows, start=1):
            if candidate.window_id == window.window_id:
                widx = idx
                break
        tidx = 1
        for idx, candidate in enumerate(window.tabs, start=1):
            if candidate.tab_id == tab.tab_id:
                tidx = idx
                break
        sidx = 1
        for idx, candidate in enumerate(tab.sessions, start=1):
            if candidate.session_id == session.session_id:
                sidx = idx
                break
        return widx, tidx, sidx

    async def update_session(
        self,
        session: iterm2.Session,
        window: iterm2.Window,
        tab: iterm2.Tab,
        widx: int,
        tidx: int,
        sidx: int,
        include_screen: bool,
    ) -> None:
        sid = session.session_id
        old = self.sessions.get(sid, {})
        title = await session_var(session, "session.name", "name")
        title = title or old.get("title") or sid
        cwd = await session_var(session, "session.path", "path", "session.currentDirectory")
        host = await session_var(session, "session.hostname", "hostname")
        tty = await session_var(session, "session.tty", "tty")
        # tmux pane id (e.g. %42) lets the bash collector match this session
        # to the right remote tmux pane even when an agent has overwritten the
        # iTerm-displayed title via OSC 0/2. AppleScript can't read iTerm2
        # session variables; the Python API can. Variable names differ across
        # iTerm2 versions, so try several candidates.
        tmux_pane = await session_var(
            session, "tmux.pane", "tmuxPane", "user.tmux.pane", "tmux_pane"
        )
        tmux_window = await session_var(
            session, "tmux.window", "tmuxWindow", "user.tmux.window", "tmux_window"
        )
        is_virtual = bool(tmux_pane) and not tty
        text = ""
        last_line = old.get("last_line", "")
        processing = bool(old.get("processing", False))
        question = bool(old.get("question", False))
        if include_screen:
            text = await screen_text(session)
            if text:
                last_line, processing, question = analyze_text(text)
        status_override = self.custom_status.get(sid, {})
        agent = status_override.get("agent") or infer_agent(title, text, last_line)
        status = status_override.get("status")
        if not status:
            status = "running" if processing else "question" if question else "idle" if agent else "unknown"
        self.sessions[sid] = {
            "win": widx,
            "tab": tidx,
            "sess": sidx,
            "iterm_window_id": str(window.window_id),
            "uid": sid,
            "tty": basename(tty),
            "title": title,
            "cwd": cwd or old.get("cwd", ""),
            "ssh_host": host or old.get("ssh_host", ""),
            "tmux_pane": tmux_pane or old.get("tmux_pane", ""),
            "tmux_window": tmux_window or old.get("tmux_window", ""),
            "tmux_pane_id": old.get("tmux_pane_id", ""),
            "tmux_cc_controller": False,
            "tmux_cc_virtual": is_virtual or bool(old.get("tmux_cc_virtual", False)),
            "running": status_override.get("running", old.get("running", "")),
            "agent": agent,
            "status": status,
            "cpu": old.get("cpu", 0),
            "last_line": status_override.get("text") or last_line,
            "processing": processing or status == "running",
            "question": question or status == "question",
            "enriched": True,
            "updated_at": now(),
        }

    def schedule_screen_update(self, session_id: str) -> None:
        pending = self.pending_screen.get(session_id)
        if pending and not pending.done():
            return

        async def run() -> None:
            await asyncio.sleep(SCREEN_DEBOUNCE_SECONDS)
            last = self.last_screen_update.get(session_id, 0)
            wait = SCREEN_MIN_INTERVAL_SECONDS - (now() - last)
            if wait > 0:
                await asyncio.sleep(wait)
            self.last_screen_update[session_id] = now()
            await self.update_by_id(session_id, include_screen=True)

        self.pending_screen[session_id] = asyncio.create_task(run())

    def apply_custom_status(self, notification: Any) -> None:
        session_id = notification_session_id(notification)
        identity = first_attr(notification, ["identity", "id"])
        payload = first_attr(notification, ["payload", "json", "value", "text"])
        child = getattr(notification, "custom_escape_sequence", None)
        if child is not None:
            identity = identity or first_attr(child, ["identity", "id"])
            payload = payload or first_attr(child, ["payload", "json", "value", "text"])
        if identity and str(identity) not in ("xtermswitch", "com.extractum.xtermswitch"):
            return
        if not session_id or not payload:
            return
        try:
            data = json.loads(str(payload))
        except Exception:
            data = {"status": str(payload)}
        if isinstance(data, dict):
            self.custom_status[session_id] = data
            asyncio.create_task(self.update_by_id(session_id, include_screen=False))

    def schedule_write(self) -> None:
        if self.pending_write and not self.pending_write.done():
            return

        async def run() -> None:
            await asyncio.sleep(WRITE_DEBOUNCE_SECONDS)
            self.write_cache()

        self.pending_write = asyncio.create_task(run())

    def write_cache(self) -> None:
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        sessions = sorted(
            self.sessions.values(),
            key=lambda item: (item.get("win", 0), item.get("tab", 0), item.get("sess", 0), item.get("uid", "")),
        )
        # Hash the content (sans updated_at) so a stream of identical
        # screen-update events doesn't re-trigger Hammerspoon's file watcher
        # and re-render the picker for nothing.
        sessions_json = json.dumps(sessions, separators=(",", ":"), ensure_ascii=False, sort_keys=True)
        if sessions_json == self.last_payload_key:
            return
        self.last_payload_key = sessions_json
        payload = {
            "version": 1,
            "source": "iterm2-python",
            "updated_at": now(),
            "sessions": sessions,
        }
        fd, tmp_name = tempfile.mkstemp(prefix=".sessions.", suffix=".json", dir=str(CACHE_PATH.parent))
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(payload, f, separators=(",", ":"), ensure_ascii=False)
                f.write("\n")
            os.replace(tmp_name, CACHE_PATH)
        finally:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass


async def main(connection: iterm2.Connection) -> None:
    state = State(connection)
    all_sessions = iterm2.Session.all_proxy(connection)

    async def snapshot_callback(_connection, _notification):
        await state.snapshot_all()

    async def session_callback(_connection, notification):
        session_id = notification_session_id(notification)
        if session_id:
            await state.update_by_id(session_id, include_screen=True)
        else:
            await state.snapshot_all()

    async def terminate_callback(_connection, notification):
        session_id = notification_session_id(notification)
        if session_id:
            state.sessions.pop(session_id, None)
            state.custom_status.pop(session_id, None)
            state.last_screen_update.pop(session_id, None)
            pending = state.pending_screen.pop(session_id, None)
            if pending and not pending.done():
                pending.cancel()
            state.schedule_write()
        else:
            await state.snapshot_all()

    async def screen_callback(_connection, notification):
        session_id = notification_session_id(notification)
        if session_id:
            state.schedule_screen_update(session_id)

    async def custom_callback(_connection, notification):
        state.apply_custom_status(notification)

    # Initial snapshot pulls screen text so last_line/processing are populated
    # immediately. Subsequent layout/focus snapshots skip the per-session
    # screen RPC; screen_callback handles real screen changes.
    await state.snapshot_all(include_screen=True)
    await iterm2.notifications.async_subscribe_to_new_session_notification(connection, session_callback)
    await iterm2.notifications.async_subscribe_to_terminate_session_notification(connection, terminate_callback)
    await iterm2.notifications.async_subscribe_to_layout_change_notification(connection, snapshot_callback)
    await iterm2.notifications.async_subscribe_to_focus_change_notification(connection, snapshot_callback)
    await iterm2.notifications.async_subscribe_to_location_change_notification(connection, session_callback, session=all_sessions)
    await iterm2.notifications.async_subscribe_to_screen_update_notification(connection, screen_callback, session=all_sessions)
    await iterm2.notifications.async_subscribe_to_custom_escape_sequence_notification(connection, custom_callback, session=all_sessions)
    try:
        await iterm2.notifications.async_subscribe_to_prompt_notification(
            connection,
            session_callback,
            session=all_sessions,
            modes=[iterm2.PromptState.EDITING, iterm2.PromptState.RUNNING, iterm2.PromptState.FINISHED],
        )
    except Exception:
        pass
    while True:
        await asyncio.sleep(3600)


iterm2.run_forever(main, retry=True)
