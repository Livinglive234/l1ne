#!/bin/bash
# Creates the GitHub release for a version tag if it is not there yet. The Android and iPhone workflows both call this, whichever finishes first makes it.
#   v0.1.0-beta.3   ->  a PUBLISHED PRE-RELEASE titled "L1ne 0.1.0 beta 3"   (same for -rc1, -alpha.1, any suffix)
#   v0.1.0          ->  a DRAFT titled "L1ne 0.1.0", published by hand after a look
# usage: scripts/make-release.sh <tag> <commit>        (DRY_RUN=1 prints the command instead of running it)
set -euo pipefail
TAG="$1"; SHA="$2"
GH="gh"; [ "${DRY_RUN:-}" = 1 ] && GH="echo gh"
if [ "${DRY_RUN:-}" != 1 ] && gh release view "$TAG" >/dev/null 2>&1; then exit 0; fi

V="${TAG#v}"; CORE="${V%%-*}"; SUFFIX=""; [[ "$V" == *-* ]] && SUFFIX="${V#*-}"
if [ -z "$SUFFIX" ]; then
  $GH release create "$TAG" --draft --target "$SHA" --title "L1ne $CORE" --notes-file .github/release-notes.md
  exit 0
fi

# "beta.3" -> "beta 3", "rc2" -> "release candidate 2", "alpha1" -> "alpha 1"
NAME="${SUFFIX%%[0-9.]*}"; NUM="${SUFFIX#"$NAME"}"; NUM="${NUM#.}"
case "$NAME" in rc) NAME="release candidate" ;; esac
LABEL="${NAME:-$SUFFIX}${NUM:+ $NUM}"
NOTES="$(mktemp)"
{
  echo "**This is a $LABEL, a pre-release for testing.** It can have bugs. Each one is signed with the project's release key and numbered higher than the last, so a newer one installs **over** an older one on Android and keeps your accounts."
  echo
  cat .github/release-notes.md
} > "$NOTES"
$GH release create "$TAG" --prerelease --target "$SHA" --title "L1ne $CORE $LABEL" --notes-file "$NOTES" || $GH release view "$TAG" >/dev/null     # the other workflow may have made it a moment ago
