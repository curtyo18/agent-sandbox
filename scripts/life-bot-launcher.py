#!/usr/bin/env python3
"""life-bot launcher — tiny HTTP utility that wakes a named claude session."""

import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8088
SESSION_NAME = "life-bot"

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>life-bot</title>
  <style>
    body {{ font-family: -apple-system, system-ui, sans-serif;
           background: #111; color: #eee;
           margin: 0; padding: 2rem;
           min-height: 100vh; display: flex;
           flex-direction: column; align-items: center; justify-content: center; }}
    h1     {{ font-size: 1.5rem; margin: 0 0 0.5rem; }}
    .state {{ font-family: monospace; font-size: 1rem; opacity: 0.8;
             margin-bottom: 2rem; }}
    .alive {{ color: #6ee7b7; }}
    .dead  {{ color: #fca5a5; }}
    a.btn  {{ display: inline-block; padding: 1rem 2rem;
             background: #2563eb; color: white; text-decoration: none;
             border-radius: 0.5rem; font-size: 1.1rem; font-weight: 600;
             min-width: 200px; text-align: center; }}
  </style>
</head>
<body>
  <h1>life-bot</h1>
  <p class="state {state_class}">{state_text}</p>
  <a class="btn" href="/wake">{button_text}</a>
</body>
</html>
"""


def session_alive() -> bool:
    """Return True if the named tmux session currently exists."""
    r = subprocess.run(
        ["tmux", "has-session", "-t", SESSION_NAME],
        capture_output=True,
        timeout=2,
    )
    return r.returncode == 0


def render_status_page() -> bytes:
    if session_alive():
        body = HTML_TEMPLATE.format(
            state_class="alive",
            state_text="● tmux session running in /projects/life",
            button_text="Restart life-bot",
        )
    else:
        body = HTML_TEMPLATE.format(
            state_class="dead",
            state_text="○ not running",
            button_text="Start life-bot",
        )
    return body.encode("utf-8")


def wake_session() -> None:
    """Kill any existing life-bot session, then spawn a fresh one running claude."""
    subprocess.run(
        ["tmux", "kill-session", "-t", SESSION_NAME],
        capture_output=True,  # tolerate "no such session"
        timeout=2,
    )
    subprocess.run(
        [
            "tmux", "new-session", "-d", "-s", SESSION_NAME,
            "bash", "-lc", "cd /projects/life && claude",
        ],
        check=True,
        timeout=5,
    )


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            body = render_status_page()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/wake":
            wake_session()
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        # Quiet stderr; default would spam every request.
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
