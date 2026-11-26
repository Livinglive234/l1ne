# Releasing

A release is a pushed version tag. GitHub Actions does the rest.

| Tag | What CI makes |
|---|---|
| `v0.1.0-beta.3` | a **published pre-release**, "L1ne 0.1.0 beta 3", with the signed Android APKs and the unsigned iPhone IPA |
| `v0.1.0-rc2` (or any suffix) | the same, titled "L1ne 0.1.0 release candidate 2" |
| `v0.1.0` | a **draft** "L1ne 0.1.0": nothing is public until you open it on GitHub and press Publish |

Cut the next beta with `scripts/tag-beta.sh` (it works out the number, checks that you are on a pushed `main`, tags it and pushes the tag; `--dry-run` only prints it).
The release text comes from `.github/release-notes.md`; pre-releases get a line on top saying so. `scripts/make-release.sh` is the one place that decides names and flags, and both workflows call it.

## Why a newer build installs over an older one (Android)
Android only updates an app when the new APK is **signed by the same key** and has a **higher `versionCode`**.
- **Same key:** release builds are signed with the project's release key, kept in the repository's secrets (`L1NE_KEYSTORE_BASE64` and friends), never in the repository. The key's SHA-256 fingerprint is pinned in `.github/release-cert.sha256` and the build **stops** if an APK is signed by anything else.
  Back up the key (`~/L1ne-release-key/`): if it is lost, nobody can update from an older build, and a new key means everyone uninstalls once.
- **Higher number:** CI uses the workflow's run number as `versionCode`, which only ever goes up. The visible version (`versionName`) is the tag without the `v`, such as `0.1.0-beta.3`.
- **Debug builds** (from a computer, or CI's ordinary builds) are signed with a different, throwaway key. Uninstall one once before installing a release.

## iPhone
The IPA is **unsigned**, so it cannot be installed as it is (there is no paid Apple Developer account yet). `MARKETING_VERSION` is the tag's version without the suffix and the build number is the run number.
