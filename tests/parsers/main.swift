import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failed += 1 } }
let dir = URL(fileURLWithPath: CommandLine.arguments[1])

// vCard
let v = VCard.parse(try! String(contentsOf: dir.appendingPathComponent("contacts.vcf"), encoding: .utf8))
check(v.entries.count == 3, "3 SIP entries (got \(v.entries.count))")
check(v.skipped == 1, "1 card skipped for no SIP address (got \(v.skipped))")
check(v.entries.first == VCard.Entry(name: "Jordan Lee", address: "7201@pbx.example.com"), "domain lower-cased, scheme stripped")
check(v.entries.contains { $0.name == "FoldedName Person" && $0.address == "alice@sip.example.com" }, "folded FN + IMPP with SERVICE-TYPE param and uri params")
check(v.entries.contains { $0.name == "Jane Doe" && $0.address == "jane@example.org" }, "name from N when FN is missing, X-SIP, xmpp ignored")
check(!v.entries.contains { $0.address.contains("+1612") }, "phone numbers are never imported")

// phone numbers, for display
check(PhoneFormat.pretty("6517604266") == "(651) 760-4266", "a bare US number is formatted")
check(PhoneFormat.pretty("16517604266") == "(651) 760-4266" && PhoneFormat.pretty("+16517604266") == "(651) 760-4266", "+1 and 1 prefixes are dropped")
check(["7001", "5550142", "(612) 354-0645", "Max Example", "+442071234567", "0123456789", "61235406451", ""].allSatisfy { PhoneFormat.pretty($0) == $0 }, "extensions, names, formatted and international numbers are left alone")

check(PhoneFormat.isOutside("6125550142") && PhoneFormat.isOutside("16125550142") && PhoneFormat.isOutside("+16125550142"), "outside numbers are told")
check(!["7001", "2993", "0", "*97", "96125550142", "+442071234567"].contains { PhoneFormat.isOutside($0) }, "extensions, codes and prefixed numbers are not outside numbers")

// SIP log: what is removed, what is kept
let regMsg = "REGISTER sip:pbx.example.com SIP/2.0\r\nAuthorization: Digest username=\"7001\", realm=\"asterisk\", response=\"0123456789abcdef\"\r\nCSeq: 2 REGISTER"
let regClean = LogRedactor.clean(regMsg)
check(!regClean.contains("0123456789abcdef") && !regClean.contains("realm") && regClean.contains("Authorization: [removed]") && regClean.contains("CSeq: 2 REGISTER"), "the digest header is removed, the rest of the message stays")
check(LogRedactor.clean("a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:WVNfX19zZWNyZXRrZXlfX19f\na=rtpmap:0 PCMU/8000") == "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:[removed]\na=rtpmap:0 PCMU/8000", "SRTP keys are removed")
check(LogRedactor.clean("password=hunter2 next") == "password=[removed] next" && LogRedactor.clean("secret: abc") == "secret: [removed]" && LogRedactor.clean("cnonce=\"zzz\"") == "cnonce=\"[removed]\"", "anything that looks like a secret is removed")
let fromLine = "From: \"(612) 354-0645\" <sip:6123540645@pbx.example.com>;tag=abc"
check(LogRedactor.clean(fromLine) == fromLine, "ordinary lines are untouched")
SipLog.shared.clear()
for i in 0..<2600 { SipLog.shared.add("line \(i)") }
check(SipLog.shared.count == 2500 && SipLog.shared.text().hasPrefix("line 100") && SipLog.shared.text().hasSuffix("line 2599"), "the log keeps the last 2500 entries")
SipLog.shared.clear(); SipLog.shared.add("Authorization: Digest response=\"x\""); SipLog.shared.add("   ")
check(SipLog.shared.text() == "Authorization: [removed]" && SipLog.shared.count == 1, "entries are redacted as they arrive; blank ones are skipped")

