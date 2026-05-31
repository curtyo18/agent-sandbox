#!/usr/bin/env python3
"""Session launcher — tiny HTTP utility that wakes a named `claude --remote-control` session.

It inspects the session's pane and reports the *real* state — connected / starting / stuck /
exited — so failures surface in the UI instead of silently hanging. The page gives immediate
feedback on tap (a pulsing "starting…") and polls `/status` until the session reaches a
definitive state, so the button never just hangs.

Configure via env vars:
  LAUNCHER_SESSION  tmux session name (default: claude-session)
  LAUNCHER_PROJECT  working directory for claude (default: /projects)
  LAUNCHER_PORT     port to listen on (default: 8088)
"""

import html
import json
import os
import shlex
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT         = int(os.environ.get("LAUNCHER_PORT", "8088"))
SESSION_NAME = os.environ.get("LAUNCHER_SESSION", "claude-session")
PROJECT_PATH = os.environ.get("LAUNCHER_PROJECT", "/projects")
LOG_FILE     = "/tmp/session-launcher-claude.log"

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
    "starting":  "Connecting… this can take ~10s. The output below updates live.",
    "stuck":     "claude is blocked on the prompt shown below and can't be answered remotely. "
                 "A fresh container normally seeds folder-trust automatically.",
    "exited":    "claude isn't running. Tap the button; if it dies again the output below says why.",
}

PAGE = """<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>%%SESSION%%</title>
<style>
 body{font-family:-apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;
   padding:1.5rem;min-height:100vh;display:flex;flex-direction:column;align-items:center;}
 h1{font-size:1.4rem;margin:.2rem 0;}
 .state{font-family:monospace;font-size:1rem;margin:.5rem 0 1.2rem;text-align:center;min-height:1.2em;}
 .ok{color:#6ee7b7;} .bad{color:#fca5a5;}
 .warn{color:#fcd34d;animation:pulse 1.2s ease-in-out infinite;}
 @keyframes pulse{0%,100%{opacity:1;}50%{opacity:.4;}}
 a.btn{display:inline-block;padding:1rem 2rem;background:#2563eb;color:#fff;text-decoration:none;
   border-radius:.5rem;font-size:1.1rem;font-weight:600;min-width:220px;text-align:center;
   transition:background .2s;}
 a.btn.busy{background:#475569;pointer-events:none;opacity:.85;}
 pre{width:100%;max-width:680px;background:#000;color:#cbd5e1;border:1px solid #333;border-radius:.5rem;
   padding:.75rem;overflow:auto;font-size:.8rem;line-height:1.3;white-space:pre-wrap;margin-top:1.2rem;}
 pre:empty{display:none;}
 .hint{opacity:.6;font-size:.8rem;margin-top:.5rem;text-align:center;max-width:680px;}
</style></head>
<body data-session="%%SESSION%%" data-state="%%STATE%%">
 <h1>%%SESSION%%</h1>
 <p class="state %%CSS%%" id="state">%%HEADLINE%%</p>
 <a class="btn" id="go" href="/wake">%%BUTTON%%</a>
 <pre id="pane">%%PANE%%</pre>
 <p class="hint" id="hint">%%HINT%%</p>
<script>
(function(){
  var SESSION = document.body.dataset.session;
  var TERMINAL = ["connected", "stuck", "exited"];
  var stateEl = document.getElementById("state");
  var paneEl  = document.getElementById("pane");
  var hintEl  = document.getElementById("hint");
  var go      = document.getElementById("go");
  var polling = false;

  function apply(s){
    stateEl.textContent = s.headline;
    stateEl.className = "state " + s.css;
    paneEl.textContent = s.pane || "";
    if (s.hint){ hintEl.textContent = s.hint; }
    go.textContent = (s.state === "exited" ? "Start " : "Restart ") + SESSION;
    if (TERMINAL.indexOf(s.state) >= 0){ go.classList.remove("busy"); }
  }
  function poll(){
    fetch("/status", {cache: "no-store"})
      .then(function(r){ return r.json(); })
      .then(function(s){
        apply(s);
        if (TERMINAL.indexOf(s.state) < 0){ setTimeout(poll, 1500); }
        else { polling = false; }
      })
      .catch(function(){ polling = false; });
  }
  function startPolling(){ if (!polling){ polling = true; poll(); } }

  go.addEventListener("click", function(e){
    e.preventDefault();
    stateEl.textContent = "⟳ starting " + SESSION + "…";
    stateEl.className = "state warn";
    paneEl.textContent = "";
    go.classList.add("busy");
    go.textContent = "starting…";
    fetch("/wake", {cache: "no-store"}).then(function(r){
      if (!r.ok){
        return r.text().then(function(t){
          stateEl.textContent = (t || "wake failed").trim();
          stateEl.className = "state bad";
          go.classList.remove("busy");
          go.textContent = "Try again";
        });
      }
      startPolling();
    }).catch(function(){ location.href = "/wake"; });  // no-fetch fallback
  });

  if (document.body.dataset.state === "starting"){ startPolling(); }
})();
</script>
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

    claude must keep its TTY — piping its stdout makes it drop to non-interactive --print
    mode and exit — so we mirror the pane to a log via `pipe-pane` instead of a pipe.
    Returns immediately; the client polls /status to watch it connect.
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
    button = ("Start " if state == "exited" else "Restart ") + SESSION_NAME
    out = (PAGE
           .replace("%%SESSION%%", html.escape(SESSION_NAME))
           .replace("%%STATE%%", state)
           .replace("%%CSS%%", css)
           .replace("%%HEADLINE%%", html.escape(headline))
           .replace("%%BUTTON%%", html.escape(button))
           .replace("%%PANE%%", html.escape(pane))
           .replace("%%HINT%%", html.escape(HINTS[state])))
    return out.encode("utf-8")


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
        elif self.path == "/status":
            state, pane = session_status()
            css, headline = STATES[state]
            body = json.dumps({"state": state, "css": css, "headline": headline,
                               "pane": pane, "hint": HINTS[state]}).encode("utf-8")
            self._send(200, body, "application/json; charset=utf-8")
        elif self.path == "/wake":
            # Spawn and return immediately — the client shows "starting…" and polls /status.
            try:
                wake_session()
            except Exception as e:
                self._send(500, f"wake failed: {html.escape(str(e))}\n".encode("utf-8"),
                           "text/plain; charset=utf-8")
                return
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
