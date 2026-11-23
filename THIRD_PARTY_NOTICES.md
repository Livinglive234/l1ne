# Third-party notices

L1ne's own code is MIT licensed (see [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md)). A built L1ne contains the components below, each under
its own license. License texts live with each component's source (`vendor/` after `scripts/fetch-deps.sh`, or the project's repository).

## PJSIP / pjproject 2.17 (SIP, media, SRTP, DTLS-SRTP)
- Copyright Teluu Inc. and Benny Prijono. Licensed **GPL-2.0-or-later**; a commercial license is available from Teluu.
- https://github.com/pjsip/pjproject, license overview: https://docs.pjsip.org/en/latest/overview/license.html
- L1ne applies a patch (`scripts/patches/pjsip-tls-wildcard.patch`) that lets PJSIP accept TLS wildcard certificates. The patch is a modification of
  PJSIP and is distributed under PJSIP's license.
- pjproject bundles other libraries in `third_party/` (for example libsrtp, Speex, GSM, iLBC, G.722.1, libresample, WebRTC audio code). Each keeps its
  own license file inside `third_party/<name>/`. L1ne builds the audio-only subset and no video codecs.

## OpenSSL 3.5.x (TLS, DTLS-SRTP)
- Copyright The OpenSSL Project Authors. Licensed **Apache-2.0**. https://github.com/openssl/openssl
- Built from the official release tarball, checksum verified by `scripts/fetch-deps.sh`.

## Mozilla CA certificate bundle (`L1ne/Resources/cacert.pem`)
- Extracted from Mozilla's root store and published by the curl project (https://curl.se/docs/caextract.html). Derived from Mozilla's root store, which Mozilla and curl publish under the **Mozilla Public
  License 2.0** (check their pages for the current terms); it is data, not code, and is used so TLS server certificates can be verified.

## Android build (when built)
- Kotlin, AndroidX, Jetpack Compose and Material: **Apache-2.0**. PJSIP and OpenSSL apply on Android exactly as above.

## Test tooling (not shipped)
- OpenLDAP (OpenLDAP Public License), Radicale (GPL-3.0), Python and OpenSSL command-line tools are used only by the tests and are not part of L1ne.
