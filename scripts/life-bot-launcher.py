#!/usr/bin/env python3
"""life-bot launcher — tiny HTTP utility that wakes a named claude session."""

from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8088


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            body = b"hello from life-bot launcher\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        # Quiet stderr; default would spam every request.
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