// ringback
check(RingbackRule.wanted(outgoing: true, answered: false, waiting: true, acceptEarlyMedia: false), "a call that is dialling or ringing gets L1ne's ringback tone")
check(!RingbackRule.wanted(outgoing: true, answered: true, waiting: true, acceptEarlyMedia: false) && !RingbackRule.wanted(outgoing: false, answered: false, waiting: true, acceptEarlyMedia: false)
      && !RingbackRule.wanted(outgoing: true, answered: false, waiting: false, acceptEarlyMedia: false) && !RingbackRule.wanted(outgoing: true, answered: false, waiting: true, acceptEarlyMedia: true), "none once answered, for incoming calls, when not waiting, or when the PBX's early media is let through")


// auto answer: off unless switched on; an allow list matches extensions exactly and numbers by their digits
var aa = Account(); check(!aa.mayAutoAnswer(callerUser: "7001"), "auto answer is off by default")
aa.autoAnswer = true; check(aa.mayAutoAnswer(callerUser: "7001"), "on with no list: any caller that asks")
aa.autoAnswerFrom = "7001, (651) 760-4266"
check(aa.mayAutoAnswer(callerUser: "7001") && !aa.mayAutoAnswer(callerUser: "7002") && aa.mayAutoAnswer(callerUser: "16517604266") && !aa.mayAutoAnswer(callerUser: "6125550142"), "the list lets in the listed extension and number only")

// caller ID kept in the history
check(PhoneFormat.callerIDName(remote: "\"Ada Lovelace\" <sip:6125550142@pbx.example.com>") == "Ada Lovelace", "a caller's name is kept")
check(PhoneFormat.callerIDName(remote: "\"6125550142\" <sip:6125550142@pbx.example.com>") == "" && PhoneFormat.callerIDName(remote: "\"(612) 555-0142\" <sip:6125550142@pbx.example.com>") == "", "a name that is only the number again is not kept")
check(PhoneFormat.callerIDName(remote: "<sip:7001@pbx.example.com>") == "" && PhoneFormat.callerIDName(remote: "sip:7001@pbx.example.com") == "", "no name, nothing kept")

// version label
check(VersionLabel.pretty("0.1.0-beta.9") == "0.1.0 beta 9" && VersionLabel.pretty("0.1.0-rc1") == "0.1.0 rc1" && VersionLabel.pretty("0.1.0") == "0.1.0" && VersionLabel.pretty("1.0") == "1.0", "a tag version reads naturally")

