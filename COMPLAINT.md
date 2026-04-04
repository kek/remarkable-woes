# reMarkable Desktop App 3.26.0 — Unable to Connect on macOS

## The Problem

The reMarkable desktop app (v3.26.0, build 1351) on macOS is unable to
connect to reMarkable's cloud services. During the pairing/login process,
the app displays various error messages at different stages: "Could not
receive hostname: NetworkError" in the status bar, and "Unable to connect
to our servers — The connection to our servers is not secure. Please try
logging in again, or connect to a different Wi-Fi." after attempting to
pair.

This is a fresh install on macOS 15 (Apple Silicon). The network is fully
functional — every other application connects fine, and reMarkable's own
servers are reachable from the same machine using system tools.

After several hours of debugging, I identified the root cause and multiple
compounding issues in the app. I'm filing this so other users don't have
to reverse-engineer a shipping application to get it to work.

## Root Cause

The app bundles OpenSSL 3.6.0 (`nssl-3.6.0-a2eab2a5bb`), which produces
TLS 1.3 ClientHello messages that reMarkable's own GCP-hosted discovery
endpoint (`internal.cloud.remarkable.com`) intermittently rejects with a
TCP RST during the handshake.

Evidence:

- macOS system curl (LibreSSL/SecureTransport): **connects fine**
- macOS system Python (LibreSSL 2.8.3): **connects fine**
- Python with OpenSSL 3.6.1, TLS 1.3 default: **connection reset by peer**
- Python with OpenSSL 3.6.1, forced TLS 1.2: **connects fine**
- The app's own curl backend (OpenSSL 3.6.0): **connection reset by peer**
- The app's Qt HTTP backend (OpenSSL 3.6.0): **QNetworkReply error code 2**

Forcing TLS 1.2 from the same OpenSSL 3.6.x library works. The issue is
specifically OpenSSL 3.6.x's TLS 1.3 handshake versus your GCP frontend.

## Additional Issues Found During Debugging

While working around the TLS failure, I encountered a cascade of further
problems in the app:

### 1. Qt selects OpenSSL over SecureTransport with no override

The app bundles three Qt TLS plugins: `libqsecuretransportbackend.dylib`,
`libqopensslbackend.dylib`, and `libqcertonlybackend.dylib`. Qt selects
the OpenSSL backend because the bundled `libssl.3.dylib` is present.

macOS SecureTransport handles TLS 1.3 with your server correctly. If Qt
used it, the app would just work. There is no environment variable or
configuration option to force the backend selection.

### 2. The curl backend toggle is broken

The app has a `UseCurlHttpBackend` setting. Writing it via `defaults write
com.remarkable.desktop UseCurlHttpBackend -bool true` has no effect — the
app always reads `false from config`. The only way to activate it is via
an undocumented environment variable: `ENABLE_CURL_HTTP_BACKEND=1` (and
the value must be `1`, not `true`).

### 3. The curl backend has no CA certificate bundle

When the curl backend is activated, it has no bundled CA certificates. No
`.pem`, `.crt`, or `.cer` file ships with the app. The curl code sets the
CA path programmatically and ignores standard environment variables
(`SSL_CERT_FILE`, `CURL_CA_BUNDLE`). It appears to fall back to
`/etc/ssl/cert.pem` on macOS.

### 4. No useful error diagnostics

The Qt HTTP backend logs `QNetworkReply error code 2` — a generic
"RemoteHostClosedError" with no indication of what URL was accessed, what
the TLS error was, or what cert was rejected. The curl backend is slightly
better (`CURLE_SSL_CONNECT_ERROR(35): Connection reset by peer`) but still
requires launching from a terminal to see it. The user-facing error
messages ("NetworkError", "connection is not secure") give no actionable
information.

### 5. The discovery URL is named "internal"

The production discovery endpoint is `internal.cloud.remarkable.com`. This
naming is confusing for debugging — it looks like an internal/development
endpoint that shouldn't be accessed from consumer devices. The other
environment URLs (`dev.internal.cloud.remarkable.com`,
`qa.internal.cloud.remarkable.com`, `stage.internal.cloud.remarkable.com`)
reinforce this confusion.

### 6. ServiceEnvironment enum rejects its own values

Setting `ServiceEnvironment` in defaults to `production`, `Production`,
`Internal`, or numeric values all produce `Invalid enum value for
"Environment"`. Only `Staging` was accepted. The production environment
appears to be the default with no way to explicitly select it.

## Impact

The app was completely non-functional for approximately 8 hours. The
workaround required:

1. Reverse-engineering the binary to find the discovery URL
2. Identifying the TLS 1.3/OpenSSL 3.6 incompatibility
3. Discovering the `ENABLE_CURL_HTTP_BACKEND=1` env var
4. Setting up a local HTTPS reverse proxy (system Python with LibreSSL)
5. Generating a self-signed certificate and adding it to the system CA store
6. Configuring /etc/hosts and pf port forwarding
7. Running the app from a terminal with the env var set

No regular user could have done this.

## Suggested Fixes

1. **Use SecureTransport on macOS.** Either make Qt prefer the
   SecureTransport TLS backend, or remove the OpenSSL backend plugin from
   the macOS build. SecureTransport is the native macOS TLS implementation
   and handles your server correctly.

2. **Pin TLS 1.2 for the discovery endpoint** as an immediate workaround
   until the OpenSSL 3.6.x / GCP compatibility issue is resolved.

3. **Bundle a CA certificate file** with the app for the curl backend, or
   properly integrate with the macOS system keychain.

4. **Make `UseCurlHttpBackend` actually work** from NSUserDefaults, not
   just from an undocumented environment variable.

5. **Log actionable errors.** Include the URL, the TLS error code, and the
   certificate chain in error messages — at minimum to stderr, ideally to
   a user-accessible log file.

6. **Test on macOS with current system configurations.** This bug would
   have been caught by connecting from any machine with OpenSSL 3.6.x,
   which shipped in January 2026.

## Environment

- macOS 15.x (Darwin 25.4.0), Apple Silicon
- reMarkable Desktop 3.26.0 (CFBundleVersion 1351)
- Network: residential, no corporate proxy, no VPN active
- Microsoft Defender present (managed) but network protection disabled
- App bundled OpenSSL: 3.6.0
- System Python OpenSSL: 3.6.1 (same issue)
- System curl: LibreSSL 3.3.6 / SecureTransport (works)
