import Foundation
import Darwin

// MARK: - Codificación BER mínima para SNMP v2c

typealias OID = [UInt32]

func oid(_ s: String) -> OID { s.split(separator: ".").compactMap { UInt32($0) } }

enum BER {
    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }

    static func integer(_ v: Int64) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: x & 0xFF), at: 0)
            x >>= 8
        } while !(x == 0 && bytes[0] & 0x80 == 0) && !(x == -1 && bytes[0] & 0x80 != 0)
        return tlv(0x02, bytes)
    }

    static func octets(_ s: String) -> [UInt8] { tlv(0x04, Array(s.utf8)) }

    static func objectID(_ o: OID) -> [UInt8] {
        guard o.count >= 2 else { return tlv(0x06, []) }
        var out: [UInt8] = [UInt8(o[0] * 40 + o[1])]
        for var c in o.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(c & 0x7F)]
            c >>= 7
            while c > 0 { chunk.insert(UInt8(c & 0x7F) | 0x80, at: 0); c >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }

    /// Lee un TLV en `b[i...]`: (tag, inicio del contenido, longitud).
    static func read(_ b: [UInt8], _ i: Int) -> (tag: UInt8, start: Int, len: Int)? {
        guard i + 1 < b.count else { return nil }
        let tag = b[i]
        var len = Int(b[i + 1]), start = i + 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, start + n <= b.count else { return nil }
            len = 0
            for k in 0..<n { len = len << 8 | Int(b[start + k]) }
            start += n
        }
        guard start + len <= b.count else { return nil }
        return (tag, start, len)
    }

    static func decodeInt(_ b: ArraySlice<UInt8>) -> Int64 {
        guard let first = b.first else { return 0 }
        var v: Int64 = first & 0x80 != 0 ? -1 : 0
        for x in b { v = v << 8 | Int64(x) }
        return v
    }

    static func decodeUnsigned(_ b: ArraySlice<UInt8>) -> UInt64 { b.reduce(0) { $0 << 8 | UInt64($1) } }

    static func decodeOID(_ b: ArraySlice<UInt8>) -> OID {
        guard let first = b.first else { return [] }
        var out: OID = [UInt32(first) / 40, UInt32(first) % 40]
        var acc: UInt32 = 0
        for x in b.dropFirst() {
            acc = acc << 7 | UInt32(x & 0x7F)
            if x & 0x80 == 0 { out.append(acc); acc = 0 }
        }
        return out
    }
}

enum SNMPValue: Hashable {
    case int(Int64), unsigned(UInt64), bytes([UInt8]), oid(OID), null, missing

    var string: String? {
        guard case .bytes(let b) = self else { return nil }
        let s = (String(bytes: b, encoding: .utf8) ?? String(bytes: b, encoding: .isoLatin1) ?? "")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return s.isEmpty ? nil : s
    }

    var int: Int64? {
        switch self {
        case .int(let v): return v
        case .unsigned(let v): return Int64(clamping: v)
        default: return nil
        }
    }
}

struct VarBind: Hashable { let oid: OID; let value: SNMPValue }

enum SNMPPacket {
    static let get: UInt8 = 0xA0, getNext: UInt8 = 0xA1, response: UInt8 = 0xA2

    static func request(_ pdu: UInt8, community: String, id: Int32, oids: [OID]) -> [UInt8] {
        let binds = oids.map { BER.tlv(0x30, BER.objectID($0) + [0x05, 0x00]) }.flatMap { $0 }
        let body = BER.integer(Int64(id)) + BER.integer(0) + BER.integer(0) + BER.tlv(0x30, binds)
        return BER.tlv(0x30, BER.integer(1) + BER.octets(community) + BER.tlv(pdu, body)) // versión 1 = v2c
    }

