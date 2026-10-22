"""Sample service for the secure CI/CD pipeline reference implementation.

A deliberately small HTTP service built only on the Python standard
library (``http.server``). Keeping the runtime dependency-free is the
point: the interesting surface of this repository is the pipeline, and
a zero-dependency service keeps the build, scan, and promotion stages
fast and reproducible. Swapping in FastAPI/Flask changes nothing about
the pipeline contract.

Endpoints:
    GET  /health            Liveness/readiness probe.
    GET  /                  Service index.
    GET  /api/v1/greet      Greeting with an optional ``?name=`` query.
    POST /api/v1/echo       Echoes a JSON request body back as JSON.

Routing lives in the pure function :func:`route` so unit tests can
exercise every endpoint without opening a socket.
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SERVICE_NAME = "sample-service"
SERVICE_VERSION = os.environ.get("SERVICE_VERSION", "0.1.0")


def route(method: str, raw_path: str, body: bytes = b"") -> tuple[int, dict]:
    """Route one request and return ``(status_code, json_payload)``.

    Pure function: no I/O, no globals mutated. The HTTP handler below
    is a thin adapter over this function.
    """
    parsed = urlparse(raw_path)
    path = parsed.path
    query = parse_qs(parsed.query)

    if method == "GET" and path == "/health":
        return 200, {
            "status": "ok",
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
        }

    if method == "GET" and path == "/":
        return 200, {
            "service": SERVICE_NAME,
            "version": SERVICE_VERSION,
            "endpoints": ["/health", "/api/v1/greet", "/api/v1/echo"],
        }

    if method == "GET" and path == "/api/v1/greet":
        name = (query.get("name") or ["World"])[0].strip() or "World"
        if len(name) > 100:
            return 400, {"error": "name must be 100 characters or fewer"}
        return 200, {"message": f"Hello, {name}!"}

    if method == "POST" and path == "/api/v1/echo":
        if not body:
            return 400, {"error": "request body must be valid JSON"}
        try:
            payload = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return 400, {"error": "request body must be valid JSON"}
        return 200, {"echo": payload}

    return 404, {"error": "not found", "path": path}


class Handler(BaseHTTPRequestHandler):
    """Thin HTTP adapter over :func:`route`."""

    server_version = "SampleService/1.0"

    def _handle(self, method: str) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        status, payload = route(method, self.path, body)
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._handle("GET")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._handle("POST")

    def log_message(self, format: str, *args: object) -> None:
        # Keep container logs structured-ish and quiet: one line per hit
        # on stderr is the http.server default; suppressing it here keeps
        # demo output clean. Real deployments ship access logs to the
        # platform log aggregator instead.
        pass


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"{SERVICE_NAME} {SERVICE_VERSION} listening on :{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
