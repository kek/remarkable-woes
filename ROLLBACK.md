# Rollback Steps

Undo all configuration changes made to work around the reMarkable TLS bug.

## 1. Remove /etc/hosts entry

```bash
sudo sed -i '' '/internal.cloud.remarkable.com/d' /etc/hosts
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

## 2. Remove self-signed cert from /etc/ssl/cert.pem

The cert block starts with a comment-less `-----BEGIN CERTIFICATE-----`
at the very end of the file. Remove the last certificate block:

```bash
# Find line number where our cert starts (last BEGIN CERTIFICATE in the file)
LINE=$(grep -n 'BEGIN CERTIFICATE' /etc/ssl/cert.pem | tail -1 | cut -d: -f1)
# Preview what will be removed
sudo tail -n +$LINE /etc/ssl/cert.pem
# Remove it
sudo sed -i '' "${LINE},\$d" /etc/ssl/cert.pem
```

## 3. Remove self-signed cert from system keychain

```bash
sudo security delete-certificate -c "internal.cloud.remarkable.com" /Library/Keychains/System.keychain
```

## 4. Disable pf redirect

```bash
sudo pfctl -F rules
sudo pfctl -d
```

Note: if you have other pf rules in /etc/pf.conf, reload them instead:
```bash
sudo pfctl -f /etc/pf.conf
```

## 5. Remove Defender exclusions

```bash
mdatp exclusion folder remove --path "/Applications/reMarkable.app"
mdatp exclusion process remove --name "reMarkable"
```

## 6. Clean up launchctl env vars

```bash
launchctl unsetenv ENABLE_CURL_HTTP_BACKEND
launchctl unsetenv SSL_CERT_FILE
```

## 7. Reset reMarkable defaults

```bash
defaults delete com.remarkable.desktop UseCurlHttpBackend 2>/dev/null
defaults delete com.remarkable.desktop ServiceEnvironment 2>/dev/null
```

## 8. Stop the proxy

```bash
pkill -f rm_tls_proxy.py
```
