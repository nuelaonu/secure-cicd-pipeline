"""Unit tests for the sample service.

Written with the standard-library ``unittest`` runner so they execute
with zero installed dependencies (``python -m unittest``) and are also
collected unchanged by ``pytest`` in CI.

Run locally:
    python -m unittest discover -s tests -v
    # or, with dev dependencies installed:
    pytest -q
"""

import json
import sys
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.main import Handler, route  # noqa: E402


class RouteTests(unittest.TestCase):
    def test_health(self):
        status, payload = route("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["service"], "sample-service")

    def test_index_lists_endpoints(self):
        status, payload = route("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn("/health", payload["endpoints"])

    def test_greet_default_name(self):
        status, payload = route("GET", "/api/v1/greet")
        self.assertEqual(status, 200)
        self.assertEqual(payload["message"], "Hello, World!")

    def test_greet_with_name(self):
        status, payload = route("GET", "/api/v1/greet?name=Pipeline")
        self.assertEqual(status, 200)
        self.assertEqual(payload["message"], "Hello, Pipeline!")

    def test_greet_rejects_overlong_name(self):
        status, _ = route("GET", "/api/v1/greet?name=" + "x" * 101)
        self.assertEqual(status, 400)

    def test_echo_round_trips_json(self):
        status, payload = route("POST", "/api/v1/echo", b'{"gate": "sonar"}')
        self.assertEqual(status, 200)
        self.assertEqual(payload["echo"], {"gate": "sonar"})

    def test_echo_rejects_invalid_json(self):
        status, _ = route("POST", "/api/v1/echo", b"not-json")
        self.assertEqual(status, 400)

    def test_echo_rejects_empty_body(self):
        status, _ = route("POST", "/api/v1/echo", b"")
        self.assertEqual(status, 400)

    def test_unknown_path_is_404(self):
        status, payload = route("GET", "/does-not-exist")
        self.assertEqual(status, 404)
        self.assertEqual(payload["error"], "not found")

    def test_wrong_method_is_404(self):
        status, _ = route("POST", "/health", b"{}")
        self.assertEqual(status, 404)


class LiveServerTests(unittest.TestCase):
    """One end-to-end check that the HTTP adapter serves route() output."""

    def test_health_over_http(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=5
            ) as response:
                payload = json.loads(response.read())
            self.assertEqual(response.status, 200)
            self.assertEqual(payload["status"], "ok")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