// outside-line prefix
var ob = Account(); ob.username = "7001"; ob.domain = "pbx.example.com"; ob.outboundPrefix = "9"
check(ob.dial("6125550142") == "96125550142" && ob.dial("(612) 555-0142") == "96125550142" && ob.dial("16125550142") == "916125550142" && ob.dial("+16125550142") == "916125550142", "outside numbers get the prefix")
check(["7001", "2997", "0", "*97", "911", "96125550142"].allSatisfy { ob.dial($0) == $0 }, "extensions, codes and prefixed numbers are left alone")
var ob2 = ob; ob2.formatWithPrefix = true; ob2.intlPrefix = "1"; ob2.plusTo00 = true
// dialling an address: the account's own server gets the dial rules (the outside-line prefix is put back on a call-back), another server is left alone
var dialAcc = ob; dialAcc.domain = "pbx.example.com"
check(dialAcc.dialURI("6125550142@pbx.example.com") == "sip:96125550142@pbx.example.com" && dialAcc.dialURI("6125550142@PBX.example.com") == "sip:96125550142@pbx.example.com", "a call-back to an outside number on the account's own server gets the prefix again")
check(dialAcc.dialURI("7001@pbx.example.com") == "sip:7001@pbx.example.com" && dialAcc.dialURI("6125550142") == "sip:96125550142@pbx.example.com", "extensions are left alone, a typed number gets the rules")
check(dialAcc.dialURI("6125550142@other.example.org") == "sip:6125550142@other.example.org" && dialAcc.dialURI("sip:*97@pbx.example.com") == "sip:*97@pbx.example.com", "another server and explicit sip: addresses go out as they are")
check(ob2.dial("6125550142") == "96125550142" && ob2.dial("+44207123456789") == "0044207123456789", "works with the other dial rules")
check(ob.withoutOutboundPrefix("96125550142@pbx.example.com") == "6125550142@pbx.example.com" && ob.withoutOutboundPrefix("7001@pbx.example.com") == "7001@pbx.example.com" && ob.withoutOutboundPrefix("9125550142@pbx.example.com") == "9125550142@pbx.example.com", "history keeps the number without the prefix")
let xmlPrefix = (try! String(contentsOf: dir.appendingPathComponent("linphone-provision.xml"), encoding: .utf8)).replacingOccurrences(of: "</config>", with: "<section name=\"l1ne\"><entry name=\"outbound_prefix\">9</entry></section></config>")
let rp = try! Provisioning.parse(xml: Data(xmlPrefix.utf8))
check(rp.accounts.allSatisfy { $0.account.outboundPrefix == "9" }, "the l1ne section is the default prefix for every account in the file")
let perAccount = (try! String(contentsOf: dir.appendingPathComponent("linphone-provision.xml"), encoding: .utf8)).replacingOccurrences(of: "<entry name=\"reg_sendregister\" overwrite=\"true\">1</entry>", with: "<entry name=\"reg_sendregister\" overwrite=\"true\">1</entry><entry name=\"l1ne_outbound_prefix\">9</entry>")
let rpa = try! Provisioning.parse(xml: Data(perAccount.utf8))
check(rpa.accounts[0].account.outboundPrefix == "9" && rpa.accounts[1].account.outboundPrefix == "", "a prefix inside one account's own section is set on that account only")
let overridden = try! Provisioning.parse(xml: Data(xmlPrefix.replacingOccurrences(of: "<entry name=\"reg_sendregister\" overwrite=\"true\">1</entry>", with: "<entry name=\"reg_sendregister\" overwrite=\"true\">1</entry><entry name=\"l1ne_outbound_prefix\"></entry>").utf8))
check(overridden.accounts[0].account.outboundPrefix == "" && overridden.accounts[1].account.outboundPrefix == "9", "an account's own empty entry beats the file's default, which still covers the others")
check((try! Provisioning.parse(xml: Data(xmlPrefix.replacingOccurrences(of: ">9<", with: ">9x<").utf8))).accounts[0].account.outboundPrefix == "", "only digits, * and # are accepted")

// provisioning
let r = try! Provisioning.parse(xml: try! Data(contentsOf: dir.appendingPathComponent("linphone-provision.xml")))
check(r.accounts.count == 2, "both accounts are returned (got \(r.accounts.count))")
check(r.accounts[1].account.domain == "sip.linphone.org", "the linphone.org account is returned like any other")
let a = r.accounts[0]
check(a.account.username == "7201" && a.account.domain == "pbx.example.com", "identity")
check(a.account.port == 5061 && a.account.transport == .tls, "tls on 5061")
check(a.account.label == "pbx.example.com" && a.account.displayName == "Max Example", "label is the SIP domain, display name kept")
check(a.secret == "test-secret-not-real", "secret from auth_info")
check(r.contactsURL == "https://pbx.example.com/p/contacts-0123456789abcdef0123456789abcdef.vcf", "contacts URL")
check(r.accounts[1].secret == "another-fake", "the linphone.org account keeps its own credentials")

// links
check(Provisioning.configURL(from: "linphone-config:https://pbx.example.com/p/x.xml")?.absoluteString == "https://pbx.example.com/p/x.xml", "linphone-config: link")
check(Provisioning.configURL(from: " l1ne-config:https://a.b/c.xml ")?.host == "a.b", "l1ne-config: link")
check(Provisioning.configURL(from: "https://a.b/c.xml") != nil, "plain https")
check(Provisioning.configURL(from: "http://a.b/c.xml") == nil, "http refused")
check(Provisioning.configURL(from: "sip:7201@a.b") == nil, "non-config refused")
check((try? Provisioning.parse(xml: Data("<html></html>".utf8))) == nil, "non-config XML rejected")

