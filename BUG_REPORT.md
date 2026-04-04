# Bug Report: reMarkable Desktop App 3.26.0 — TLS 1.3 Connection Failure

## Summary

reMarkable desktop app v3.26.0 (build 1351) on macOS cannot connect to
`internal.cloud.remarkable.com` due to a TLS 1.3 handshake failure caused
by the bundled OpenSSL 3.6.0 library. The server (hosted on GCP at
35.201.126.131) resets the TCP connection during the TLS 1.3 handshake
initiated by OpenSSL 3.6.x clients.

## Affected Version

- **App**: reMarkable Desktop 3.26.0 (CFBundleVersion 1351)
- **Platform**: macOS 15.x (Darwin 25.4.0), Apple Silicon
- **Bundled OpenSSL**: 3.6.0 (`nssl-3.6.0-a2eab2a5bb`)
- **Bundled Qt**: 6.x with SecureTransport + OpenSSL TLS backends

## Symptoms

1. On launch, status bar shows: `Could not receive hostname: NetworkError`
2. Clicking "Pair the app" shows "Pairing your device. Please wait..." then
   fails with "Unable to connect to our servers — The connection to our
   servers is not secure."
3. No network connections are established (confirmed via `nettop`)

## Root Cause

The app makes an HTTPS GET request to:
```
https://internal.cloud.remarkable.com/discovery/v1/endpoints
```

This request fails at the TLS handshake stage. The server sends a TCP RST
during the TLS 1.3 ClientHello from OpenSSL 3.6.x.

### Evidence

**Qt HTTP backend** (default): `QNetworkReply error code 2`
(RemoteHostClosedError) — the Qt backend loads `libqopensslbackend.dylib`
which uses the bundled `libssl.3.dylib` (OpenSSL 3.6.0).

**Curl HTTP backend** (`ENABLE_CURL_HTTP_BACKEND=1`):
```
CURLE_SSL_CONNECT_ERROR(35): SSL connect error - Recv failure: Connection reset by peer
url=https://internal.cloud.remarkable.com/discovery/v1/endpoints
```

**Reproducing with Python 3.14 (OpenSSL 3.6.1)** — same failure:
```python
import urllib.request, ssl
ctx = ssl.create_default_context()
urllib.request.urlopen('https://internal.cloud.remarkable.com/discovery/v1/endpoints', context=ctx)
# → ConnectionResetError: [Errno 54] Connection reset by peer
```

**Forcing TLS 1.2 with Python** — works:
```python
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
ctx.load_default_certs()
urllib.request.urlopen('https://internal.cloud.remarkable.com/discovery/v1/endpoints', context=ctx)
# → 200 OK, returns valid JSON
```

**System curl (LibreSSL/SecureTransport)** — works:
```
$ /usr/bin/curl https://internal.cloud.remarkable.com/discovery/v1/endpoints
{
    "notifications" : "eu.tectonic.remarkable.com",
    "webapp" : "webapp-prod.cloud.remarkable.engineering",
    "mqttbroker" : "vernemq-prod.cloud.remarkable.engineering"
}
```

**openssl s_client** — works (both system and bundled OpenSSL via
DYLD_LIBRARY_PATH can complete the handshake when used standalone).

### Conclusion

OpenSSL 3.6.x's TLS 1.3 ClientHello is rejected by the GCP load balancer
fronting `internal.cloud.remarkable.com`. This is likely due to a new TLS
extension or post-quantum key exchange added in OpenSSL 3.6 that the GCP
frontend does not support. The connection is RST'd before the handshake
completes.

The Qt HTTP backend is doubly affected because it preferentially loads
`libqopensslbackend.dylib` (which uses the same broken OpenSSL 3.6.0)
over the `libqsecuretransportbackend.dylib` (which uses macOS native TLS
and would work correctly).

## Additional Issues Found

1. **`UseCurlHttpBackend` defaults setting is ignored**: Writing to
   `NSUserDefaults` (`defaults write com.remarkable.desktop
   UseCurlHttpBackend -bool true`) has no effect. The app reads from an
   internal config source. Only the environment variable
   `ENABLE_CURL_HTTP_BACKEND=1` works.

2. **No bundled CA certificates**: The curl backend has no bundled CA
   certificate file. It relies on the system's `/etc/ssl/cert.pem` for
   certificate verification but does not read `SSL_CERT_FILE` or
   `CURL_CA_BUNDLE` environment variables.

3. **Qt TLS backend selection**: The app loads all three Qt TLS plugins
   (SecureTransport, OpenSSL, CertOnly) but appears to select the OpenSSL
   backend by default. There is no way to force SecureTransport selection
   via environment variables.

## Intermittency Note

The TLS 1.3 connection reset was consistently reproducible for ~8 hours on
2026-04-03 (18:00–02:00 CEST), then stopped reproducing around 2026-04-04
10:00 CEST. At that point:

- The app's bundled curl backend (OpenSSL 3.6.0) could connect directly
- Python with OpenSSL 3.6.1 could also connect
- The server IP remained 35.201.126.131

This suggests the GCP load balancer frontend was rotated or reconfigured.
The issue may recur when the same frontend configuration is deployed again.

The proof scripts in `prove_tls_bug.sh` and `prove_tls_bug.py` can be
re-run to check if the issue is currently active.

## Suggested Fixes

1. **Immediate**: Pin TLS to 1.2 for the discovery endpoint, or configure
   curl/Qt to use TLS 1.2 maximum when connecting to
   `internal.cloud.remarkable.com`.

2. **Short-term**: Force the Qt TLS backend to use SecureTransport
   (`libqsecuretransportbackend.dylib`) on macOS instead of the bundled
   OpenSSL. SecureTransport handles TLS 1.3 correctly with GCP.

3. **Long-term**: Update the GCP load balancer configuration to accept
   OpenSSL 3.6.x TLS 1.3 ClientHello, or downgrade the bundled OpenSSL
   to a version (e.g., 3.0.x or 3.3.x) that produces compatible TLS 1.3
   handshakes.

4. **Also**: Respect `CURL_CA_BUNDLE` / `SSL_CERT_FILE` environment
   variables and/or bundle a CA certificate file with the app for the curl
   backend.

## Workaround

A local TLS reverse proxy using system Python (LibreSSL) can bridge the
gap. See `start-remarkable.sh` in this repository for the full workaround
including setup instructions.
