#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tiny local captive portal used by the no-root integration simulation."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class PortalHandler(BaseHTTPRequestHandler):
    authorized = False

    def do_GET(self):
        if self.path.startswith("/generate_204"):
            if PortalHandler.authorized:
                self.send_response(204)
                self.end_headers()
            else:
                authority = self.headers.get("Host")
                if not authority:
                    host, port = self.server.server_address
                    authority = f"{host}:{port}"
                self.send_response(302)
                self.send_header("Location", f"http://{authority}/login")
                self.end_headers()
            return

        if self.path.startswith("/login"):
            PortalHandler.authorized = True
            body = b"portal login accepted\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, _format, *_args):
        pass


parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=0)
args = parser.parse_args()

server = ThreadingHTTPServer((args.host, args.port), PortalHandler)
print(server.server_address[1], flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