// system contacts -> SIP-only entries
import Contacts
func person(_ given: String, _ family: String, im: [(String, String)] = [], urls: [String] = [], phone: String? = nil) -> CNContact {
    let c = CNMutableContact(); c.givenName = given; c.familyName = family
    c.instantMessageAddresses = im.map { CNLabeledValue(label: nil, value: CNInstantMessageAddress(username: $0.0, service: $0.1)) }
    c.urlAddresses = urls.map { CNLabeledValue(label: nil, value: $0 as NSString) }
    if let p = phone { c.phoneNumbers = [CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: p))] }
    return c
}
let sc = SystemContacts.convert([
    person("Jordan", "Lee", im: [("7201@PBX.example.com", "SIP")], phone: "+16125551234"),
    person("Alice", "Example", im: [("sip:alice@sip.example.com;transport=tls", "Other")]),
    person("Web", "Only", urls: ["sips:web@example.org", "https://example.org"]),
    person("Phone", "Only", im: [("someone", "Skype")], phone: "+16125550000"),
    person("Bare", "User", im: [("bob", "SIP")]),
])
check(sc.entries.contains(VCard.Entry(name: "Jordan Lee", address: "7201@pbx.example.com")), "SIP-service IM address with bare user@domain")
check(sc.entries.contains(VCard.Entry(name: "Alice Example", address: "alice@sip.example.com")), "sip: URI in an IM entry, params stripped")
check(sc.entries.contains(VCard.Entry(name: "Web Only", address: "web@example.org")), "sip URL on the card; https URL ignored")
check(sc.skipped == 2, "cards with no SIP address skipped (phone-only, non-SIP IM, bare user without domain) -> got \(sc.skipped)")
check(!sc.entries.contains { $0.address.contains("1612") }, "phone numbers never imported")

// account model: dial rules and old saved accounts
var acc = Account(); acc.domain = "pbx.example.com"; acc.username = "7198"
check(acc.dial("7201") == "7201", "plain extension unchanged")
acc.formatWithPrefix = true; acc.intlPrefix = "1"
check(acc.dial("6125550123") == "+16125550123", "national number gets +prefix")
check(acc.dial("7201") == "7201" && acc.dial("*97") == "*97", "extensions and codes are not prefixed")
check(acc.dial("(612) 555-0123") == "+16125550123", "punctuation removed")
acc.plusTo00 = true
check(acc.dial("6125550123") == "0016125550123", "+ replaced by 00")
acc.intlPrefix = "44"; acc.formatWithPrefix = true; acc.plusTo00 = false
check(acc.dial("07911123456") == "+447911123456", "trunk 0 dropped before the country code")
acc.formatWithPrefix = false; acc.dialStripPrefix = "9"; acc.dialAddPrefix = "1"
check(acc.dial("96125550123") == "16125550123", "strip then add prefix")
let old = #"{"id":"0F0E0D0C-0B0A-0908-0706-050403020100","label":"Old","domain":"pbx.example.com","port":5061,"transport":"tls","media":"srtp-sdes","username":"7198","authUser":"","contactsURL":"","pushGateway":"","dialStripPrefix":"","dialAddPrefix":""}"#
let decoded = try? JSONDecoder().decode(Account.self, from: Data(old.utf8))
check(decoded?.expires == 3600 && decoded?.enabled == true && decoded?.mwiEnabled == true && decoded?.iceEnabled == false, "old saved account loads with defaults for new fields")
let again = try? JSONDecoder().decode(Account.self, from: JSONEncoder().encode(acc))
check(again == acc, "account round-trips through JSON")
let dtls = try? Provisioning.parse(xml: Data("""
<config><section name="proxy_0"><entry name="reg_identity">sip:1@h.example</entry><entry name="reg_proxy">sip:h.example;transport=tls</entry><entry name="reg_expires">1800</entry></section>
<section name="auth_info_0"><entry name="username">1</entry><entry name="passwd">x</entry></section>
<section name="sip"><entry name="media_encryption">dtls</entry><entry name="media_encryption_mandatory">1</entry></section></config>
""".utf8))
check(dtls?.accounts.first?.account.media == .srtpDTLS && dtls?.accounts.first?.account.mediaMandatory == true && dtls?.accounts.first?.account.expires == 1800, "DTLS, mandatory flag and expiry read from provisioning")

