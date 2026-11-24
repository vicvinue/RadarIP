import Foundation
import Darwin

// MARK: - Barrido ICMP (ping) sin privilegios

enum ICMPSweep {
    /// Envía echo requests a todas las IPs (dos pasadas) y llama a `onReply` con la latencia en ms.
    /// Bloquea hasta `timeout` segundos tras el último envío. Devuelve false si no se pudo abrir el socket.
    @discardableResult
    static func run(_ ips: [UInt32], timeout: Double = 1.2, cancel: CancelFlag,
                    onReply: (UInt32, Double) -> Void) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var rcv: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd)

        let ident = UInt16.random(in: 1...0xFFFE)
        var index: [UInt32: Int] = [:]
        for (i, ip) in ips.enumerated() { index[ip] = i }
        var sentAt = [Double](repeating: 0, count: ips.count)
        var replied = [Bool](repeating: false, count: ips.count)
        var rbuf = [UInt8](repeating: 0, count: 2048)

        func drain() {
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &rbuf, rbuf.count, 0, $0, &len) }
                }
                if n <= 0 { return }
                // En macOS el datagrama trae la cabecera IP; en otros sistemas no.
                let off = rbuf[0] >> 4 == 4 ? Int(rbuf[0] & 0x0F) * 4 : 0
                guard n >= off + 8, rbuf[off] == 0 else { continue } // 0 = echo reply
                let src = UInt32(bigEndian: from.sin_addr.s_addr)
                guard let i = index[src], !replied[i] else { continue }
                replied[i] = true
                onReply(src, max(0, (monotonicNow() - sentAt[i]) * 1000))
            }
        }

        func wait(until deadline: Double) {
            while monotonicNow() < deadline, !cancel.isCancelled {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&p, 1, 20)
                drain()
            }
        }

        func send(_ i: Int, seq: UInt16) {
            var pkt = [UInt8](repeating: 0, count: 24)
            pkt[0] = 8 // echo request
            pkt[4] = UInt8(ident >> 8); pkt[5] = UInt8(ident & 0xFF)
            pkt[6] = UInt8(seq >> 8); pkt[7] = UInt8(seq & 0xFF)
            for k in 8..<pkt.count { pkt[k] = UInt8(k) }
            let ck = checksum(pkt)
            pkt[2] = UInt8(ck >> 8); pkt[3] = UInt8(ck & 0xFF)
            var a = makeSockaddr(ips[i], port: 0)
            sentAt[i] = monotonicNow()
            _ = withSockaddr(&a) { sendto(fd, pkt, pkt.count, 0, $0, $1) }
        }

        for pass in 0..<2 {
            for i in ips.indices where !replied[i] {
                if cancel.isCancelled { return true }
                send(i, seq: UInt16(truncatingIfNeeded: i &* 2 &+ pass))
                drain()
                if i % 16 == 15 { usleep(1000) }
            }
            wait(until: monotonicNow() + (pass == 0 ? 0.5 : timeout))
        }
        return true
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count { sum += UInt32(data[i]) << 8 | UInt32(data[i + 1]); i += 2 }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

// MARK: - Sondeo TCP masivo (connect no bloqueante)

enum TCPResult { case open, refused, failed }

enum TCPScan {
    static func run(_ targets: [(UInt32, UInt16)], timeout: Double, window: Int = 512, cancel: CancelFlag,
                    onResult: (UInt32, UInt16, TCPResult) -> Void) {
        struct Active { let fd: Int32; let ip: UInt32; let port: UInt16; let deadline: Double }
        var active: [Active] = []
        var next = 0
        while next < targets.count || !active.isEmpty {
            if cancel.isCancelled { active.forEach { close($0.fd) }; return }
            while active.count < window, next < targets.count {
                let (ip, port) = targets[next]
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                if fd < 0 { break } // sin descriptores libres: esperar a que se liberen
                next += 1
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var lg = linger(l_onoff: 1, l_linger: 0) // cierre con RST, sin TIME_WAIT
                setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, socklen_t(MemoryLayout<linger>.size))
                setNonBlocking(fd)
                var a = makeSockaddr(ip, port: port)
                let r = withSockaddr(&a) { connect(fd, $0, $1) }
                if r == 0 {
                    close(fd); onResult(ip, port, .open)
                } else if errno == EINPROGRESS {
                    active.append(Active(fd: fd, ip: ip, port: port, deadline: monotonicNow() + timeout))
                } else {
                    let e = errno
                    close(fd); onResult(ip, port, e == ECONNREFUSED ? .refused : .failed)
                }
            }
            if active.isEmpty { usleep(10_000); continue }
            var pfds = active.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            _ = poll(&pfds, nfds_t(pfds.count), 50)
            let now = monotonicNow()
            var keep: [Active] = []
            keep.reserveCapacity(active.count)
            for (k, a) in active.enumerated() {
                if pfds[k].revents != 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(a.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    close(a.fd)
                    onResult(a.ip, a.port, err == 0 ? .open : (err == ECONNREFUSED ? .refused : .failed))
                } else if now >= a.deadline {
                    close(a.fd)
                    onResult(a.ip, a.port, .failed)
                } else {
                    keep.append(a)
                }
            }
            active = keep
        }
    }
}

