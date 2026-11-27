#!/bin/bash
# Compiles and runs the ZRTP engine tests (in memory, no network) and the SRTP tests, which also compare byte for byte with libsrtp
# (the copy inside vendor/pjproject, when it is there). Needs OpenSSL 3 or newer: set OPENSSL=<prefix> if it is not Homebrew's.
# usage: tests/zrtp/run.sh        (CI runs the same script)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
O="${OPENSSL:-$(brew --prefix openssl 2>/dev/null || echo /usr)}"
OUT="$(mktemp -d)"
CFLAGS=(-std=gnu11 -Wall -Wextra -Werror -I"$O/include")
cc "${CFLAGS[@]}" native/zrtp/zrtp.c tests/zrtp/test_zrtp.c -L"$O/lib" -lcrypto -o "$OUT/zrtp" && "$OUT/zrtp"
S=vendor/pjproject/third_party/srtp
if [ -d "$S/srtp" ]; then
  mkdir -p "$OUT/cfg"
  cat > "$OUT/cfg/config.h" <<'EOF'
#define CPU_CISC 1
#define HAVE_ARPA_INET_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STDINT_H 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1
#define HAVE_UINT8_T 1
#define PACKAGE_STRING "libsrtp"
#define PACKAGE_VERSION "2.6.0"
EOF
  cat > "$OUT/err.c" <<'EOF'
#include "srtp.h"
#include "err.h"
void srtp_err_report(srtp_err_reporting_level_t p, const char *f, ...) { (void)p; (void)f; }
void srtp_err_reporting_set_level(srtp_err_reporting_level_t l) { (void)l; }
srtp_err_status_t srtp_err_reporting_init(void) { return srtp_err_status_ok; }
srtp_err_status_t srtp_install_err_report_handler(srtp_err_report_handler_func_t *h) { (void)h; return srtp_err_status_ok; }
EOF
  SRCS=("$S/srtp/srtp.c" "$S"/crypto/cipher/{aes,aes_icm,cipher,cipher_test_cases,null_cipher}.c "$S"/crypto/hash/{auth,auth_test_cases,hmac,null_auth,sha1}.c "$S"/crypto/kernel/{alloc,crypto_kernel,key}.c "$S/crypto/math/datatypes.c" "$S"/crypto/replay/{rdb,rdbx}.c)
  cc -std=gnu11 -w -DWITH_LIBSRTP -DHAVE_CONFIG_H -I"$OUT/cfg" -I"$S/include" -I"$S/crypto/include" "${SRCS[@]}" "$OUT/err.c" -I"$O/include" native/zrtp/l1srtp.c tests/zrtp/test_srtp.c -L"$O/lib" -lcrypto -o "$OUT/srtp"
else
  cc "${CFLAGS[@]}" native/zrtp/l1srtp.c tests/zrtp/test_srtp.c -L"$O/lib" -lcrypto -o "$OUT/srtp"
fi
"$OUT/srtp"