    static func parse(_ b: [UInt8]) -> (id: Int32, error: Int, binds: [VarBind])? {
        guard let msg = BER.read(b, 0), msg.tag == 0x30,
              let ver = BER.read(b, msg.start), ver.tag == 0x02,
              let comm = BER.read(b, ver.start + ver.len), comm.tag == 0x04,
              let pdu = BER.read(b, comm.start + comm.len), pdu.tag == response,
              let rid = BER.read(b, pdu.start), rid.tag == 0x02,
              let err = BER.read(b, rid.start + rid.len),
              let idx = BER.read(b, err.start + err.len),
              let list = BER.read(b, idx.start + idx.len), list.tag == 0x30
        else { return nil }
        var binds: [VarBind] = []
        var i = list.start
        let end = list.start + list.len
        while i < end, let vb = BER.read(b, i), vb.tag == 0x30 {
            if let o = BER.read(b, vb.start), o.tag == 0x06, let v = BER.read(b, o.start + o.len) {
                let content = b[v.start..<(v.start + v.len)]
                let value: SNMPValue
                switch v.tag {
                case 0x02: value = .int(BER.decodeInt(content))
                case 0x04, 0x40, 0x44: value = .bytes(Array(content))
                case 0x06: value = .oid(BER.decodeOID(content))
                case 0x41, 0x42, 0x43, 0x46: value = .unsigned(BER.decodeUnsigned(content))
                case 0x05: value = .null
                default: value = .missing // noSuchObject / noSuchInstance / endOfMibView
                }
                binds.append(VarBind(oid: BER.decodeOID(b[o.start..<(o.start + o.len)]), value: value))
            }
            i = vb.start + vb.len
        }
        return (Int32(truncatingIfNeeded: BER.decodeInt(b[rid.start..<(rid.start + rid.len)])),
                Int(BER.decodeInt(b[err.start..<(err.start + err.len)])), binds)
    }
}

// MARK: - Sesión con un equipo (bloqueante)

final class SNMPSession {
    let ip: UInt32
    let community: String
    private let fd: Int32
    private var nextID: Int32 = Int32.random(in: 1...100_000)

    init?(ip: UInt32, community: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        setNonBlocking(fd)
        self.fd = fd; self.ip = ip; self.community = community
    }

    deinit { close(fd) }