// MARK: - Nombres: mDNS (unicast) y NetBIOS

enum NameKind { case mdns, netbios }

struct NetBIOSInfo { var name: String?; var group: String?; var mac: String? }

enum NameProbe {
    /// Pregunta en paralelo a cada IP su nombre por mDNS (PTR inverso al puerto 5353) y NetBIOS (NBSTAT, puerto 137).
    static func run(_ ips: [UInt32], timeout: Double = 1.5, cancel: CancelFlag,
                    onMDNS: (UInt32, String) -> Void, onNetBIOS: (UInt32, NetBIOSInfo) -> Void) {
        guard !ips.isEmpty else { return }
        let mfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        let nfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        defer { if mfd >= 0 { close(mfd) }; if nfd >= 0 { close(nfd) } }
        guard mfd >= 0, nfd >= 0 else { return }
        for fd in [mfd, nfd] {
            setNonBlocking(fd)
            var rcv: Int32 = 1 << 20
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        }
        var ttl: UInt8 = 255
        setsockopt(mfd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        let mdnsGroup: UInt32 = 0xE000_00FB // 224.0.0.251
        let useMulticast = ips.count <= 1024
        let wanted = Set(ips)
        var gotM = Set<UInt32>(), gotN = Set<UInt32>()
        var buf = [UInt8](repeating: 0, count: 4096)

        func receive(_ fd: Int32, _ handle: (UInt32, [UInt8]) -> Void) {
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n <= 0 { return }
                let src = UInt32(bigEndian: from.sin_addr.s_addr)
                if wanted.contains(src) { handle(src, Array(buf[0..<n])) }
            }
        }
        func pump(until deadline: Double) {
            while monotonicNow() < deadline, !cancel.isCancelled {
                var p = [pollfd(fd: mfd, events: Int16(POLLIN), revents: 0), pollfd(fd: nfd, events: Int16(POLLIN), revents: 0)]
                _ = poll(&p, 2, 25)
                receive(mfd) { ip, data in
                    guard !gotM.contains(ip), let name = DNSPacket.firstPTR(data) else { return }
                    gotM.insert(ip); onMDNS(ip, name)
                }
                receive(nfd) { ip, data in
                    guard !gotN.contains(ip), let info = parseNBSTAT(data) else { return }
                    gotN.insert(ip); onNetBIOS(ip, info)
                }
            }
        }

        for pass in 0..<2 {
            for (i, ip) in ips.enumerated() {
                if cancel.isCancelled { return }
                let txid = UInt16(truncatingIfNeeded: i)
                if !gotM.contains(ip) {
                    let q = DNSPacket.ptrQuery(for: ip, id: txid)
                    var a = makeSockaddr(ip, port: 5353)
                    _ = withSockaddr(&a) { sendto(mfd, q, q.count, 0, $0, $1) }
                    if useMulticast {
                        var g = makeSockaddr(mdnsGroup, port: 5353)
                        _ = withSockaddr(&g) { sendto(mfd, q, q.count, 0, $0, $1) }
                    }
                }
                if !gotN.contains(ip) {
                    let q = nbstatQuery(id: txid)
                    var a = makeSockaddr(ip, port: 137)
                    _ = withSockaddr(&a) { sendto(nfd, q, q.count, 0, $0, $1) }
                }
                if i % 16 == 15 { pump(until: monotonicNow() + 0.004) }
            }
            pump(until: monotonicNow() + (pass == 0 ? 0.6 : timeout))
        }
    }

    static func nbstatQuery(id: UInt16) -> [UInt8] {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x20]
        let name: [UInt8] = [0x2A] + [UInt8](repeating: 0, count: 15) // "*"
        for c in name { q.append(0x41 + (c >> 4)); q.append(0x41 + (c & 0x0F)) }
        q += [0x00, 0x00, 0x21, 0x00, 0x01] // NBSTAT, IN
        return q
    }

    static func parseNBSTAT(_ b: [UInt8]) -> NetBIOSInfo? {
        guard b.count > 57, let (_, end) = DNSPacket.readName(b, 12) else { return nil }
        var off = end + 10 // type, class, ttl, rdlength
        guard off < b.count else { return nil }
        let count = Int(b[off]); off += 1
        var info = NetBIOSInfo()
        for k in 0..<count {
            let e = off + k * 18
            guard e + 18 <= b.count else { return info.name == nil ? nil : info }
            let raw = String(decoding: b[e..<(e + 15)].map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let suffix = b[e + 15]
            let group = b[e + 16] & 0x80 != 0
            guard suffix == 0x00, !raw.isEmpty else { continue }
            if group { info.group = info.group ?? raw } else { info.name = info.name ?? raw }
        }
        let m = off + count * 18
        if m + 6 <= b.count {
            let mac = Array(b[m..<(m + 6)])
            if mac.contains(where: { $0 != 0 }) { info.mac = formatMAC(mac) }
        }
        return info.name == nil && info.group == nil ? nil : info
    }
}

