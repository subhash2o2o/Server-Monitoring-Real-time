from __future__ import annotations

import asyncio
import os
import time
from dataclasses import dataclass
from typing import AsyncIterator, Optional

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from watchfiles import awatch


app = FastAPI(title="SSE Log Stream", version="1.0.0")


@dataclass(frozen=True)
class Settings:
    log_path: str
    start_from_beginning: bool
    heartbeat_seconds: float


def get_settings() -> Settings:
    log_path = os.getenv("LOG_PATH", "/logs/deploy.log")
    start_from_beginning = os.getenv("START_FROM_BEGINNING", "0") == "1"
    heartbeat_seconds = float(os.getenv("HEARTBEAT_SECONDS", "10"))
    return Settings(
        log_path=log_path,
        start_from_beginning=start_from_beginning,
        heartbeat_seconds=heartbeat_seconds,
    )


def sse_event(*, event: str, data: str, event_id: Optional[str] = None) -> str:
    # SSE framing: https://html.spec.whatwg.org/multipage/server-sent-events.html
    # Note: if data contains newlines, each line must be prefixed with 'data:'.
    lines = data.splitlines() or [""]
    parts: list[str] = []
    if event_id is not None:
        parts.append(f"id: {event_id}")
    parts.append(f"event: {event}")
    for line in lines:
        parts.append(f"data: {line}")
    parts.append("")
    return "\n".join(parts) + "\n"


def _safe_dirname(path: str) -> str:
    d = os.path.dirname(os.path.abspath(path))
    return d if d else "."


def _read_new_bytes(path: str, start_offset: int) -> tuple[str, int]:
    # Synchronous file read; FastAPI does not execute shell commands.
    # We open/seek/read to avoid holding a file handle forever.
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        f.seek(start_offset)
        chunk = f.read()
        end_offset = f.tell()
    return chunk, end_offset


async def _tail_file_sse(request: Request, settings: Settings) -> AsyncIterator[str]:
    # Each client gets an independent tailer.
    # This supports multiple concurrent clients safely.

    log_path = settings.log_path
    log_dir = _safe_dirname(log_path)

    # Ensure directory exists; if file doesn't exist yet, we still stream heartbeats
    # and start reading once it appears.
    os.makedirs(log_dir, exist_ok=True)

    # Start offset: end-of-file by default (stream only new logs)
    offset = 0
    if not settings.start_from_beginning and os.path.exists(log_path):
        try:
            offset = os.path.getsize(log_path)
        except OSError:
            offset = 0

    # Initial hello event (helps clients render "connected" state)
    yield sse_event(event="heartbeat", data="ping")

    # Watch the directory for changes (no polling). Heartbeats are sent on timeout.
    watcher = awatch(log_dir)

    while True:
        if await request.is_disconnected():
            return

        try:
            # Wait for file changes; timeout drives heartbeat.
            await asyncio.wait_for(watcher.__anext__(), timeout=settings.heartbeat_seconds)
        except asyncio.TimeoutError:
            yield sse_event(event="heartbeat", data="ping")
            continue
        except StopAsyncIteration:
            # Shouldn't usually happen, but end gracefully.
            return
        except asyncio.CancelledError:
            # Client disconnected / server shutdown.
            return

        # Directory changed; try reading new bytes from the target log.
        if not os.path.exists(log_path):
            continue

        try:
            chunk, offset = _read_new_bytes(log_path, offset)
        except OSError:
            # File rotated or temporarily unavailable; reset offset safely.
            offset = 0
            continue

        if not chunk:
            continue

        # Emit each new line as a 'log' SSE event.
        # Keep latency low by streaming immediately.
        for raw_line in chunk.splitlines():
            if await request.is_disconnected():
                return
            line = raw_line.rstrip("\r\n")
            # Simple event id for client resume; time-based is fine here.
            event_id = str(int(time.time() * 1000))
            yield sse_event(event="log", data=line, event_id=event_id)


@app.get("/events")
async def events(request: Request) -> StreamingResponse:
    settings = get_settings()

    headers = {
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "X-Accel-Buffering": "no",  # important for nginx
    }

    return StreamingResponse(
        _tail_file_sse(request, settings),
        media_type="text/event-stream",
        headers=headers,
    )


@app.get("/", response_class=HTMLResponse)
async def index() -> HTMLResponse:
    # Convenience for local/dev. In production, Nginx serves web/index.html.
    html = """
<!doctype html>
<html>
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>SSE Log Stream</title>
  <style>
    body { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; margin: 0; }
    header { padding: 12px 16px; background: #111827; color: #fff; }
    #status { opacity: 0.85; font-size: 12px; }
    #log { height: calc(100vh - 56px); overflow: auto; padding: 12px 16px; background: #0b1020; color: #d1d5db; }
    .line { white-space: pre-wrap; }
    .INFO { color: #a7f3d0; }
    .WARN { color: #fde68a; }
    .ERROR { color: #fca5a5; }
  </style>
</head>
<body>
  <header>
    <div><strong>Real-time Deploy Logs (SSE)</strong></div>
    <div id=\"status\">connecting…</div>
  </header>
  <div id=\"log\"></div>

  <script>
    const statusEl = document.getElementById('status');
    const logEl = document.getElementById('log');

    function appendLine(text) {
      const div = document.createElement('div');
      div.className = 'line';
      const m = text.match(/\|\s+(INFO|WARN|ERROR)\s+\|/);
      if (m) div.classList.add(m[1]);
      div.textContent = text;
      logEl.appendChild(div);
      logEl.scrollTop = logEl.scrollHeight;
    }

    let es;
    function connect() {
      statusEl.textContent = 'connecting…';
      es = new EventSource('/events');

      es.addEventListener('log', (ev) => {
        appendLine(ev.data);
      });

      es.addEventListener('heartbeat', (_ev) => {
        statusEl.textContent = 'connected (heartbeat OK)';
      });

      es.onerror = () => {
        statusEl.textContent = 'disconnected; retrying…';
        // EventSource auto-reconnects; keep UI state.
      };
    }

    connect();
  </script>
</body>
</html>
"""
    return HTMLResponse(content=html)
