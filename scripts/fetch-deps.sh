#!/bin/bash
# Downloads the third-party sources L1ne is built on into vendor/ (not stored in this repo):
#   - pjproject 2.17 (SIP stack)      https://github.com/pjsip/pjproject
#   - OpenSSL 3.5.9 (TLS, DTLS-SRTP)  https://github.com/openssl/openssl  (SHA-256 checked)
# Then build them with scripts/build-openssl.sh and scripts/build-pjsip.sh (iOS, macOS only) or scripts/build-android-native.sh (macOS, Linux, Windows).
# Needs git, curl and tar; runs on macOS, Linux and Windows (Git Bash).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor/openssl-dl
if [ ! -d vendor/pjproject ]; then
  git clone --depth 1 --branch 2.17 https://github.com/pjsip/pjproject.git vendor/pjproject
fi
OSSL=openssl-3.5.9
SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
if [ ! -d "vendor/openssl-dl/$OSSL" ]; then
  curl -sSL -o "vendor/openssl-dl/$OSSL.tar.gz" "https://github.com/openssl/openssl/releases/download/$OSSL/$OSSL.tar.gz"
  . "$(dirname "$0")/lib.sh"; check_sha256 "$SHA" "vendor/openssl-dl/$OSSL.tar.gz"
  tar xzf "vendor/openssl-dl/$OSSL.tar.gz" -C vendor/openssl-dl
fi
echo "done. Next: scripts/build-openssl.sh && scripts/build-pjsip.sh"
