**Builds for sideloading and testing.**

- **Android (`.apk`)**: signed with the project's release key, so each new release installs **over the previous one** and keeps your accounts and data. One file for 64-bit and 32-bit ARM phones; needs Android 8.0 or later. If you installed an earlier *debug* build, uninstall it once first: Android will not replace an app signed with a different key.
- **iPhone (`.ipa`)**: **unsigned**. It will not install as it is. Sign it with your own Apple ID using a sideloading tool, or build from source (see the README).

**Source (GPL).** A built L1ne contains PJSIP (GPL-2.0-or-later). The complete corresponding source for these files is this repository at the release tag, plus pjproject 2.17 and OpenSSL 3.5.9, which `scripts/fetch-deps.sh` downloads (pinned and checksum-verified), and the patch in `scripts/patches/`. See LICENSING.md.
