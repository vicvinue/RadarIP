import Foundation
import Darwin
import SystemConfiguration

// MARK: - Utilidades IPv4

extension UInt32 {
    /// Representa una IPv4 en orden de host como texto "a.b.c.d".
    var ipString: String { "\(self >> 24 & 255).\(self >> 16 & 255).\(self >> 8 & 255).\(self & 255)" }
}

func ipFromString(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var v: UInt32 = 0
    for p in parts {
        guard let n = UInt32(p), n < 256 else { return nil }
        v = v << 8 | n
    }
    return v
}

func makeSockaddr(_ ip: UInt32, port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr = in_addr(s_addr: ip.bigEndian)
    return a
}

func withSockaddr<T>(_ a: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &a) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
}

func monotonicNow() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

func raiseFileLimit() {
    var rl = rlimit()
    if getrlimit(RLIMIT_NOFILE, &rl) == 0 {
        rl.rlim_cur = min(rl.rlim_max, 8192)
        setrlimit(RLIMIT_NOFILE, &rl)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

func formatMAC(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
}

func macBytes(_ mac: String) -> [UInt8]? {
    let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
    guard parts.count == 6 else { return nil }
    var out: [UInt8] = []
    for p in parts {
        guard let b = UInt8(p, radix: 16) else { return nil }
        out.append(b)
    }
    return out
}

// MARK: - Rangos

enum RangeError: LocalizedError {
    case empty, invalid(String), tooLarge(Int)
    var errorDescription: String? {
        switch self {
        case .empty: return "Escribe un rango de IP, por ejemplo 192.168.1.1-254"
        case .invalid(let t): return "No entiendo «\(t)». Formatos válidos: 192.168.1.1-254, 192.168.1.1-192.168.1.50, 192.168.1.0/24"
        case .tooLarge(let n): return "El rango tiene \(n) direcciones; el máximo es \(RangeParser.maxHosts)."
        }
    }
}

enum RangeParser {
    static let maxHosts = 65_536

    static func parse(_ text: String) throws -> [UInt32] {
        let normalized = text.replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
        let tokens = normalized.split(whereSeparator: { ",; \n\t".contains($0) }).map(String.init)
        guard !tokens.isEmpty else { throw RangeError.empty }
        var set = Set<UInt32>()
        for t in tokens {
            if let slash = t.firstIndex(of: "/") {
                guard let base = ipFromString(String(t[..<slash])),
                      let bits = Int(t[t.index(after: slash)...]), (0...32).contains(bits)
                else { throw RangeError.invalid(t) }
                let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
                let net = base & mask, bc = net | ~mask
                let count = Int(bc - net) + 1
                if count > maxHosts + 2 { throw RangeError.tooLarge(count) }
                if bits >= 31 {
                    for v in net...bc { set.insert(v) }
                } else {
                    for v in (net + 1)..<bc { set.insert(v) }
                }
            } else if let dash = t.firstIndex(of: "-") {
                let l = String(t[..<dash]), r = String(t[t.index(after: dash)...])
                guard let a = ipFromString(l) else { throw RangeError.invalid(t) }
                let b: UInt32
                if let full = ipFromString(r) {
                    b = full
                } else if let last = UInt32(r), last < 256 {
                    b = (a & 0xFFFF_FF00) | last
                } else { throw RangeError.invalid(t) }
                guard b >= a else { throw RangeError.invalid(t) }
                if Int(b - a) + 1 > maxHosts { throw RangeError.tooLarge(Int(b - a) + 1) }
                for v in a...b { set.insert(v) }
            } else {
                guard let a = ipFromString(t) else { throw RangeError.invalid(t) }
                set.insert(a)
            }
            if set.count > maxHosts { throw RangeError.tooLarge(set.count) }
        }
        return set.sorted()
    }
}

// MARK: - Interfaces de red

struct NetInterface: Identifiable, Hashable {
    let id: String          // nombre BSD (en0…)
    let displayName: String // "Wi-Fi", "Ethernet"…
    let ip: UInt32
    let mask: UInt32
    let mac: String?

    var prefix: Int { mask.nonzeroBitCount }
    var broadcast: UInt32 { ip | ~mask }

    /// Rango sugerido; en redes mayores que /22 se limita a la /24 propia.
    var suggestedRange: String {
        if prefix >= 31 { return ip.ipString }
        let m: UInt32 = prefix < 22 ? 0xFFFF_FF00 : mask
        let net = ip & m, bc = net | ~m
        return "\((net + 1).ipString)-\((bc - 1).ipString)"
    }

    var label: String { "\(displayName) · \(ip.ipString)/\(prefix)" }

    func contains(_ other: UInt32) -> Bool { other & mask == ip & mask }
}

enum NetInfo {
    static func interfaces() -> [NetInterface] {
        var names: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                if let b = SCNetworkInterfaceGetBSDName(i) as String?,
                   let n = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                    names[b] = n
                }
            }
        }
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }

        var macs: [String: String] = [:]
        var v4: [(String, UInt32, UInt32)] = []
        var cursor = ifap
        while let cur = cursor {
            let ifa = cur.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            if addr.pointee.sa_family == UInt8(AF_LINK) {
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    let d = dl.pointee
                    guard d.sdl_alen == 6, let off = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return }
                    let base = UnsafeRawPointer(dl).advanced(by: off + Int(d.sdl_nlen))
                    let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                    // macOS devuelve 02:00:00:00:00:00 a procesos sin permiso de red local.
                    if bytes.contains(where: { $0 != 0 }), bytes != [2, 0, 0, 0, 0, 0] { macs[name] = formatMAC(bytes) }
                }
            } else if addr.pointee.sa_family == UInt8(AF_INET),
                      flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                      let nm = ifa.ifa_netmask {
                let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if mask != 0xFFFF_FFFF { v4.append((name, ip, mask)) }
            }
        }
        return v4.map { NetInterface(id: $0.0, displayName: names[$0.0] ?? $0.0, ip: $0.1, mask: $0.2, mac: macs[$0.0]) }
    }

    /// Interfaz principal y router según la configuración global del sistema.
    static func primary() -> (interface: String?, router: UInt32?) {
        guard let store = SCDynamicStoreCreate(nil, "RadarIP" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (dict["PrimaryInterface"] as? String, (dict["Router"] as? String).flatMap(ipFromString))
    }

    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName
    }
}

