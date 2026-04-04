#!/bin/bash
#
# Proof: the reMarkable discovery endpoint rejects TLS 1.3 from OpenSSL 3.6.x
# but accepts TLS 1.3 from LibreSSL/SecureTransport and TLS 1.2 from anything.
#
# Connects by IP (35.201.126.131) to bypass any /etc/hosts overrides.
# No dependencies beyond macOS defaults and a Python with OpenSSL 3.6.x.

set -u

HOST="internal.cloud.remarkable.com"
REAL_IP="35.201.126.131"
URL="https://$HOST/discovery/v1/endpoints"
SYSTEM_PYTHON="/usr/bin/python3"
USER_PYTHON="$(which python3 2>/dev/null)"

header() { printf "\n\033[1m%s\033[0m\n" "$1"; }
ok()     { printf "  \033[32mOK\033[0m   %s\n" "$1"; }
fail()   { printf "  \033[31mFAIL\033[0m %s\n" "$1"; }

echo "========================================"
echo " reMarkable TLS 1.3 Bug — Proof Script"
echo "========================================"
echo ""
echo "Host:    $HOST"
echo "Real IP: $REAL_IP (bypasses /etc/hosts)"

# Helper: Python snippet that connects by IP with Host header set
py_test_tls() {
    local PYTHON="$1"
    local MAX_TLS="$2"  # "default" or "TLSv1_2"

    $PYTHON -c "
import ssl, urllib.request
ip = '$REAL_IP'
host = '$HOST'
url = 'https://%s/discovery/v1/endpoints' % ip

if '$MAX_TLS' == 'TLSv1_2':
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_default_certs()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
else:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

req = urllib.request.Request(url, headers={'Host': host})
try:
    r = urllib.request.urlopen(req, context=ctx, timeout=10)
    print('OK %d' % r.status)
except Exception as e:
    reason = getattr(e, 'reason', e)
    print('FAIL %s' % reason)
" 2>&1
}

# ── Test 1: system curl (LibreSSL / SecureTransport) ──────────────────

header "Test 1: system curl (LibreSSL / SecureTransport)"
CURL_VER=$(/usr/bin/curl --version | head -1)
echo "  Binary:  /usr/bin/curl"
echo "  Version: $CURL_VER"

BODY=$(/usr/bin/curl -s --connect-timeout 10 --resolve "$HOST:443:$REAL_IP" "$URL" 2>&1)
if echo "$BODY" | grep -q "notifications"; then
    ok "TLS 1.3 works with LibreSSL / SecureTransport"
else
    fail "unexpected: $BODY"
fi

# ── Test 2: system Python (LibreSSL) ──────────────────────────────────

header "Test 2: system Python (LibreSSL) — TLS default"
SSL_VER=$($SYSTEM_PYTHON -c "import ssl; print(ssl.OPENSSL_VERSION)" 2>/dev/null)
echo "  Binary:  $SYSTEM_PYTHON"
echo "  SSL:     $SSL_VER"

RESULT=$(py_test_tls "$SYSTEM_PYTHON" "default")
if echo "$RESULT" | grep -q "^OK"; then
    ok "TLS works with LibreSSL — $RESULT"
else
    fail "TLS with LibreSSL — $RESULT"
fi

# ── Test 3: user Python (OpenSSL 3.6.x) — TLS 1.3 (default) ─────────

if [ "$USER_PYTHON" != "$SYSTEM_PYTHON" ] && [ -n "$USER_PYTHON" ]; then
    header "Test 3: user Python (OpenSSL 3.6.x) — TLS 1.3 default"
    SSL_VER=$($USER_PYTHON -c "import ssl; print(ssl.OPENSSL_VERSION)" 2>/dev/null)
    echo "  Binary:  $USER_PYTHON"
    echo "  SSL:     $SSL_VER"

    RESULT=$(py_test_tls "$USER_PYTHON" "default")
    if echo "$RESULT" | grep -q "^OK"; then
        ok "TLS 1.3 works (bug not reproduced) — $RESULT"
    else
        fail "TLS 1.3 rejected by server — $RESULT"
    fi

# ── Test 4: user Python (OpenSSL 3.6.x) — TLS 1.2 forced ────────────

    header "Test 4: user Python (OpenSSL 3.6.x) — TLS 1.2 forced"
    echo "  Binary:  $USER_PYTHON"
    echo "  SSL:     $SSL_VER"

    RESULT=$(py_test_tls "$USER_PYTHON" "TLSv1_2")
    if echo "$RESULT" | grep -q "^OK"; then
        ok "TLS 1.2 works with same OpenSSL 3.6.x — $RESULT"
    else
        fail "TLS 1.2 also fails — $RESULT"
    fi
else
    header "Test 3/4: skipped (no separate user Python found)"
fi

# ── Test 5: user Python (OpenSSL 3.6.x) — TLS 1.3 with SNI ──────────

if [ "$USER_PYTHON" != "$SYSTEM_PYTHON" ] && [ -n "$USER_PYTHON" ]; then
    header "Test 5: user Python (OpenSSL 3.6.x) — TLS 1.3 with proper SNI"
    echo "  Binary:  $USER_PYTHON"
    echo "  SSL:     $SSL_VER"
    echo "  Note:    connects by hostname (sends SNI), skips cert verify"

    RESULT=$($USER_PYTHON -c "
import ssl, socket

host = '$HOST'
ip = '$REAL_IP'
port = 443

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

sock = socket.create_connection((ip, port), timeout=10)
ssock = ctx.wrap_socket(sock, server_hostname=host)
ssock.sendall(b'GET /discovery/v1/endpoints HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' % host.encode())
data = b''
while True:
    chunk = ssock.recv(4096)
    if not chunk:
        break
    data += chunk
ssock.close()

if b'200' in data.split(b'\r\n')[0]:
    print('OK 200')
else:
    print('FAIL %s' % data.split(b'\r\n')[0].decode())
" 2>&1)

    if echo "$RESULT" | grep -q "^OK"; then
        ok "TLS 1.3 with SNI works — $RESULT"
    else
        fail "TLS 1.3 with SNI rejected — $RESULT"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────

header "Summary"
echo "  If tests 1+2 pass but test 3 or 5 fails and test 4 passes, this"
echo "  confirms the TLS 1.3 incompatibility between OpenSSL 3.6.x and the"
echo "  GCP frontend at internal.cloud.remarkable.com."
echo ""
echo "  NOTE: The issue may be intermittent. It was consistently reproduced"
echo "  on 2026-04-03 for several hours, then stopped reproducing ~8h later."
echo "  The server (GCP load balancer) may rotate configurations. If all"
echo "  tests pass, the server is currently in a compatible state."
echo ""
echo "  The reMarkable desktop app bundles OpenSSL 3.6.0 (vs 3.6.1 tested"
echo "  here) which may behave differently. The app's specific build options"
echo "  (compiled on a CI runner) may produce a different TLS ClientHello."
