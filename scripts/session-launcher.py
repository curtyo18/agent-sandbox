#!/usr/bin/env python3
"""Session launcher — tiny HTTP utility that wakes a named `claude --remote-control` session.

Rather than a naive "did tmux start?" check (which reports success even when claude is hung
on a prompt), this inspects the session's pane and reports the *real* state — connected /
still starting / blocked on a prompt / exited — so failures surface in the UI instead of
silently hanging.

Configure via env vars:
  LAUNCHER_SESSION  tmux session name (default: claude-session)
  LAUNCHER_PROJECT  working directory for claude (default: /projects)
  LAUNCHER_PORT     port to listen on (default: 8088)
"""

import html
import os
import shlex
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT         = int(os.environ.get("LAUNCHER_PORT", "8088"))
SESSION_NAME = os.environ.get("LAUNCHER_SESSION", "claude-session")
PROJECT_PATH = os.environ.get("LAUNCHER_PROJECT", "/projects")
LOG_FILE     = "/tmp/session-launcher-claude.log"
WAKE_TIMEOUT = 15   # seconds to wait for a definitive state after spawning

# Pane text meaning "up and Remote Control connected".
OK_MARKERS = ("remote control active", "remote-control is active")
# Pane text meaning "alive but blocked on input we can't supply from a detached session".
STUCK_MARKERS = (
    "is this a project you", "trust this folder",        # workspace-trust dialog
    "enter to confirm",                                  # generic TUI menu
    "claude login", "invalid api key", "please log in",  # auth
)

# state -> (css class, headline)
STATES = {
    "connected": ("ok",   "● Remote Control active — open the Claude app"),
    "starting":  ("warn", "● started — waiting for Remote Control to connect…"),
    "stuck":     ("bad",  "▲ needs attention — claude is waiting for input it can't get here"),
    "exited":    ("bad",  "○ not running"),
}
HINTS = {
    "connected": "Switch to the Claude app → Code tab; this session should be listed.",
    "starting":  "Reload in a few seconds. If it stays here, the output above shows why.",
    "stuck":     "claude is blocked on the prompt shown above and can't be answered remotely. "
                 "A fresh container normally seeds folder-trust automatically.",
    "exited":    "claude isn't running. Tap the button; if it dies again the output above says why.",
}

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{session}</title>
<style>
 body{{font-family:-apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;
   padding:1.5rem;min-height:100vh;display:flex;flex-direction:column;align-items:center;}}
 h1{{font-size:1.4rem;margin:.2rem 0;}}
 .state{{font-family:monospace;font-size:1rem;margin:.5rem 0 1.2rem;text-align:center;}}
 .ok{{color:#6ee7b7;}} .warn{{color:#fcd34d;}} .bad{{color:#fca5a5;}}
 a.btn{{display:inline-block;padding:1rem 2rem;background:#2563eb;color:#fff;text-decoration:none;
   border-radius:.5rem;font-size:1.1rem;font-weight:600;min-width:220px;text-align:center;}}
 pre{{width:100%;max-width:680px;background:#000;color:#cbd5e1;border:1px solid #333;
   border-radius:.5rem;padding:.75rem;overflow:auto;font-size:.8rem;line-height:1.3;
   white-space:pre-wrap;margin-top:1.2rem;}}
 .hint{{opacity:.6;font-size:.8rem;margin-top:.5rem;text-align:center;max-width:680px;}}
</style></head><body>
 <h1>{session}</h1>
 <p class="state {css}">{headline}</p>
 <a class="btn" href="/wake">{button}</a>
 {pane_block}
 <p class="hint">{hint}</p>
</body></html>
"""


def _tmux(*args, timeout=3):
    try:
        return subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 1, "", "tmux timed out")


def session_alive() -> bool:
    return _tmux("has-session", "-t", SESSION_NAME).returncode == 0


def capture_pane(lines: int = 40) -> str:
    r = _tmux("capture-pane", "-t", SESSION_NAME, "-p", "-S", f"-{lines}")
    if r.returncode != 0:
        return ""
    return "\n".join(line.rstrip() for line in r.stdout.splitlines()).strip()


def session_status():
    """Return (state, pane) where state is connected / stuck / starting / exited."""
    if not session_alive():
        return "exited", ""
    pane = capture_pane()
    low = pane.lower()
    if any(m in low for m in OK_MARKERS):
        return "connected", pane
    if any(m in low for m in STUCK_MARKERS):
        return "stuck", pane
    return "starting", pane


def wake_session() -> None:
    """Kill any existing session, then spawn a fresh claude in a real TTY pane.

    Note: claude must keep its TTY — piping its stdout makes it drop to non-interactive
    --print mode and exit. So we mirror the pane to a log via `pipe-pane` instead of a pipe.
    """
    _tmux("kill-session", "-t", SESSION_NAME)  # tolerate "no such session"
    cmd = (f"cd {shlex.quote(PROJECT_PATH)} && "
           f"exec claude --dangerously-skip-permissions --remote-control {shlex.quote(SESSION_NAME)}")
    r = _tmux("new-session", "-d", "-s", SESSION_NAME, "bash", "-lc", cmd, timeout=6)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "tmux new-session failed")
    _tmux("pipe-pane", "-t", SESSION_NAME, "-o", f"cat >> {shlex.quote(LOG_FILE)}")


def render_page() -> bytes:
    state, pane = session_status()
    css, headline = STATES[state]
    button = f"Start {SESSION_NAME}" if state == "exited" else f"Restart {SESSION_NAME}"
    pane_block = f"<pre>{html.escape(pane)}</pre>" if pane else ""
    return HTML_TEMPLATE.format(
        session=html.escape(SESSION_NAME),
        css=css,
        headline=html.escape(headline),
        button=html.escape(button),
        pane_block=pane_block,
        hint=html.escape(HINTS[state]),
    ).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, ctype: str = "text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self._send(200, render_page())
        elif self.path == "/wake":
            try:
                wake_session()
            except Exception as e:  # surface the failure instead of pretending success
                self._send(500, f"wake failed: {html.escape(str(e))}\n".encode("utf-8"),
                           "text/plain; charset=utf-8")
                return
            # Wait for a definitive outcome so the status page shows the real result,
            # not a perpetual "starting". Break early once connected / stuck / exited.
            deadline = time.time() + WAKE_TIMEOUT
            while time.time() < deadline:
                time.sleep(1)
                if session_status()[0] in ("connected", "stuck", "exited"):
                    break
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        pass  # quiet; default spams every request


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