// voicemail target
var vm = Account(); vm.domain = "pbx.example.com"
check(vm.voicemailTarget == "sip:*97@pbx.example.com", "voicemail defaults to *97")
vm.voicemailURI = ""
check(vm.voicemailTarget == nil, "a cleared voicemail number gives no target")
vm.voicemailURI = "*97"; check(vm.voicemailTarget == "sip:*97@pbx.example.com", "*97 becomes sip:*97@server")
vm.voicemailURI = " 8500 "; check(vm.voicemailTarget == "sip:8500@pbx.example.com", "other extension, spaces trimmed")
vm.voicemailURI = "sip:mail@vm.example.org"; check(vm.voicemailTarget == "sip:mail@vm.example.org", "full SIP address used as typed")
vm.voicemailURI = "SIPS:mail@vm.example.org"; check(vm.voicemailTarget == "SIPS:mail@vm.example.org", "sips: address used as typed")
vm.voicemailURI = "7000"; vm.formatWithPrefix = true; vm.intlPrefix = "1"; check(vm.voicemailTarget == "sip:7000@pbx.example.com", "voicemail number is never reformatted by dial rules")

// port follows transport
var pt = Account()
check(pt.transport == .tls && pt.port == 5061, "new account defaults to TLS on 5061")
pt.changeTransport(to: .udp); check(pt.transport == .udp && pt.port == 5060, "TLS -> UDP moves 5061 to 5060")
pt.changeTransport(to: .tcp); check(pt.transport == .tcp && pt.port == 5060, "UDP -> TCP keeps 5060")
pt.changeTransport(to: .tls); check(pt.transport == .tls && pt.port == 5061, "TCP -> TLS moves 5060 to 5061")
pt.port = 5080; pt.changeTransport(to: .udp); check(pt.port == 5080, "a custom port is left alone")
pt.port = 0; pt.changeTransport(to: .tls); check(pt.port == 5061, "a missing port gets the default")
check(Account.defaultPort(for: .udp) == 5060 && Account.defaultPort(for: .tcp) == 5060 && Account.defaultPort(for: .tls) == 5061, "default ports")

// new-account short form
var ns = Account(); ns.setServer("pbx.example.com"); check(ns.domain == "pbx.example.com" && ns.port == 5061, "plain domain keeps the transport's port")
ns.setServer(" sip:pbx.example.com:5080 "); check(ns.domain == "pbx.example.com" && ns.port == 5080, "sip: prefix and host:port are read")
ns.setServer("sips:pbx.example.com/extra;transport=tls"); check(ns.domain == "pbx.example.com", "path and parameters dropped")
ns.setServer("[2001:db8::1]"); check(ns.domain == "[2001:db8::1]", "IPv6 literal left whole")
var fin = Account(); fin.domain = "pbx.example.com:5061"; fin.displayName = "Alex Example"; fin.username = "7198"; fin.finishNewAccount()
check(fin.domain == "pbx.example.com" && fin.port == 5061 && fin.label == "pbx.example.com" && fin.media == .srtpSDES, "new TLS account: parsed, named after its server (not the display name), SRTP kept")
var udp = Account(); udp.changeTransport(to: .udp); udp.domain = "pbx.example.com"; udp.finishNewAccount()
check(udp.media == .none && udp.mediaMandatory == false && udp.port == 5060, "new UDP account: no SDES (it needs TLS), port 5060")

