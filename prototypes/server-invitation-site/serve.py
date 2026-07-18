#!/usr/bin/env python3
"""Serve the static invitation prototype with the AASA JSON MIME type."""

from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SITE_ROOT = Path(__file__).resolve().parent


class StaticHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SITE_ROOT), **kwargs)

    def guess_type(self, path):
        if path.endswith("/.well-known/apple-app-site-association"):
            return "application/json"
        return super().guess_type(path)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), StaticHandler).serve_forever()
