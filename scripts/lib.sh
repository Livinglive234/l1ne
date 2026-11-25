#!/bin/bash
# Shared helpers for the build scripts. Source it: `. "$(dirname "$0")/lib.sh"`.
# Works on macOS, Linux and Windows (Git Bash / MSYS2; WSL counts as Linux). iOS builds need macOS and Xcode, nothing else can run them.

case "$(uname -s)" in
  Darwin) L1NE_OS=mac;     NDK_HOST=darwin-x86_64;  JOBS=$(sysctl -n hw.ncpu) ;;
  Linux)  L1NE_OS=linux;   NDK_HOST=linux-x86_64;   JOBS=$(nproc) ;;
  MINGW*|MSYS*|CYGWIN*) L1NE_OS=windows; NDK_HOST=windows-x86_64; JOBS=${NUMBER_OF_PROCESSORS:-4} ;;
  *) echo "unsupported system: $(uname -s)"; exit 1 ;;
esac

# The Android NDK the native libraries are built with. Keep in step with `ndkVersion` in android/app/build.gradle.kts.
NDK_VERSION=29.0.14206865

need_mac() { [ "$L1NE_OS" = mac ] || { echo "$1 needs macOS and Xcode; this script cannot run on $L1NE_OS."; exit 1; }; }

# In-place sed that behaves the same on BSD (macOS) and GNU sed: sedi 'expression' file
sedi() { sed -i.bak -e "$1" "$2" && rm -f "$2.bak"; }

# Copy a directory tree without its .git folder (rsync is not on every machine): copy_tree from to
copy_tree() { mkdir -p "$2"; ( cd "$1" && tar --exclude=.git -cf - . ) | ( cd "$2" && tar xf - ); }

# Verify a SHA-256 checksum: check_sha256 <hash> <file>
check_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then echo "$1  $2" | sha256sum -c -; else echo "$1  $2" | shasum -a 256 -c -; fi
}

# Find the Android SDK: $ANDROID_HOME, $ANDROID_SDK_ROOT, or sdk.dir in android/local.properties (Windows escapes are undone).
android_sdk() {
  local root="${1:?repo root}" sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -z "$sdk" ] && [ -f "$root/android/local.properties" ]; then
    sdk=$(sed -n 's/^sdk.dir=//p' "$root/android/local.properties" | sed -e 's#\\\\#/#g' -e 's#\\:#:#g')
  fi
  [ -n "$sdk" ] || { echo "Android SDK not found: set ANDROID_HOME or sdk.dir in android/local.properties" >&2; return 1; }
  if [ "$L1NE_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then sdk=$(cygpath -u "$sdk"); fi
  echo "$sdk"
}
