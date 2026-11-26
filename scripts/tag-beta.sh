#!/bin/bash
# Cuts the next beta: tags main as v<version>-beta.<n> and pushes the tag. CI then builds it, signs the Android APKs and publishes a pre-release.
# usage: scripts/tag-beta.sh [version] [--dry-run]       version defaults to the newest tag's, e.g. 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."
DRY=0; CORE=""
for a in "$@"; do if [ "$a" = "--dry-run" ]; then DRY=1; else CORE="$a"; fi; done
git fetch -q --tags
if [ -z "$CORE" ]; then newest="$(git tag -l 'v*' --sort=-v:refname | head -1)"; newest="${newest#v}"; CORE="${newest%%-*}"; CORE="${CORE:-0.1.0}"; fi
LAST="$(git tag -l "v$CORE-beta.*" | sed -E 's/.*-beta\.//' | sort -n | tail -1)"
N=$(( ${LAST:-0} + 1 )); TAG="v$CORE-beta.$N"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Run this on main."; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first."; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Push main first: the beta is built from what is on GitHub."; exit 1; }
echo "Next beta: $TAG, from $(git rev-parse --short HEAD) ($(git log -1 --format=%s))"
[ $DRY = 1 ] && exit 0
git tag -a "$TAG" -m "L1ne $CORE beta $N"
git push origin "$TAG"
echo "Pushed. Watch it at: gh run list --limit 4"