enum DNSPacket {
    static func ptrQuery(for ip: UInt32, id: UInt16) -> [UInt8] {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        let labels = ["\(ip & 255)", "\(ip >> 8 & 255)", "\(ip >> 16 & 255)", "\(ip >> 24 & 255)", "in-addr", "arpa"]
        for l in labels { q.append(UInt8(l.utf8.count)); q += Array(l.utf8) }
        q += [0, 0x00, 0x0C, 0x00, 0x01] // PTR, IN
        return q
    }

    static func readName(_ b: [UInt8], _ start: Int) -> (String, Int)? {
        var labels: [String] = []
        var i = start, end: Int?, jumps = 0
        while true {
            guard i < b.count else { return nil }
            let len = Int(b[i])
            if len == 0 { i += 1; break }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < b.count else { return nil }
                if end == nil { end = i + 2 }
                i = (len & 0x3F) << 8 | Int(b[i + 1])
                jumps += 1
                if jumps > 32 { return nil }
                continue
            }
            guard i + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        return (labels.joined(separator: "."), end ?? i)
    }

    static func firstPTR(_ b: [UInt8]) -> String? {
        guard b.count >= 12, b[2] & 0x80 != 0 else { return nil } // debe ser respuesta
        let qd = Int(b[4]) << 8 | Int(b[5])
        let rr = (Int(b[6]) << 8 | Int(b[7])) + (Int(b[8]) << 8 | Int(b[9])) + (Int(b[10]) << 8 | Int(b[11]))
        var off = 12
        for _ in 0..<qd {
            guard let (_, e) = readName(b, off) else { return nil }
            off = e + 4
        }
        for _ in 0..<rr {
            guard let (_, e) = readName(b, off), e + 10 <= b.count else { return nil }
            let type = Int(b[e]) << 8 | Int(b[e + 1])
            let rdlen = Int(b[e + 8]) << 8 | Int(b[e + 9])
            let rd = e + 10
            if type == 12, let (name, _) = readName(b, rd), !name.isEmpty { return name }
            off = rd + rdlen
        }
        return nil
    }
}

// MARK: - DNS inverso (sistema)

enum ReverseDNS {
    static func lookup(_ ips: [UInt32], timeout: Double = 3, cancel: CancelFlag, onName: @escaping (UInt32, String) -> Void) {
        let group = DispatchGroup()
        let limiter = DispatchSemaphore(value: 24)
        let lock = NSLock()
        let finished = CancelFlag()
        for ip in ips {
            if cancel.isCancelled { break }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                limiter.wait()
                defer { limiter.signal(); group.leave() }
                guard !cancel.isCancelled, let name = resolve(ip) else { return }
                lock.lock(); defer { lock.unlock() }
                if !finished.isCancelled { onName(ip, name) }
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        lock.lock(); finished.cancel(); lock.unlock()
    }

    static func resolve(_ ip: UInt32) -> String? {
        var a = makeSockaddr(ip, port: 0)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withSockaddr(&a) { getnameinfo($0, $1, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD) }
        guard r == 0 else { return nil }
        let s = String(cString: host).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return s.isEmpty || s == ip.ipString ? nil : s
    }
}

// MARK: - Título HTTP

final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum HTTPProbe {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 3
        c.timeoutIntervalForResource = 5
        c.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: c, delegate: TrustAllDelegate(), delegateQueue: nil)
    }()

    private static let titleRegex = try! NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: [.caseInsensitive])
    private static let realmRegex = try! NSRegularExpression(pattern: "realm=\"([^\"]*)\"", options: [.caseInsensitive])

    static func describe(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh) RadarIP", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        let html = String(decoding: data.prefix(131_072), as: UTF8.self)
        if let t = firstGroup(titleRegex, html).map(decodeEntities), !t.isEmpty { return t }
        if http.statusCode == 401, let auth = http.value(forHTTPHeaderField: "WWW-Authenticate"),
           let realm = firstGroup(realmRegex, auth), !realm.isEmpty { return realm }
        if let server = http.value(forHTTPHeaderField: "Server"), !server.isEmpty { return server }
        return nil
    }

    private static func firstGroup(_ re: NSRegularExpression, _ s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return s[r].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }
}
