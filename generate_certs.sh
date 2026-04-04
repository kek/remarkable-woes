#!/bin/sh
# Generate a self-signed TLS cert/key pair for rm_tls_proxy.py.
# The cert's CN must match the hostname the reMarkable connects to
# (internal.cloud.remarkable.com), and the proxy presents it to the device.
# The device only trusts it because we install ca-bundle.pem on the host
# and override DNS in /etc/hosts so this proxy answers for that hostname.

set -eu

cd "$(dirname "$0")"

if [ -f rm_key.pem ] || [ -f rm_cert.pem ]; then
	echo "rm_cert.pem / rm_key.pem already exist. Remove them first if you want to regenerate." >&2
	exit 1
fi

openssl req -x509 -newkey rsa:2048 -nodes \
	-keyout rm_key.pem -out rm_cert.pem \
	-days 365 \
	-subj "/CN=internal.cloud.remarkable.com" \
	-addext "subjectAltName=DNS:internal.cloud.remarkable.com"

chmod 600 rm_key.pem
echo "Generated rm_cert.pem and rm_key.pem (valid 365 days)."
