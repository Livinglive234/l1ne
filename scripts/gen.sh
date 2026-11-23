#!/bin/bash
# Generates L1ne.xcodeproj from project.yml. Your signing team stays out of the repo:
#   export L1NE_TEAM_ID=XXXXXXXXXX     (your Apple Developer Team ID; leave unset for simulator-only builds)
set -euo pipefail
cd "$(dirname "$0")/.."
L1NE_TEAM_ID="${L1NE_TEAM_ID:-}" xcodegen generate
