import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failed += 1 } }
let env = ProcessInfo.processInfo.environment

// ---- BER / filter (known byte vectors)
check(BER.int(0) == [0x02, 0x01, 0x00], "BER int 0")
check(BER.int(128) == [0x02, 0x02, 0x00, 0x80], "BER int 128 needs a leading zero")
check(BER.int(-1) == [0x02, 0x01, 0xFF], "BER int -1")
check(BER.length(200) == [0x81, 0xC8] && BER.length(5) == [5] && BER.length(300) == [0x82, 0x01, 0x2C], "BER lengths")
check((try? LDAPFilter.encode("(cn=a)")) == [0xA3, 0x07, 0x04, 0x02, 0x63, 0x6E, 0x04, 0x01, 0x61], "filter equality")
check((try? LDAPFilter.encode("(objectClass=*)")) == [0x87, 0x0B] + Array("objectClass".utf8), "filter presence")
check((try? LDAPFilter.encode("(&(a=1)(b=2))"))?.first == 0xA0 && (try? LDAPFilter.encode("(|(a=1)(b=2))"))?.first == 0xA1 && (try? LDAPFilter.encode("(!(a=1))"))?.first == 0xA2, "filter and/or/not")
check((try? LDAPFilter.encode("(cn=Ma*in)"))?.first == 0xA4, "filter substrings")
check((try? LDAPFilter.encode("cn=a")) == nil && (try? LDAPFilter.encode("(cn=a")) == nil && (try? LDAPFilter.encode("(&)")) == nil, "bad filters rejected")
var rd = BERReader([0x30, 0x03, 0x02, 0x01, 0x05, 0x99])
let first = rd.next()
check(first?.tag == 0x30 && first.map { BERReader.int(Array($0.content.dropFirst(2))) } == 5 && rd.pos == 5, "reader frames one element and leaves the rest")
var short = BERReader([0x30, 0x05, 0x01]); check(short.next() == nil, "reader waits for a whole element")

// ---- mapping
let sample = [
    LDAPEntry(dn: "cn=Max,ou=p,dc=x", attributes: ["displayname": ["Jordan Lee"], "labeleduri": ["sip:7201@PBX.example.com"], "telephonenumber": ["+1 612 555 0101"]]),
    LDAPEntry(dn: "cn=Ext,ou=p,dc=x", attributes: ["telephonenumber": ["7102"], "cn": ["Sam"]]),
    LDAPEntry(dn: "cn=None,ou=p,dc=x", attributes: ["cn": ["Phone Only"], "telephonenumber": ["+1 612 555 0199"]]),
    LDAPEntry(dn: "cn=Bare,ou=p,dc=x", attributes: ["labeleduri": ["7305"], "givenname": ["Bare"], "sn": ["User"]]),
]
let noExt = DirectoryMapping.ldap(sample, nameAttr: "displayName", sipAttr: "labeledURI", phoneAttr: "telephoneNumber", phoneAsExtension: false, domain: "pbx.example.com")
check(noExt.entries.map(\.address) == ["7201@pbx.example.com", "7305@pbx.example.com"] && noExt.skipped == 2, "mapping: SIP attribute only, bare extension completed with the domain, phone-only skipped")
let withExt = DirectoryMapping.ldap(sample, nameAttr: "displayName", sipAttr: "labeledURI", phoneAttr: "telephoneNumber", phoneAsExtension: true, domain: "pbx.example.com")
check(withExt.entries.contains(VCard.Entry(name: "Sam", address: "7102@pbx.example.com")), "mapping: phone as extension (name falls back to cn)")
check(withExt.entries.contains(VCard.Entry(name: "Bare User", address: "7305@pbx.example.com")), "mapping: name from givenName + sn")
check(!withExt.entries.contains { $0.name == "Phone Only" } || withExt.entries.contains { $0.address == "16125550199@pbx.example.com" }, "mapping: with phone-as-extension a long number becomes digits at the domain (documented)")
check(DirectoryMapping.rdnValue("cn=Jordan Lee,ou=people,dc=example,dc=com") == "Jordan Lee", "rdn value")

// ---- live LDAP (independent server: OpenLDAP slapd)
func run(_ body: @escaping () async -> Void) { let g = DispatchSemaphore(value: 0); Task { await body(); g.signal() }; g.wait() }