    private func exchange(_ pdu: UInt8, _ oids: [OID], timeoutMs: Int32 = 1200, retries: Int = 1) -> [VarBind]? {
        nextID &+= 1
        let id = nextID
        let packet = SNMPPacket.request(pdu, community: community, id: id, oids: oids)
        var buf = [UInt8](repeating: 0, count: 65_536)
        for _ in 0...retries {
            var a = makeSockaddr(ip, port: 161)
            _ = withSockaddr(&a) { sendto(fd, packet, packet.count, 0, $0, $1) }
            let deadline = monotonicNow() + Double(timeoutMs) / 1000
            while monotonicNow() < deadline {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, Int32(max(1, (deadline - monotonicNow()) * 1000))) > 0 else { break }
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0, let r = SNMPPacket.parse(Array(buf[0..<n])), r.id == id else { continue }
                return r.error == 0 ? r.binds : nil
            }
        }
        return nil
    }

    func get(_ oids: [OID]) -> [OID: SNMPValue]? {
        guard let binds = exchange(SNMPPacket.get, oids) else { return nil }
        return Dictionary(binds.map { ($0.oid, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// Recorre una rama con GETNEXT. Devuelve [sufijo tras el prefijo: valor].
    func walk(_ prefix: OID, limit: Int = 64) -> [(OID, SNMPValue)] {
        var out: [(OID, SNMPValue)] = []
        var current = prefix
        for _ in 0..<limit {
            guard let vb = exchange(SNMPPacket.getNext, [current])?.first,
                  vb.oid.count > prefix.count, Array(vb.oid.prefix(prefix.count)) == prefix,
                  vb.value != .missing, vb.oid != current else { break }
            out.append((Array(vb.oid.dropFirst(prefix.count)), vb.value))
            current = vb.oid
        }
        return out
    }
}

// MARK: - Identificación masiva (sysName, sysDescr, modelo)

struct SNMPInfo: Hashable {
    var name: String?
    var descr: String?
    var model: String?      // hrDeviceDescr.1
    var community: String
    var isPrinter: Bool
}

enum SNMPIdentify {
    static let sysDescr = oid("1.3.6.1.2.1.1.1.0")
    static let sysName = oid("1.3.6.1.2.1.1.5.0")
    static let hrDeviceDescr1 = oid("1.3.6.1.2.1.25.3.2.1.3.1")
    static let prtGeneralSerial = oid("1.3.6.1.2.1.43.5.1.1.17.1") // solo existe en impresoras

    /// Una consulta GET por equipo y comunidad; las respuestas se asocian por IP de origen.
    static func run(_ ips: [UInt32], communities: [String], cancel: CancelFlag, onInfo: (UInt32, SNMPInfo) -> Void) {
        guard !ips.isEmpty, !communities.isEmpty else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        setNonBlocking(fd)
        var rcv: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        let wanted = Set(ips)
        var done = Set<UInt32>()
        var buf = [UInt8](repeating: 0, count: 65_536)

        func pump(until deadline: Double, community: String) {
            while monotonicNow() < deadline, !cancel.isCancelled {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&p, 1, 25)
                while true {
                    var from = sockaddr_in()
                    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &from) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                    }
                    if n <= 0 { break }
                    let src = UInt32(bigEndian: from.sin_addr.s_addr)
                    guard wanted.contains(src), !done.contains(src),
                          let r = SNMPPacket.parse(Array(buf[0..<n])), r.error == 0 else { continue }
                    let values = Dictionary(r.binds.map { ($0.oid, $0.value) }, uniquingKeysWith: { a, _ in a })
                    done.insert(src)
                    onInfo(src, SNMPInfo(name: values[sysName]?.string, descr: values[sysDescr]?.string,
                                         model: values[hrDeviceDescr1]?.string, community: community,
                                         isPrinter: values[prtGeneralSerial].map { $0 != .missing && $0 != .null } ?? false))
                }
            }
        }

        for community in communities {
            for pass in 0..<2 {
                for (i, ip) in ips.enumerated() where !done.contains(ip) {
                    if cancel.isCancelled { return }
                    let pkt = SNMPPacket.request(SNMPPacket.get, community: community, id: Int32(i),
                                                 oids: [sysDescr, sysName, hrDeviceDescr1, prtGeneralSerial])
                    var a = makeSockaddr(ip, port: 161)
                    _ = withSockaddr(&a) { sendto(fd, pkt, pkt.count, 0, $0, $1) }
                    if i % 16 == 15 { pump(until: monotonicNow() + 0.004, community: community) }
                }
                pump(until: monotonicNow() + (pass == 0 ? 0.6 : 1.0), community: community)
            }
        }
    }
}

// MARK: - Estado de impresoras (Printer-MIB, RFC 3805)

struct PrinterSupply: Hashable {
    var description: String
    var type: Int
    var level: Int
    var max: Int
    var colorant: String?

    /// Porcentaje restante; nil si la impresora no lo informa.
    var percent: Int? { level >= 0 && max > 0 ? Swift.min(100, level * 100 / max) : nil }

    var isWaste: Bool { [4, 8].contains(type) }   // depósito de tóner/tinta residual: se llena, no se gasta

    var levelText: String {
        if let p = percent { return "\(p) %" }
        switch level {
        case -3: return isWaste ? "OK" : "Queda"
        case -2: return "Desconocido"
        default: return "—"
        }
    }

    var typeName: String {
        switch type {
        case 3, 21: return "Tóner"
        case 4: return "Depósito de tóner residual"
        case 5, 6: return "Tinta"
        case 8: return "Depósito de tinta residual"
        case 9: return "Tambor"
        case 10: return "Revelador"
        case 15: return "Fusor"
        case 16: return "Kit de mantenimiento"
        default: return "Consumible"
        }
    }
}

