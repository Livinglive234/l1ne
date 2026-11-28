#!/bin/bash
# Runs the ZRTP engine against Linphone's bzrtp in memory (first-call handshakes, some with lost packets) and checks that both sides end with the
# same SRTP keys and verification code, then switches the call to unencrypted (GoClear) from each side in turn. bzrtp only has GoClear when built with GOCLEAR_ENABLED, which this script does. bzrtp is GPLv3 and is only fetched into a temporary folder and linked into this test, never into the apps.
# Needs: git, a C/C++ compiler, cmake (pip install cmake), OpenSSL (Homebrew). usage: tests/zrtp/run-interop.sh [rounds]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; W="$(mktemp -d)"; O="${OPENSSL:-$(brew --prefix openssl)}"; cd "$W"
git clone -q --depth 1 https://github.com/BelledonneCommunications/bzrtp.git; git clone -q --depth 1 https://github.com/BelledonneCommunications/bctoolbox.git
mkdir bb && (cd bb && cmake ../bctoolbox -DENABLE_MBEDTLS=OFF -DENABLE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$O" -DENABLE_TESTS_COMPONENT=OFF -DENABLE_UNIT_TESTS=OFF -DENABLE_STRICT=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release >/dev/null && make -j8 >/dev/null)
F=bb/src/bctoolbox.framework/Versions/A; mkdir out
INC=(-Ibzrtp/include -Ibzrtp/src -Ibctoolbox/include -Ibb/include -I$F/Headers -I"$O/include")
for f in bzrtp packetParser pgpwords stateMachine zidCache; do clang -c -O1 -w -DGOCLEAR_ENABLED "${INC[@]}" bzrtp/src/$f.c -o out/$f.o; done
clang++ -c -O1 -w -std=c++17 -DGOCLEAR_ENABLED "${INC[@]}" bzrtp/src/cryptoUtils.cc -o out/cryptoUtils.o
clang -O1 -w -DGOCLEAR_ENABLED -I"$ROOT/native/zrtp" "${INC[@]}" "$ROOT/tests/zrtp/interop_bzrtp.c" "$ROOT/native/zrtp/zrtp.c" out/*.o $F/bctoolbox -L"$O/lib" -lssl -lcrypto -lc++ -o interop
./interop "${1:-12}"
