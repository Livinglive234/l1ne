#!/bin/bash
# Compiles tests/parsers/main.swift with the app sources it exercises (plain Swift, no simulator) and runs it against tests/fixtures.
# usage: tests/parsers/run.sh        (CI runs the same script)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
OUT="$(mktemp -d)/parsers"
swiftc -o "$OUT" L1ne/PhoneFormat.swift L1ne/RingbackRule.swift L1ne/SipLog.swift L1ne/VersionLabel.swift L1ne/VCard.swift L1ne/Provisioning.swift L1ne/Account.swift L1ne/SystemContacts.swift L1ne/ContactsStore.swift tests/parsers/main.swift
"$OUT" tests/fixtures
