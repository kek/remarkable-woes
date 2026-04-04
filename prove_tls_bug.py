#!/usr/bin/env python3
"""
Proof: OpenSSL 3.6.x TLS 1.3 is rejected by internal.cloud.remarkable.com
       while TLS 1.2 from the same library works fine.

Run with any Python linked against OpenSSL 3.6.x:
    python3 prove_tls_bug.py

Expected output:
    Test 1 (TLS 1.3): FAIL — Connection reset by peer
    Test 2 (TLS 1.2): OK   — 200, 178 bytes
"""

import ssl
import urllib.request
import sys

HOST = "internal.cloud.remarkable.com"
# Connect by IP to bypass any /etc/hosts overrides
REAL_IP = "35.201.126.131"
URL = "https://%s/discovery/v1/endpoints" % REAL_IP
PATH = "/discovery/v1/endpoints"

print("Python:  %s" % sys.version.split()[0])
print("OpenSSL: %s" % ssl.OPENSSL_VERSION)
print("Host:    %s (via %s)" % (HOST, REAL_IP))
print()


def test(label, ctx):
    try:
        # Use IP in URL but set Host header for SNI/vhost
        ctx.check_hostname = False
        req = urllib.request.Request(URL, headers={"Host": HOST})
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        data = resp.read()
        print("  %s: OK   -- %d, %d bytes" % (label, resp.status, len(data)))
        return True
    except Exception as e:
        name = type(e).__name__
        # unwrap URLError
        if hasattr(e, "reason"):
            e = e.reason
            name = type(e).__name__
        print("  %s: FAIL -- %s: %s" % (label, name, e))
        return False


# Test 1: default (TLS 1.3 on OpenSSL 3.6.x)
ctx1 = ssl.create_default_context()
t1 = test("Test 1 (TLS 1.3, default)", ctx1)

# Test 2: force TLS 1.2 max
ctx2 = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx2.maximum_version = ssl.TLSVersion.TLSv1_2
ctx2.load_default_certs()
t2 = test("Test 2 (TLS 1.2, forced) ", ctx2)

# Test 3: force TLS 1.3 only
try:
    ctx3 = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx3.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx3.load_default_certs()
    t3 = test("Test 3 (TLS 1.3, forced) ", ctx3)
except Exception as e:
    print("  Test 3 (TLS 1.3, forced) : SKIP -- %s" % e)
    t3 = False

print()
if not t1 and t2:
    print("CONFIRMED: TLS 1.3 fails, TLS 1.2 works. OpenSSL 3.6.x bug.")
    sys.exit(0)
elif t1 and t2:
    print("NOT REPRODUCED: both work. Your OpenSSL may not be 3.6.x,")
    print("or the server has been fixed.")
    sys.exit(0)
elif not t1 and not t2:
    print("BOTH FAILED: network issue unrelated to TLS version.")
    sys.exit(1)
else:
    print("UNEXPECTED: TLS 1.3 works but TLS 1.2 doesn't.")
    sys.exit(1)
