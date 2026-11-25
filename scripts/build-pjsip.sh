#!/bin/bash
# Builds pjproject (vendor/pjproject) for iOS device + simulator (arm64) and packs it into
# vendor/PJSIP.xcframework. TLS uses Apple's own backend (no OpenSSL to cross-build);
# SRTP uses pjproject's bundled libsrtp (SDES, what Asterisk/FreePBX offers).
# Usage: scripts/build-pjsip.sh            (re-run safely; each slice builds in vendor/build/<slice>)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/pjproject"
OUT="$ROOT/vendor/build"
MIN_IOS=15.0
JOBS=$(sysctl -n hw.ncpu)

[ -d "$SRC" ] || { echo "missing $SRC (run scripts/fetch-deps.sh)"; exit 1; }

# L1ne's patches to pjproject (see scripts/patches). Safe to run again: an applied patch is skipped.
for p in "$ROOT"/scripts/patches/*.patch; do
  [ -f "$p" ] || continue
  if git -C "$SRC" apply --check "$p" 2>/dev/null; then git -C "$SRC" apply "$p"; echo "applied $(basename "$p")"
  elif git -C "$SRC" apply --check -R "$p" 2>/dev/null; then echo "already applied: $(basename "$p")"
  else echo "patch does not apply cleanly: $p"; exit 1; fi
done

build_slice() {
  local name="$1" platform="$2" minflag="$3"
  local dir="$OUT/$name"
  local dev; dev="$(xcode-select -p)/Platforms/${platform}.platform/Developer"
  local sdk; sdk="$(xcrun --sdk "$( [ "$platform" = iPhoneOS ] && echo iphoneos || echo iphonesimulator )" --show-sdk-path)"

  echo "==> $name: copying source"
  rm -rf "$dir"; mkdir -p "$dir"
  rsync -a --exclude .git "$SRC/" "$dir/src/"

  cat > "$dir/src/pjlib/include/pj/config_site.h" <<'EOF'
#define PJ_CONFIG_IPHONE 1
#include <pj/config_site_sample.h>
/* audio only */
#define PJMEDIA_HAS_VIDEO 0
/* CallKit owns the audio session; pjsua must not grab it itself */
#define PJMEDIA_AUDIO_DEV_HAS_COREAUDIO 1
/* TLS and DTLS-SRTP through OpenSSL (vendor/openssl, built by build-openssl.sh) */
#define PJMEDIA_SRTP_HAS_DTLS 1
/* IPv6 (needed for IPv6-only / NAT64 networks, and for the Allow IPv6 setting) */
#define PJ_HAS_IPV6 1
#define PJSUA_MAX_CALLS 4
#define PJSUA_MAX_ACC 8
EOF

  echo "==> $name: configure"
  ( cd "$dir/src"
    DEVPATH="$dev" IPHONESDK="$sdk" ARCH="-arch arm64" MIN_IOS="$minflag=$MIN_IOS" \
      ./configure-iphone --disable-video --disable-opencore-amr --disable-silk --disable-bcg729 \
        --disable-libyuv --disable-libwebrtc --disable-opus --disable-darwin-ssl \
        --with-ssl="$ROOT/vendor/openssl/$name" >"$dir/configure.log" 2>&1 \
      || { tail -30 "$dir/configure.log"; exit 1; }
    echo "==> $name: make"
    make dep >"$dir/dep.log" 2>&1
    make -j"$JOBS" lib >"$dir/make.log" 2>&1 || { tail -40 "$dir/make.log"; exit 1; }
  )

  echo "==> $name: merging libraries"
  local libs=( "$dir"/src/*/lib/*.a "$dir"/src/third_party/lib/*.a "$ROOT/vendor/openssl/$name/lib/libssl.a" "$ROOT/vendor/openssl/$name/lib/libcrypto.a" )
  libtool -static -o "$dir/libpjsip.a" "${libs[@]}" 2>/dev/null
}

if [ -z "${HEADERS_ONLY:-}" ]; then   # HEADERS_ONLY=1 repackages without recompiling
  build_slice ios-arm64 iPhoneOS -miphoneos-version-min
  build_slice ios-arm64-simulator iPhoneSimulator -mios-simulator-version-min
fi

echo "==> headers"
H="$OUT/Headers"; rm -rf "$H"; mkdir -p "$H"
for d in pjlib pjlib-util pjnath pjmedia pjsip; do cp -R "$OUT/ios-arm64/src/$d/include/." "$H/"; done
# the sample config_site.h is per-slice; headers need a neutral one
cp "$OUT/ios-arm64/src/pjlib/include/pj/config_site.h" "$H/pj/config_site.h"
# configure-generated platform header (endianness etc.), identical for both arm64 slices
cp "$OUT/ios-arm64/src/pjlib/include/pj/compat/os_auto.h" "$H/pj/compat/os_auto.h"
# the library is built with -DPJ_AUTOCONF=1; the Swift module must see the same
sed -i '' '1i\
#ifndef PJ_AUTOCONF\
#define PJ_AUTOCONF 1\
#endif
' "$H/pj/config_site.h"
cat > "$H/module.modulemap" <<'EOF'
module CPJSIP {
  header "pjsua-lib/pjsua.h"
  export *
}
EOF

echo "==> xcframework"
rm -rf "$ROOT/vendor/PJSIP.xcframework"
xcodebuild -create-xcframework \
  -library "$OUT/ios-arm64/libpjsip.a" -headers "$H" \
  -library "$OUT/ios-arm64-simulator/libpjsip.a" -headers "$H" \
  -output "$ROOT/vendor/PJSIP.xcframework"
echo "done: vendor/PJSIP.xcframework"