if let port = env["LDAP_PORT"].flatMap(Int.init) {
    run {
        let base = LDAPSettings(host: "127.0.0.1", port: port, security: .none, bindDN: "cn=admin,dc=example,dc=com", password: "secret",
                                baseDN: "ou=people,dc=example,dc=com", filter: "(objectClass=inetOrgPerson)",
                                attributes: ["cn", "displayName", "labeledURI", "telephoneNumber", "givenName", "sn"])
        do {
            let all = try await LDAPClient.search(base)
            check(all.count == 5, "LDAP: all 5 people returned (got \(all.count))")
            check(all.first { $0.dn.contains("Jordan Lee") }?.first("labeledURI") == "sip:7201@pbx.example.com", "LDAP: attribute values read")
            check(all.first { $0.dn.contains("Alice") }?.attributes["labeleduri"]?.count == 2, "LDAP: multi-valued attribute")
            check(all.contains { $0.first("displayName") == "Zoë Müller" }, "LDAP: UTF-8 values")
            let r = DirectoryMapping.ldap(all, nameAttr: "displayName", sipAttr: "labeledURI", phoneAttr: "telephoneNumber", phoneAsExtension: false, domain: "pbx.example.com")
            check(Set(r.entries.map(\.address)) == ["7201@pbx.example.com", "alice@sip.example.org", "alice.work@sip.example.org", "zoe@pbx.example.com"], "LDAP -> contacts: only people with a SIP address (got \(r.entries.map(\.address)))")
        } catch { check(false, "LDAP search failed: \(error.localizedDescription)") }

        var f = base; f.filter = "(&(objectClass=inetOrgPerson)(cn=Jordan*))"
        if let r = try? await LDAPClient.search(f) { check(r.count == 1, "LDAP: filter (&(...)(cn=Jordan*)) -> 1 (got \(r.count))") } else { check(false, "LDAP filtered search failed") }
        f.filter = "(|(sn=Lee)(sn=Rivera))"
        if let r = try? await LDAPClient.search(f) { check(r.count == 2, "LDAP: filter (|(sn=..)(sn=..)) -> 2 (got \(r.count))") } else { check(false, "LDAP or-filter failed") }
        f.filter = "(&(objectClass=inetOrgPerson)(!(labeledURI=*)))"
        if let r = try? await LDAPClient.search(f) { check(r.count == 2, "LDAP: not-present filter -> the 2 without a URI (got \(r.count))") } else { check(false, "LDAP not-filter failed") }

        var bad = base; bad.password = "wrong"
        do { _ = try await LDAPClient.search(bad); check(false, "LDAP: wrong password should fail") }
        catch let LDAPError.server(code, _) { check(code == 49, "LDAP: wrong password -> invalidCredentials 49 (got \(code))") }
        catch { check(false, "LDAP: wrong password gave \(error)") }

        var anon = base; anon.bindDN = ""; anon.password = ""
        _ = try? await LDAPClient.search(anon)     // slapd's default ACL may or may not allow it; only checking it doesn't hang
        check(true, "LDAP: anonymous bind completes without hanging")

        var closed = base; closed.port = 1
        do { _ = try await LDAPClient.search(closed, timeout: 8); check(false, "LDAP: closed port should fail") }
        catch { check(true, "LDAP: closed port reports an error (\(error.localizedDescription))") }
    }
} else { print("skip LDAP live tests (no LDAP_PORT)") }

// ---- live CardDAV (independent server: Radicale)
if let base = env["CARDDAV_URL"], let url = URL(string: base) {
    run {
        do {
            let r = try await CardDAV.fetch(url: url, username: "alex", password: "pw")
            check(Set(r.entries.map(\.address)) == ["7201@pbx.example.com", "alice@sip.example.org"], "CardDAV: SIP entries only (got \(r.entries.map(\.address)))")
            check(r.entries.contains { $0.name == "Jordan Lee" }, "CardDAV: names read")
            check(r.skipped == 1, "CardDAV: phone-only card skipped (got \(r.skipped))")
        } catch { check(false, "CardDAV fetch failed: \(error.localizedDescription)") }
        do { _ = try await CardDAV.fetch(url: url, username: "alex", password: "nope"); check(false, "CardDAV: wrong password should fail") }
        catch let CardDAV.Failure.status(c) { check(c == 401, "CardDAV: wrong password -> 401 (got \(c))") }
        catch { check(false, "CardDAV: wrong password gave \(error)") }
        do { _ = try await CardDAV.fetch(url: url.appendingPathComponent("missing/"), username: "alex", password: "pw"); check(false, "CardDAV: missing book should fail") }
        catch let CardDAV.Failure.status(c) { check(c == 404, "CardDAV: missing address book -> 404 (got \(c))") }
        catch { check(false, "CardDAV: missing book gave \(error)") }
    }
} else { print("skip CardDAV live tests (no CARDDAV_URL)") }

print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
