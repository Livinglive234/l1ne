#!/bin/bash
# Runs the directory tests against real, independent servers: OpenLDAP (slapd) and Radicale (CardDAV).
# Needs: brew install openldap; python3 -m venv /tmp/radicale-venv && /tmp/radicale-venv/bin/pip install radicale
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d /tmp/l1ne-dirtest.XXXXXX)
LDAP_PORT=3389; DAV_PORT=5232
cleanup() { [ -f "$T/slapd.pid" ] && kill "$(cat "$T/slapd.pid")" 2>/dev/null || true; [ -n "${RAD:-}" ] && kill "$RAD" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

# --- OpenLDAP
S=/opt/homebrew/etc/openldap/schema
mkdir -p "$T/db"
cat > "$T/slapd.conf" <<CONF
include $S/core.schema
include $S/cosine.schema
include $S/inetorgperson.schema
pidfile $T/slapd.pid
database mdb
maxsize 104857600
suffix "dc=example,dc=com"
rootdn "cn=admin,dc=example,dc=com"
rootpw secret
directory $T/db
index objectClass eq
CONF
/opt/homebrew/opt/openldap/sbin/slapadd -f "$T/slapd.conf" -l "$ROOT/tests/directory/people.ldif" >/dev/null
/opt/homebrew/opt/openldap/libexec/slapd -f "$T/slapd.conf" -h "ldap://127.0.0.1:$LDAP_PORT" -d 0 >"$T/slapd.log" 2>&1 &
sleep 1

# --- Radicale (htpasswd with plain text for the test)
mkdir -p "$T/dav"
echo "alex:pw" > "$T/users"
cat > "$T/radicale.conf" <<CONF
[server]
hosts = 127.0.0.1:$DAV_PORT
[auth]
type = htpasswd
htpasswd_filename = $T/users
htpasswd_encryption = plain
[storage]
filesystem_folder = $T/dav
CONF
/tmp/radicale-venv/bin/python -m radicale --config "$T/radicale.conf" >"$T/radicale.log" 2>&1 &
RAD=$!
sleep 2
BOOK="http://127.0.0.1:$DAV_PORT/alex/contacts/"
curl -s -u alex:pw -X MKCOL "$BOOK" -H 'Content-Type: application/xml' --data '<?xml version="1.0"?><mkcol xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav"><set><prop><resourcetype><collection/><C:addressbook/></resourcetype></prop></set></mkcol>' -o /dev/null
put() { curl -s -u alex:pw -X PUT "$BOOK$1.vcf" -H 'Content-Type: text/vcard' --data-binary "$2" -o /dev/null; }
put max $'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:max\r\nFN:Jordan Lee\r\nN:Lee;Jordan;;;\r\nIMPP:sip:7201@pbx.example.com\r\nEND:VCARD\r\n'
put alice $'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:alice\r\nFN:Alice Example\r\nX-SIP:sip:alice@sip.example.org\r\nTEL:+16125551234\r\nEND:VCARD\r\n'
put phone $'BEGIN:VCARD\r\nVERSION:3.0\r\nUID:phone\r\nFN:Phone Only\r\nTEL:+16125550000\r\nEND:VCARD\r\n'

# --- build and run
swiftc -o "$T/dirtests" "$ROOT/ios/VCard.swift" "$ROOT/ios/LDAP.swift" "$ROOT/ios/CardDAV.swift" "$ROOT/ios/DirectoryMapping.swift" "$ROOT/tests/directory/main.swift" 2>&1 | grep -E "error" || true
LDAP_PORT=$LDAP_PORT CARDDAV_URL="$BOOK" "$T/dirtests"
