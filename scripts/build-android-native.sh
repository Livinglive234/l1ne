#!/bin/bash
# Builds OpenSSL and pjproject (static, arm64-v8a) for Android into vendor/android/, using the NDK from android/local.properties.
# Same feature set as the iOS build: audio only, OpenSSL for TLS and DTLS-SRTP, bundled libsrtp for SDES.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK=$(sed -n 's/^sdk.dir=//p' "$ROOT/android/local.properties")
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$(ls -d "$SDK"/ndk/* | tail -1)}"
OUT="$ROOT/vendor/android"; JOBS=$(sysctl -n hw.ncpu)
API=26
TC="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64"
mkdir -p "$OUT"

# OpenSSL
if [ ! -f "$OUT/openssl/lib/libssl.a" ]; then
  W="$ROOT/vendor/build/openssl-android"; rm -rf "$W"; mkdir -p "$W"; rsync -a "$ROOT/vendor/openssl-dl/openssl-3.5.9/" "$W/"
  ( cd "$W"; export PATH="$TC/bin:$PATH"
    ./Configure android-arm64 -D__ANDROID_API__=$API no-shared no-tests no-apps no-docs no-dso no-engine no-comp no-ssl3 no-weak-ssl-ciphers \
      --prefix="$OUT/openssl" --openssldir="$OUT/openssl/ssl" >configure.log 2>&1 || { tail -20 configure.log; exit 1; }
    make -j"$JOBS" build_libs >make.log 2>&1 || { tail -30 make.log; exit 1; }
    make install_dev >install.log 2>&1 )
fi
echo "openssl: $(ls "$OUT/openssl/lib"/*.a | xargs -n1 basename | tr '\n' ' ')"

# pjproject
SRC="$ROOT/vendor/pjproject"
for p in "$ROOT"/scripts/patches/*.patch; do
  [ -f "$p" ] || continue
  if git -C "$SRC" apply --check "$p" 2>/dev/null; then git -C "$SRC" apply "$p"; echo "applied $(basename "$p")"; fi
done
W="$ROOT/vendor/build/pjsip-android"; rm -rf "$W"; mkdir -p "$W"; rsync -a --exclude .git "$SRC/" "$W/src/"
# pjproject's OpenSL file calls opensl_to_pj_error before declaring it; current clang refuses that
sed -i '' 's|^#define THIS_FILE       "opensl_dev.c"|&\npj_status_t opensl_to_pj_error(SLresult code);|' "$W/src/pjmedia/src/pjmedia-audiodev/opensl_dev.c"
cat > "$W/src/pjlib/include/pj/config_site.h" <<'EOT'
#define PJ_CONFIG_ANDROID 1
#include <pj/config_site_sample.h>
/* OpenSL ES for audio (no Java classes needed) instead of the sample's JNI backend */
#undef PJMEDIA_AUDIO_DEV_HAS_OPENSL
#undef PJMEDIA_AUDIO_DEV_HAS_ANDROID_JNI
#define PJMEDIA_AUDIO_DEV_HAS_OPENSL 1
#define PJMEDIA_AUDIO_DEV_HAS_ANDROID_JNI 0
#define PJMEDIA_HAS_VIDEO 0
#define PJMEDIA_SRTP_HAS_DTLS 1
#define PJ_HAS_IPV6 1
#define PJSUA_MAX_CALLS 4
#define PJSUA_MAX_ACC 8
EOT
( cd "$W/src"
  APP_PLATFORM=android-$API TARGET_ABI=arm64-v8a ./configure-android --disable-video --disable-opencore-amr --disable-silk --disable-bcg729 \
    --disable-libyuv --disable-libwebrtc --disable-opus --with-ssl="$OUT/openssl" >"$W/configure.log" 2>&1 || { tail -30 "$W/configure.log"; exit 1; }
  make dep >"$W/dep.log" 2>&1
  make -j"$JOBS" lib >"$W/make.log" 2>&1 || { tail -40 "$W/make.log"; exit 1; } )
mkdir -p "$OUT/pjsip/lib" "$OUT/pjsip/include"
cp "$W"/src/*/lib/*.a "$W"/src/third_party/lib/*.a "$OUT/pjsip/lib/" 2>/dev/null || true
for d in pjlib pjlib-util pjnath pjmedia pjsip; do rsync -a "$W/src/$d/include/" "$OUT/pjsip/include/"; done
echo "pjsip libs: $(ls "$OUT/pjsip/lib" | tr '\n' ' ')"
