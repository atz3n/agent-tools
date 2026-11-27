#!/usr/bin/env python3
"""Command bridge between agent requests and the Thunderbird add-on.

The add-on cannot be reached over HTTP (a WebExtension only dials out), so
agent requests are turned into commands, queued, picked up by the add-on's
long-poll, and resolved when it reports the result back. The original agent
request blocks on a per-command event until then — or times out.
"""

from __future__ import annotations

import itertools
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any

from . import config


class BridgeError(Exception):
    """A failure to translate into an HTTP status for the agent."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass
class _Pending:
    id: str
    command: str
    params: dict[str, Any]
    event: threading.Event = field(default_factory=threading.Event)
    result: Any = None
    error: str | None = None


class Bridge:
    """Thread-safe command queue with request↔result correlation."""

    def __init__(self) -> None:
        self._cond = threading.Condition()
        self._queue: deque[_Pending] = deque()
        self._pending: dict[str, _Pending] = {}
        self._ids = itertools.count(1)
        self._last_seen = 0.0
        self._registered = False
        self._addon_info: dict[str, Any] = {}

    # -- add-on face ---------------------------------------------------------

    def hello(self, info: dict[str, Any]) -> None:
        with self._cond:
            self._addon_info = dict(info)
            self._registered = True
            self._last_seen = time.time()
            self._cond.notify_all()

    def poll(self, wait: float | None = None) -> dict[str, Any] | None:
        """Hand the add-on one queued command, holding the call up to `wait`."""
        deadline = time.monotonic() + (config.ADDON_POLL_WAIT if wait is None else wait)
        with self._cond:
            self._last_seen = time.time()
            while not self._queue:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self._cond.wait(remaining)
            item = self._queue.popleft()
        return {"id": item.id, "command": item.command, "params": item.params}

    def report(self, command_id: str, ok: bool, data: Any, error: str | None) -> bool:
        """Deliver an execution result; False when the id is unknown."""
        with self._cond:
            item = self._pending.get(command_id)
        if item is None:
            return False
        item.result = data
        item.error = None if ok else (error or "command failed")
        item.event.set()
        return True

    # -- agent face ------------------------------------------------------------

    def connected(self) -> bool:
        return self._registered and time.time() - self._last_seen <= config.ADDON_STALE_AFTER

    def status(self) -> dict[str, Any]:
        with self._cond:
            return {
                "connected": self.connected(),
                "lastSeen": self._last_seen or None,
                "queued": len(self._queue),
                "addon": self._addon_info,
            }

    def submit(self, command: str, params: dict[str, Any]) -> Any:
        """Queue a command and block until the add-on reports, or raise."""
        item = _Pending(id=f"c{next(self._ids)}", command=command, params=params)
        with self._cond:
            if not self.connected():
                raise BridgeError(504, "thunderbird not connected — is it running with the proxy add-on enabled?")
            self._pending[item.id] = item
            self._queue.append(item)
            self._cond.notify_all()
        if not item.event.wait(config.COMMAND_TIMEOUT):
            with self._cond:
                self._pending.pop(item.id, None)
                try:
                    self._queue.remove(item)
                except ValueError:
                    pass
            raise BridgeError(504, f"command '{command}' timed out after {config.COMMAND_TIMEOUT}s")
        with self._cond:
            self._pending.pop(item.id, None)
        if item.error is not None:
            raise BridgeError(502, item.error)
        return item.result
