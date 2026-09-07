#!/usr/bin/env python3
"""
Minimal fake Polar server for manually verifying Peek3D's single-machine
activation layer against the REAL compiled app — not a mock used inside a
unit test, an actual HTTP server the real `HTTPPolarLicenseAPIClient`
connects to.

Implements the exact request/response shapes of
POST /v1/customer-portal/license-keys/{activate,validate,deactivate} as
read from Polar's live OpenAPI document (see PolarLicenseConfig.swift's doc
comment for the verification trail).

Usage:
    PEEK3D_FAKE_POLAR_MODE=success  python3 scripts/fake_polar_server.py [port]
    PEEK3D_FAKE_POLAR_MODE=conflict python3 scripts/fake_polar_server.py [port]
    PEEK3D_FAKE_POLAR_MODE=revoked  python3 scripts/fake_polar_server.py [port]

Modes:
    success  - /activate succeeds, returns a fresh activation id.
               /validate returns status "granted".
    conflict - /activate returns 403 NotPermitted ("already active
               elsewhere" case).
    revoked  - /validate returns status "revoked" (activate still succeeds,
               so a device can get INTO the revoked state to observe it).

Every request is logged to stdout: method, path, and the parsed JSON body —
this is how you SEE the machine identifier (the "label" field) arrive in a
real /activate request from the real app, not just infer it from source.

Not started with the server simply DOWN (mode irrelevant) is the third
manual-verification case: kill this process entirely and the app must keep
working, never degrading local state.
"""
import http.server
import json
import os
import sys
import uuid

MODE = os.environ.get("PEEK3D_FAKE_POLAR_MODE", "success")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8933


class Handler(http.server.BaseHTTPRequestHandler):
    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {}

    def _respond(self, status, body):
        payload = json.dumps(body).encode("utf-8") if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def log_message(self, format, *args):
        # Default BaseHTTPRequestHandler logging is noisy (adds its own
        # timestamp/status line to stderr); route through our own
        # request-body logging in do_POST instead, so output stays focused
        # on what this task's verification actually needs to show.
        pass

    def do_POST(self):
        body = self._read_json()
        print(f"--> POST {self.path}")
        print(f"    body: {json.dumps(body)}")
        sys.stdout.flush()

        if self.path == "/v1/customer-portal/license-keys/activate":
            if MODE == "conflict":
                print("    <-- 403 NotPermitted (activation limit reached)")
                self._respond(403, {"error": "NotPermitted", "detail": "License key activation limit already reached."})
                return
            activation_id = str(uuid.uuid4())
            print(f"    <-- 200 activation_id={activation_id}")
            self._respond(200, {
                "id": activation_id,
                "license_key_id": str(uuid.uuid4()),
                "label": body.get("label", ""),
                "meta": {},
                "created_at": "2026-08-14T00:00:00Z",
                "modified_at": None,
                "license_key": {
                    "id": str(uuid.uuid4()),
                    "created_at": "2026-08-14T00:00:00Z",
                    "modified_at": None,
                    "organization_id": body.get("organization_id", ""),
                    "customer_id": str(uuid.uuid4()),
                    "customer": {"id": str(uuid.uuid4()), "email": "fixture@peek3d.app"},
                    "benefit_id": str(uuid.uuid4()),
                    "key": body.get("key", ""),
                    "display_key": "****",
                    "status": "granted",
                    "limit_activations": 1,
                    "usage": 0,
                    "limit_usage": None,
                    "validations": 0,
                    "last_validated_at": None,
                    "expires_at": None,
                },
            })
            return

        if self.path == "/v1/customer-portal/license-keys/validate":
            status = "revoked" if MODE == "revoked" else "granted"
            print(f"    <-- 200 status={status}")
            self._respond(200, {
                "id": str(uuid.uuid4()),
                "created_at": "2026-08-14T00:00:00Z",
                "modified_at": None,
                "organization_id": body.get("organization_id", ""),
                "customer_id": str(uuid.uuid4()),
                "customer": {"id": str(uuid.uuid4()), "email": "fixture@peek3d.app"},
                "benefit_id": str(uuid.uuid4()),
                "key": body.get("key", ""),
                "display_key": "****",
                "status": status,
                "limit_activations": 1,
                "usage": 0,
                "limit_usage": None,
                "validations": 1,
                "last_validated_at": "2026-08-14T00:00:00Z",
                "expires_at": None,
                "activation": None,
            })
            return

        if self.path == "/v1/customer-portal/license-keys/deactivate":
            print("    <-- 204")
            self._respond(204, None)
            return

        print("    <-- 404 unknown path")
        self._respond(404, {"error": "ResourceNotFound", "detail": "unknown path"})


if __name__ == "__main__":
    print(f"fake Polar server: mode={MODE} port={PORT}")
    sys.stdout.flush()
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
