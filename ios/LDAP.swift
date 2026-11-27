import Foundation
import Network

// A small LDAPv3 client: simple bind + subtree search over LDAPS (or plain TCP). iOS has no LDAP library, and a
// directory lookup only needs these two operations, so this speaks the protocol (BER) directly.

enum BER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 128 { return [UInt8(n)] }
        var bytes: [UInt8] = []; var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }
    static func int(_ v: Int, tag: UInt8 = 0x02) -> [UInt8] {
        var bytes: [UInt8] = []; var n = v
        repeat { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 } while n != 0 && n != -1
        if v >= 0, let f = bytes.first, f & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(tag, bytes)
    }
    static func enumerated(_ v: Int) -> [UInt8] { int(v, tag: 0x0A) }
    static func bool(_ b: Bool) -> [UInt8] { tlv(0x01, [b ? 0xFF : 0x00]) }
    static func octets(_ s: String, tag: UInt8 = 0x04) -> [UInt8] { tlv(tag, Array(s.utf8)) }
    static func seq(_ content: [UInt8]) -> [UInt8] { tlv(0x30, content) }
}

struct BERReader {
    let data: [UInt8]
    var pos = 0
    init(_ d: [UInt8]) { data = d }
    var atEnd: Bool { pos >= data.count }

    /// Reads one element; nil if the buffer doesn't hold a whole one yet.
    mutating func next() -> (tag: UInt8, content: [UInt8])? {
        guard pos + 2 <= data.count else { return nil }
        let tag = data[pos]
        var p = pos + 1
        var len = Int(data[p]); p += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, p + n <= data.count else { return nil }
            len = 0
            for i in 0..<n { len = (len << 8) | Int(data[p + i]) }
            p += n
        }
        guard p + len <= data.count else { return nil }
        pos = p + len
        return (tag, Array(data[p..<(p + len)]))
    }

    static func int(_ c: [UInt8]) -> Int {
        var v = c.first.map { $0 & 0x80 != 0 ? -1 : 0 } ?? 0
        for b in c { v = (v << 8) | Int(b) }
        return v
    }
    static func string(_ c: [UInt8]) -> String { String(decoding: c, as: UTF8.self) }
}

/// RFC 4515 filter text -> BER. Supports &, |, !, =, =*, substrings, >=, <=, ~=.
enum LDAPFilter {
    struct ParseError: Error, LocalizedError { var errorDescription: String? { "The LDAP filter isn't valid." } }

    static func encode(_ text: String) throws -> [UInt8] {
        var chars = Array(text.trimmingCharacters(in: .whitespaces))
        var i = 0
        let out = try parse(&chars, &i)
        guard i == chars.count else { throw ParseError() }
        return out
    }

    private static func parse(_ s: inout [Character], _ i: inout Int) throws -> [UInt8] {
        guard i < s.count, s[i] == "(" else { throw ParseError() }
        i += 1
        guard i < s.count else { throw ParseError() }
        var result: [UInt8]
        switch s[i] {
        case "&", "|":
            let tag: UInt8 = s[i] == "&" ? 0xA0 : 0xA1
            i += 1
            var inner: [UInt8] = []
            while i < s.count, s[i] == "(" { inner += try parse(&s, &i) }
            guard !inner.isEmpty else { throw ParseError() }
            result = BER.tlv(tag, inner)
        case "!":
            i += 1
            result = BER.tlv(0xA2, try parse(&s, &i))
        default:
            var item = ""
            while i < s.count, s[i] != ")" { item.append(s[i]); i += 1 }
            result = try simple(item)
        }
        guard i < s.count, s[i] == ")" else { throw ParseError() }
        i += 1
        return result
    }

    private static func simple(_ item: String) throws -> [UInt8] {
        for (op, tag) in [(">=", UInt8(0xA5)), ("<=", 0xA6), ("~=", 0xA8)] {
            if let r = item.range(of: op) {
                let attr = String(item[..<r.lowerBound]), value = unescape(String(item[r.upperBound...]))
                guard !attr.isEmpty else { throw ParseError() }
                return BER.tlv(tag, BER.octets(attr) + BER.tlv(0x04, value))
            }
        }
        guard let eq = item.firstIndex(of: "=") else { throw ParseError() }
        let attr = String(item[..<eq]), raw = String(item[item.index(after: eq)...])
        guard !attr.isEmpty else { throw ParseError() }
        if raw == "*" { return BER.tlv(0x87, Array(attr.utf8)) }                 // presence
        if raw.contains("*") {                                                  // substrings
            let parts = raw.components(separatedBy: "*")
            var subs: [UInt8] = []
            if let f = parts.first, !f.isEmpty { subs += BER.tlv(0x80, unescape(f)) }
            for mid in parts.dropFirst().dropLast() where !mid.isEmpty { subs += BER.tlv(0x81, unescape(mid)) }
            if parts.count > 1, let l = parts.last, !l.isEmpty { subs += BER.tlv(0x82, unescape(l)) }
            return BER.tlv(0xA4, BER.octets(attr) + BER.seq(subs))
        }
        return BER.tlv(0xA3, BER.octets(attr) + BER.tlv(0x04, unescape(raw)))   // equality
    }

    /// \2a style escapes
    private static func unescape(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; let u = Array(s.utf8); var i = 0
        while i < u.count {
            if u[i] == 0x5C, i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { out.append(v); i += 3 }
            else { out.append(u[i]); i += 1 }
        }
        return out
    }
}

struct LDAPEntry: Equatable {
    var dn: String
    var attributes: [String: [String]]      // lower-cased attribute name -> values
    func first(_ attr: String) -> String? { attributes[attr.lowercased()]?.first }
}

