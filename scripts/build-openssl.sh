#!/bin/bash
# Builds OpenSSL (static) for iOS device + Apple-silicon simulator into vendor/openssl/<slice>/.
# Needed because PJSIP's DTLS-SRTP code uses OpenSSL directly; also used for SIP TLS (see build-pjsip.sh).
# Source: vendor/openssl-dl/openssl-3.5.9 (official release tarball, SHA-256 checked when downloaded).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/openssl-dl/openssl-3.5.9"
OUT="$ROOT/vendor/openssl"
JOBS=$(sysctl -n hw.ncpu)
[ -d "$SRC" ] || { echo "missing $SRC"; exit 1; }

build() {
  local name="$1" target="$2" minflag="$3"
  local work="$ROOT/vendor/build/openssl-$name"
  rm -rf "$work" "$OUT/$name"; mkdir -p "$work" "$OUT/$name"
  rsync -a "$SRC/" "$work/"
  ( cd "$work"
    export CROSS_TOP="" CROSS_SDK=""
    ./Configure "$target" no-shared no-tests no-apps no-docs no-dso no-engine no-comp no-ssl3 no-weak-ssl-ciphers \
        "$minflag=15.0" --prefix="$OUT/$name" --openssldir="$OUT/$name/ssl" >configure.log 2>&1 || { tail -20 configure.log; exit 1; }
    make -j"$JOBS" build_libs >make.log 2>&1 || { tail -30 make.log; exit 1; }
    make install_dev >install.log 2>&1 || { tail -20 install.log; exit 1; }
  )
  echo "built openssl $name: $(ls "$OUT/$name/lib"/*.a | xargs -n1 basename | tr '\n' ' ')"
}

build ios-arm64            ios64-xcrun              -miphoneos-version-min
build ios-arm64-simulator  iossimulator-arm64-xcrun -mios-simulator-version-min
echo done
