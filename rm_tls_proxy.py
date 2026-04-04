#!/usr/bin/env python3
"""
Local TLS reverse proxy for reMarkable desktop app.

Works around an OpenSSL 3.6.x TLS 1.3 incompatibility between the app's
bundled OpenSSL and reMarkable's GCP-hosted discovery endpoint.

This proxy:
  1. Accepts HTTPS connections from the app on localhost:18443
  2. Forwards them to the real server (35.201.126.131) using system
     Python's LibreSSL, which handles TLS correctly

Requires:
  - /etc/hosts entry: 127.0.0.1 internal.cloud.remarkable.com
  - pf redirect: port 443 -> 18443 on lo0
  - Self-signed cert appended to /etc/ssl/cert.pem
  - App launched with ENABLE_CURL_HTTP_BACKEND=1

Must be run with /usr/bin/python3 (system Python with LibreSSL),
NOT a user-installed Python (which likely has OpenSSL 3.6.x).
"""

import ssl
import http.server
import urllib.request
import os
import socket
import sys

REAL_IP = "35.201.126.131"
REAL_HOST = "internal.cloud.remarkable.com"
LISTEN_PORT = 18443
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CERT_FILE = os.path.join(SCRIPT_DIR, "rm_cert.pem")
KEY_FILE = os.path.join(SCRIPT_DIR, "rm_key.pem")


def resolve_real_ip():
    """Resolve the real IP, bypassing /etc/hosts override."""
    # Hardcoded fallback in case DNS returns localhost due to /etc/hosts
    try:
        ip = socket.getaddrinfo(REAL_HOST, 443, socket.AF_INET)[0][4][0]
        if ip.startswith("127."):
            return REAL_IP
        return ip
    except Exception:
        return REAL_IP


class ReverseProxy(http.server.BaseHTTPRequestHandler):
    def _proxy(self, method):
        target = "https://%s%s" % (resolve_real_ip(), self.path)
        body = None
        if method in ("POST", "PUT"):
            cl = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(cl) if cl > 0 else None

        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        req = urllib.request.Request(target, data=body, method=method)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "connection", "transfer-encoding"):
                req.add_header(k, v)
        req.add_header("Host", REAL_HOST)

        try:
            resp = urllib.request.urlopen(req, context=ctx, timeout=30)
            data = resp.read()
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in ("transfer-encoding", "connection"):
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)
            sys.stdout.write(
                "OK %s %s -> %d (%db)\n" % (method, self.path, resp.status, len(data))
            )
            sys.stdout.flush()
        except Exception as e:
            sys.stdout.write("ERR %s %s -> %s\n" % (method, self.path, e))
            sys.stdout.flush()
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_PUT(self):
        self._proxy("PUT")

    def do_DELETE(self):
        self._proxy("DELETE")

    def do_PATCH(self):
        self._proxy("PATCH")

    def log_message(self, *a):
        pass


def main():
    if not os.path.exists(CERT_FILE) or not os.path.exists(KEY_FILE):
        sys.stderr.write("Error: %s or %s not found\n" % (CERT_FILE, KEY_FILE))
        sys.exit(1)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS)
    ctx.load_cert_chain(CERT_FILE, KEY_FILE)

    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), ReverseProxy)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    sys.stdout.write(
        "reMarkable TLS proxy on https://127.0.0.1:%d -> %s (%s)\n"
        % (LISTEN_PORT, REAL_HOST, REAL_IP)
    )
    sys.stdout.write("Using %s\n" % ssl.OPENSSL_VERSION)
    sys.stdout.flush()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stdout.write("\nProxy stopped.\n")


if __name__ == "__main__":
    main()