struct LDAPSettings {
    enum Security: String, Codable, CaseIterable { case ldaps, none }
    var host: String
    var port: Int
    var security: Security
    var bindDN: String
    var password: String
    var baseDN: String
    var filter: String
    var attributes: [String]
    var sizeLimit = 1000
}

enum LDAPError: Error, LocalizedError {
    case connection(String), protocolError(String), server(Int, String), timeout
    var errorDescription: String? {
        switch self {
        case .connection(let s): "Couldn't connect: \(s)"
        case .protocolError(let s): "Unexpected answer from the server: \(s)"
        case .server(let code, let msg): "The server refused (\(code))\(msg.isEmpty ? "" : ": \(msg)")."
        case .timeout: "The server didn't answer in time."
        }
    }
}

final class LDAPClient: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer: [UInt8] = []
    private var nextID = 1

    init(host: String, port: Int, security: LDAPSettings.Security) {
        let params: NWParameters = security == .ldaps ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()) : .tcp
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 636, using: params)
    }

    static func search(_ s: LDAPSettings, timeout: TimeInterval = 40) async throws -> [LDAPEntry] {
        let client = LDAPClient(host: s.host, port: s.port, security: s.security)
        return try await withThrowingTaskGroup(of: [LDAPEntry].self) { group in
            group.addTask { try await client.run(s) }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); client.connection.cancel(); throw LDAPError.timeout }
            defer { group.cancelAll(); client.connection.cancel() }
            let r = try await group.next()!
            return r
        }
    }

    private func run(_ s: LDAPSettings) async throws -> [LDAPEntry] {
        try await connect()
        // bind (an empty DN and password is an anonymous bind)
        let bindID = take()
        let bind = BER.seq(BER.int(bindID) + BER.tlv(0x60, BER.int(3) + BER.octets(s.bindDN) + BER.octets(s.password, tag: 0x80)))
        try await send(bind)
        let op = try await readMessage()
        guard op.tag == 0x61 else { throw LDAPError.protocolError("expected a bind response") }
        let (code, diag) = ldapResult(op.content)
        guard code == 0 else { throw LDAPError.server(code, diag) }

        // search
        let searchID = take()
        let filter = try LDAPFilter.encode(s.filter)
        let attrs = BER.seq(s.attributes.flatMap { BER.octets($0) })
        let search = BER.seq(BER.int(searchID) + BER.tlv(0x63,
            BER.octets(s.baseDN) + BER.enumerated(2) + BER.enumerated(0) + BER.int(s.sizeLimit) + BER.int(30) + BER.bool(false) + filter + attrs))
        try await send(search)

        var entries: [LDAPEntry] = []
        while true {
            let op = try await readMessage()
            switch op.tag {
            case 0x64:  // searchResEntry
                var e = BERReader(op.content)
                guard let dn = e.next(), let list = e.next() else { continue }
                var attrsOut: [String: [String]] = [:]
                var l = BERReader(list.content)
                while let attr = l.next() {
                    var a = BERReader(attr.content)
                    guard let type = a.next(), let vals = a.next() else { continue }
                    var v = BERReader(vals.content); var values: [String] = []
                    while let one = v.next() { values.append(BERReader.string(one.content)) }
                    attrsOut[BERReader.string(type.content).lowercased()] = values
                }
                entries.append(LDAPEntry(dn: BERReader.string(dn.content), attributes: attrsOut))
            case 0x65:  // searchResDone
                let (code, msg) = ldapResult(op.content)
                try? await send(BER.seq(BER.int(take()) + [0x42, 0x00]))      // unbind
                if code == 0 || code == 4 { return entries }                   // 4 = size limit exceeded: keep what we got
                throw LDAPError.server(code, msg)
            default: continue                                                   // references, intermediate messages
            }
        }
    }

    private func take() -> Int { defer { nextID += 1 }; return nextID }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var fired = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    }

    private func connect() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.first() { c.resume() }
                case .failed(let e): if once.first() { c.resume(throwing: LDAPError.connection(e.localizedDescription)) }
                case .waiting(let e): if once.first() { c.resume(throwing: LDAPError.connection(e.localizedDescription)) }
                case .cancelled: if once.first() { c.resume(throwing: LDAPError.connection("cancelled")) }
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "l1ne.ldap"))
        }
    }

    private func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { e in
                if let e { c.resume(throwing: LDAPError.connection(e.localizedDescription)) } else { c.resume() }
            })
        }
    }

    /// One LDAPMessage: returns its protocolOp element (the message ID is not needed: one request is in flight at a time).
    private func readMessage() async throws -> (tag: UInt8, content: [UInt8]) {
        while true {
            var r = BERReader(buffer)
            if let msg = r.next(), msg.tag == 0x30 {
                buffer.removeFirst(r.pos)
                var m = BERReader(msg.content)
                guard m.next() != nil, let op = m.next() else { throw LDAPError.protocolError("short message") }
                return op
            }
            let chunk: Data = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { c.resume(throwing: LDAPError.connection(error.localizedDescription)) }
                    else if let data, !data.isEmpty { c.resume(returning: data) }
                    else if isComplete { c.resume(throwing: LDAPError.connection("the server closed the connection")) }
                    else { c.resume(returning: Data()) }
                }
            }
            buffer += Array(chunk)
        }
    }
}

/// The LDAPResult that ends a bind or search response: the result code, then (after the matched DN) the diagnostic message.
private func ldapResult(_ content: [UInt8]) -> (code: Int, message: String) {
    var r = BERReader(content)
    let code = r.next().map { BERReader.int($0.content) } ?? -1
    _ = r.next()
    return (code, r.next().map { BERReader.string($0.content) } ?? "")
}
