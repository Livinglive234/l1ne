**Debug-signed builds for sideloading and testing.**

- **Android (`.apk`)**: signed with a throwaway debug key, so you can install it directly (allow installs from this source), but you cannot update an older install of it, and it is not meant for Google Play. Needs Android 8.0 or later; one file for 64-bit and 32-bit ARM phones.
- **iPhone (`.ipa`)**: **unsigned**. It will not install as it is. Sign it with your own Apple ID using a sideloading tool, or build from source (see the README).

**Source (GPL).** A built L1ne contains PJSIP (GPL-2.0-or-later). The complete corresponding source for these files is this repository at the release tag, plus pjproject 2.17 and OpenSSL 3.5.9, which `scripts/fetch-deps.sh` downloads (pinned and checksum-verified), and the patch in `scripts/patches/`. See LICENSING.md.