// contacts: sources, replacement and the rule that a directory never touches your own entries
MainActor.assumeIsolated {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("l1ne-contacts-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = ContactsStore(url: tmp)
    _ = store.add(name: "Typed Tom", address: "tom@pbx.example.com", account: nil)                       // typed in
    store.merge(VCard.Result(entries: [VCard.Entry(name: "Picked Pat", address: "pat@pbx.example.com")], skipped: 0), account: nil, source: "picker")
    store.merge(VCard.Result(entries: [VCard.Entry(name: "Old Link", address: "old@pbx.example.com")], skipped: 0), account: nil, source: "link")
    let tag = "dir:TEST"
    let one = store.replaceSource(tag, result: VCard.Result(entries: [
        VCard.Entry(name: "Max", address: "7201@pbx.example.com"), VCard.Entry(name: "Sam", address: "7102@pbx.example.com"),
        VCard.Entry(name: "Not Tom", address: "tom@pbx.example.com")], skipped: 1), account: nil)
    check(one.added == 2 && one.kept == 1 && one.skipped == 1, "directory sync adds new entries and leaves a typed-in address alone (added \(one.added), kept \(one.kept))")
    check(store.contacts.first { $0.address == "tom@pbx.example.com" }?.name == "Typed Tom", "a typed-in contact is never renamed by a directory")
    let two = store.replaceSource(tag, result: VCard.Result(entries: [VCard.Entry(name: "Maxwell", address: "7201@pbx.example.com")], skipped: 0), account: nil)
    check(two.updated == 1 && two.removed == 1, "second sync renames one and removes the one that left the directory (updated \(two.updated), removed \(two.removed))")
    check(!store.contacts.contains { $0.address == "7102@pbx.example.com" }, "the removed entry is gone")
    check(store.contacts.contains { $0.name == "Picked Pat" } && store.contacts.contains { $0.name == "Typed Tom" }, "picked and typed contacts survive directory syncs")
    check(store.hasLinkImports, "link imports are detected")
    let n = store.removeLinkImports()
    check(n == 1 && !store.contacts.contains { $0.name == "Old Link" }, "turning on a directory removes link imports")
    check(store.contacts.contains { $0.source == tag } && store.contacts.contains { $0.name == "Picked Pat" }, "...but not directory, picked or typed contacts")
    store.delete(source: tag); check(!store.contacts.contains { $0.source == tag }, "deleting a directory removes only its contacts")
    let reopened = ContactsStore(url: tmp); check(reopened.contacts.count == store.contacts.count, "contacts persist to disk")
}

print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)

// favorites survive a directory rename and old saved contacts (no favorite key) still load
MainActor.assumeIsolated {
    let cs = ContactsStore(url: URL(fileURLWithPath: NSTemporaryDirectory() + "fav-\(UUID().uuidString).json"))
    _ = cs.add(name: "Old name", address: "7002@pbx.example.com", account: nil)
    cs.setFavorite(address: "7002@PBX.example.com", name: "x", account: nil, true)
    _ = cs.replaceSource("dir:1", result: VCard.Result(entries: [VCard.Entry(name: "New name", address: "7002@pbx.example.com")], skipped: 0), account: nil)
    check(cs.contacts.count == 1 && cs.contacts[0].favorite == true, "a star is kept")
    let old = try? JSONDecoder().decode([Contact].self, from: Data(#"[{"id":"0F0E0D0C-0B0A-0908-0706-050403020100","name":"A","address":"7001@pbx","imported":false}]"#.utf8))
    check(old?.first?.favorite == nil, "a contact saved before favorites existed still loads")
}

// removing an account takes the contacts it imported with it, and leaves the ones you typed
MainActor.assumeIsolated {
    let cs = ContactsStore(url: URL(fileURLWithPath: NSTemporaryDirectory() + "rm-\(UUID().uuidString).json"))
    let acc = UUID(), other = UUID()
    _ = cs.merge(VCard.Result(entries: [VCard.Entry(name: "Imported", address: "7001@pbx.example.com")], skipped: 0), account: acc)
    _ = cs.merge(VCard.Result(entries: [VCard.Entry(name: "Other PBX", address: "7002@other.example.com")], skipped: 0), account: other)
    _ = cs.add(name: "Typed", address: "7003@pbx.example.com", account: acc)
    cs.removeImports(forAccount: acc)
    check(cs.contacts.map(\.name).sorted() == ["Other PBX", "Typed"], "removing an account removes the contacts it imported, not typed ones or another account's")
}

// calls with the same person
do {
    func rec(_ peer: String) -> CallRecord { CallRecord(peer: peer, accountID: nil, direction: .incoming, duration: 1) }
    check(rec("7001@pbx.example.com").isWith("7001@PBX.example.com") && rec("6517604266").isWith("6517604266@pbx.example.com") && rec("16517604266@pbx").isWith("(651) 760-4266"), "the same extension or number is the same person")
    check(!rec("7001@pbx").isWith("7002@pbx") && !rec("7001@pbx").isWith("7001@other"), "another extension or server is not")
}
