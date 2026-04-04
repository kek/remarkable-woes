#!/bin/bash
#
# Launches the reMarkable desktop app with the TLS proxy workaround.
#
# Prerequisites (one-time setup):
#   1. /etc/hosts must contain: 127.0.0.1 internal.cloud.remarkable.com
#   2. Self-signed cert must be appended to /etc/ssl/cert.pem
#   3. pf redirect must be active (this script sets it up)
#
# See ROLLBACK.md for how to undo all of this.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_SCRIPT="$SCRIPT_DIR/rm_tls_proxy.py"
CERT_FILE="$SCRIPT_DIR/rm_cert.pem"

# --- Preflight checks ---

if ! grep -q 'internal.cloud.remarkable.com' /etc/hosts 2>/dev/null; then
    echo "ERROR: /etc/hosts missing redirect. Run:"
    echo "  echo '127.0.0.1 internal.cloud.remarkable.com' | sudo tee -a /etc/hosts"
    exit 1
fi

if ! grep -q 'internal.cloud.remarkable.com' /etc/ssl/cert.pem 2>/dev/null; then
    echo "ERROR: Self-signed cert not in /etc/ssl/cert.pem. Run:"
    echo "  sudo sh -c 'cat $CERT_FILE >> /etc/ssl/cert.pem'"
    exit 1
fi

# --- Set up pf redirect (443 -> 18443 on loopback) ---

echo "Setting up pf port redirect (requires sudo)..."
echo "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port 18443" \
    | sudo pfctl -ef - 2>/dev/null || true

# --- Start proxy if not already running ---

if ! pgrep -f "rm_tls_proxy.py" >/dev/null 2>&1; then
    echo "Starting TLS proxy..."
    /usr/bin/python3 "$PROXY_SCRIPT" > "$SCRIPT_DIR/proxy.log" 2>&1 &
    PROXY_PID=$!
    echo "Proxy started (PID $PROXY_PID), log: $SCRIPT_DIR/proxy.log"
    sleep 1

    # Verify proxy is running
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "ERROR: Proxy failed to start. Check $SCRIPT_DIR/proxy.log"
        exit 1
    fi
else
    echo "Proxy already running."
fi

# --- Launch the app ---

echo "Launching reMarkable..."
ENABLE_CURL_HTTP_BACKEND=1 /Applications/reMarkable.app/Contents/MacOS/reMarkable &
APP_PID=$!

echo "reMarkable running (PID $APP_PID)"
echo ""
echo "Press Ctrl+C to stop both the app and proxy."

# Wait for app to exit, then clean up proxy
wait "$APP_PID" 2>/dev/null
echo "reMarkable exited. Stopping proxy..."
pkill -f "rm_tls_proxy.py" 2>/dev/null || true
