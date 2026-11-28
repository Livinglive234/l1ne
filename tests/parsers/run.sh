#!/bin/bash
# Compiles tests/parsers/main.swift with the app sources it exercises (plain Swift, no simulator) and runs it against tests/fixtures.
# usage: tests/parsers/run.sh        (CI runs the same script)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
OUT="$(mktemp -d)/parsers"
swiftc -o "$OUT" ios/PhoneFormat.swift ios/RingbackRule.swift ios/SipLog.swift ios/VersionLabel.swift ios/VCard.swift ios/Provisioning.swift ios/Account.swift ios/SystemContacts.swift ios/ContactsStore.swift ios/CallLog.swift tests/parsers/main.swift
"$OUT" tests/fixtures