struct PrinterStatus: Hashable {
    var model: String?
    var serial: String?
    var pageCount: Int?
    var state: Int?            // hrPrinterStatus
    var errors: [String] = []
    var display: [String] = []
    var supplies: [PrinterSupply] = []
    var updated = Date()

    var stateText: String {
        switch state {
        case 3: return "En reposo"
        case 4: return "Imprimiendo"
        case 5: return "Calentando"
        case 1: return "Requiere atención"
        default: return "Estado desconocido"
        }
    }

    /// Nivel más bajo entre los consumibles que se gastan (tóner, tinta, tambor…).
    var lowestPercent: Int? { supplies.filter { !$0.isWaste }.compactMap(\.percent).min() }
    var needsAttention: Bool { !errors.isEmpty || (lowestPercent ?? 100) <= 15 }

    static let errorBits = [
        "Poco papel", "Sin papel", "Poco tóner", "Sin tóner", "Puerta abierta", "Atasco de papel", "Fuera de línea",
        "Requiere servicio técnico", "Falta una bandeja de entrada", "Falta la bandeja de salida",
        "Falta un consumible", "Bandeja de salida casi llena", "Bandeja de salida llena", "Bandeja de entrada vacía",
        "Mantenimiento preventivo vencido",
    ]

    static func decodeErrors(_ bytes: [UInt8]) -> [String] {
        var out: [String] = []
        for (i, name) in errorBits.enumerated() {
            let byte = i / 8, bit = 7 - i % 8
            if byte < bytes.count, bytes[byte] >> bit & 1 == 1 { out.append(name) }
        }
        return out
    }
}

enum PrinterProbe {
    static func fetch(ip: UInt32, community: String) -> PrinterStatus? {
        guard let s = SNMPSession(ip: ip, community: community) else { return nil }
        let base = "1.3.6.1.2.1."
        guard let g = s.get([oid(base + "25.3.2.1.3.1"), oid(base + "43.5.1.1.17.1"), oid(base + "43.10.2.1.4.1.1"),
                             oid(base + "25.3.5.1.1.1"), oid(base + "25.3.5.1.2.1")]) else { return nil }
        var st = PrinterStatus()
        st.model = g[oid(base + "25.3.2.1.3.1")]?.string
        st.serial = g[oid(base + "43.5.1.1.17.1")]?.string
        st.pageCount = g[oid(base + "43.10.2.1.4.1.1")]?.int.map { Int($0) }
        st.state = g[oid(base + "25.3.5.1.1.1")]?.int.map { Int($0) }
        if case .bytes(let b)? = g[oid(base + "25.3.5.1.2.1")] { st.errors = PrinterStatus.decodeErrors(b) }

        func column(_ c: Int) -> [OID: SNMPValue] {
            Dictionary(s.walk(oid(base + "43.11.1.1.\(c)")).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        }
        let descr = column(6), types = column(5), max = column(8), level = column(9), colorantIdx = column(3)
        let colorants = Dictionary(s.walk(oid(base + "43.12.1.1.4")).map { ($0.0, $0.1.string ?? "") }, uniquingKeysWith: { a, _ in a })
        st.supplies = descr.keys.sorted { $0.lexicographicallyPrecedes($1) }.compactMap { idx in
            guard let d = descr[idx]?.string else { return nil }
            var colorant: String?
            if let ci = colorantIdx[idx]?.int, ci > 0, let first = idx.first {
                colorant = colorants[[first, UInt32(ci)]].flatMap { $0.isEmpty ? nil : $0 }
            }
            return PrinterSupply(description: d, type: Int(types[idx]?.int ?? 1), level: Int(level[idx]?.int ?? -2),
                                 max: Int(max[idx]?.int ?? -2), colorant: colorant)
        }
        st.display = s.walk(oid(base + "43.16.5.1.2"), limit: 8).compactMap { $0.1.string }
        st.updated = Date()
        return st
    }
}
