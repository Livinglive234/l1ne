#!/bin/bash
# Test CA and a server certificate for localhost (used only by tests/mock/mock_sip_tls.py)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
D="${1:?usage: gen-certs.sh <dir>}"; mkdir -p "$D"; cd "$D"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -keyout ca.key -out ca.pem -subj "/CN=L1ne Test CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=localhost" 2>/dev/null
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n" > ext.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -extfile ext.cnf -out server.pem 2>/dev/null
# a wildcard certificate (CN and SAN "*.test.localhost"), like the one many PBXes use
openssl req -newkey rsa:2048 -nodes -keyout wild.key -out wild.csr -subj "/CN=*.test.localhost" 2>/dev/null
printf "subjectAltName=DNS:*.test.localhost\nextendedKeyUsage=serverAuth\n" > wext.cnf
openssl x509 -req -in wild.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -extfile wext.cnf -out wild.pem 2>/dev/null
cat "$ROOT/ios/Resources/cacert.pem" ca.pem > bundle-with-test-ca.pem
echo "certs in $D"