// MARK: - Tabla ARP

struct ARPEntry {
    let mac: String
    let fresh: Bool   // entrada confirmada recientemente (no "expired")
    let iface: String
}

enum ARP {
    /// Lee la tabla de vecinos IPv4. Primero vía sysctl en el propio proceso (lo único que macOS
    /// permite a una app con permiso de Red local); si falla, recurre a `arp -anl`.
    static func table() -> [UInt32: ARPEntry] {
        if let t = sysctlTable(), !t.isEmpty { return t }
        return commandTable()
    }

    /// NET_RT_DUMPX_FLAGS + rt_msghdr_ext (como `arp -l`): incluye la caducidad de la confirmación
    /// de alcanzabilidad, que distingue entradas recientes de entradas obsoletas.
    static func sysctlTable() -> [UInt32: ARPEntry]? {
        let netRtDumpxFlags: Int32 = 9
        let extHeader = 136 // sizeof(struct rt_msghdr_ext): rt_msghdr (92+4 reservado) + rt_reach_info (40)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, netRtDumpxFlags, RTF_LLINFO]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return nil }
        guard len > 0 else { return [:] }
        len += 8192
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        var tv = timeval()
        gettimeofday(&tv, nil)
        let now = UInt64(tv.tv_sec)
        func u16(_ o: Int) -> Int { Int(buf[o]) | Int(buf[o + 1]) << 8 }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(buf[o + $1]) << (8 * UInt64($1)) } }

        var out: [UInt32: ARPEntry] = [:]
        var off = 0
        while off + extHeader + 16 <= len {
            let msglen = u16(off)
            guard msglen > 0, off + msglen <= len else { break }
            defer { off += msglen }
            let sa = off + extHeader
            // Primer sockaddr: sockaddr_inarp (len 16, AF_INET). Si no cuadra, el formato cambió.
            guard buf[sa + 1] == UInt8(AF_INET), buf[sa] >= 8 else { return nil }
            let ip = UInt32(buf[sa + 4]) << 24 | UInt32(buf[sa + 5]) << 16 | UInt32(buf[sa + 6]) << 8 | UInt32(buf[sa + 7])
            let dl = sa + (Int(buf[sa]) + 3) & ~3
            guard dl + 8 <= off + msglen, buf[dl + 1] == UInt8(AF_LINK) else { continue }
            let nlen = Int(buf[dl + 5]), alen = Int(buf[dl + 6])
            let macAt = dl + 8 + nlen
            guard alen == 6, macAt + 6 <= off + msglen else { continue }
            let mac = Array(buf[macAt..<(macAt + 6)])
            guard mac != [255, 255, 255, 255, 255, 255], mac.contains(where: { $0 != 0 }) else { continue }
            let sndExpire = u64(off + 96 + 8) // rtm_ri.ri_snd_expire (hora de calendario)
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            let ifIndex = UInt32(u16(dl + 2))
            let iface = if_indextoname(ifIndex, &name) != nil ? String(cString: name) : ""
            out[ip] = ARPEntry(mac: formatMAC(mac), fresh: sndExpire == 0 || sndExpire > now, iface: iface)
        }
        return out
    }

    static func commandTable() -> [UInt32: ARPEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        p.arguments = ["-anl"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [UInt32: ARPEntry] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count >= 5, let ip = ipFromString(f[0]),
                  let b = macBytes(f[1]), b != [255, 255, 255, 255, 255, 255], b.contains(where: { $0 != 0 })
            else { continue }
            out[ip] = ARPEntry(mac: formatMAC(b), fresh: f[2] != "expired", iface: f[4])
        }
        return out
    }
}

// MARK: - Wake-on-LAN

enum WakeOnLAN {
    @discardableResult
    static func send(mac: String, broadcasts: [UInt32]) -> Bool {
        guard let m = macBytes(mac) else { return false }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += m }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        var ok = false
        for b in Set(broadcasts + [0xFFFF_FFFF]) {
            for port: UInt16 in [9, 7] {
                var a = makeSockaddr(b, port: port)
                let n = withSockaddr(&a) { sendto(fd, packet, packet.count, 0, $0, $1) }
                if n == packet.count { ok = true }
            }
        }
        return ok
    }
}
