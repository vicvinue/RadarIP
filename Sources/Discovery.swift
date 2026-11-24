import Foundation
import Darwin

// MARK: - Bonjour: servicios que anuncia cada equipo (consulta mDNS «legacy unicast»)

struct BonjourInfo: Hashable {
    var services: Set<String> = []     // tipos, p. ej. "_ipp._tcp"
    var name: String?                  // nombre de instancia más representativo
    var model: String?                 // de los TXT: ty, md, model, usb_MDL
}

enum Bonjour {
    /// Tipos consultados → nombre legible.
    static let types: [(String, String)] = [
        ("_airplay._tcp", "AirPlay"), ("_raop._tcp", "AirPlay audio"), ("_googlecast._tcp", "Chromecast"),
        ("_ipp._tcp", "Impresora IPP"), ("_ipps._tcp", "Impresora IPPS"), ("_printer._tcp", "Impresora LPD"),
        ("_pdl-datastream._tcp", "Impresión directa"), ("_uscan._tcp", "Escáner"), ("_scanner._tcp", "Escáner"),
        ("_smb._tcp", "Archivos SMB"), ("_afpovertcp._tcp", "Archivos AFP"), ("_adisk._tcp", "Time Machine"),
        ("_ssh._tcp", "SSH"), ("_rfb._tcp", "Pantalla compartida"), ("_companion-link._tcp", "Dispositivo Apple"),
        ("_device-info._tcp", "Info de dispositivo"), ("_hap._tcp", "HomeKit"), ("_matter._tcp", "Matter"),
        ("_spotify-connect._tcp", "Spotify Connect"), ("_sonos._tcp", "Sonos"), ("_amzn-wplay._tcp", "Fire TV"),
        ("_dhnap._tcp", "Cámara Dahua"), ("_http._tcp", "Web"), ("_https._tcp", "Web segura"),
        ("_workstation._tcp", "Equipo"), ("_nvstream._tcp", "NVIDIA GameStream"), ("_androidtvremote2._tcp", "Android TV"),
    ]

    static func label(_ type: String) -> String { types.first { $0.0 == type }?.1 ?? type }

    /// Prioridad para elegir el nombre de instancia que se mostrará.
    private static let namePriority = ["_googlecast._tcp", "_airplay._tcp", "_androidtvremote2._tcp", "_ipp._tcp",
                                       "_printer._tcp", "_uscan._tcp", "_companion-link._tcp", "_dhnap._tcp", "_smb._tcp",
                                       "_raop._tcp", "_device-info._tcp", "_http._tcp"]

    static func query(id: UInt16) -> [UInt8] {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0, 0, UInt8(types.count), 0, 0, 0, 0, 0, 0]
        for (t, _) in types {
            for label in (t + ".local").split(separator: ".") { q.append(UInt8(label.utf8.count)); q += Array(label.utf8) }
            q += [0, 0x00, 0x0C, 0x00, 0x01]
        }
        return q
    }

    /// Envía la consulta al grupo multicast desde un puerto normal: cada equipo responde por unicast
    /// desde su propia IP, así que la respuesta se asocia al equipo sin resolver nombres.
    static func browse(wanted: Set<UInt32>, timeout: Double = 2.0, cancel: CancelFlag, onInfo: (UInt32, BonjourInfo) -> Void) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        setNonBlocking(fd)
        var ttl: UInt8 = 255
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var rcv: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        var infos: [UInt32: BonjourInfo] = [:]
        var buf = [UInt8](repeating: 0, count: 9000)
        let q = query(id: UInt16.random(in: 1...0xFFFE))
        let deadline = monotonicNow() + timeout
        var nextSend = 0.0
        var sends = 0
        while monotonicNow() < deadline, !cancel.isCancelled {
            if sends < 3, monotonicNow() >= nextSend {
                var g = makeSockaddr(0xE000_00FB, port: 5353)
                _ = withSockaddr(&g) { sendto(fd, q, q.count, 0, $0, $1) }
                sends += 1
                nextSend = monotonicNow() + 0.5
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 50)
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n <= 0 { break }
                let src = UInt32(bigEndian: from.sin_addr.s_addr)
                guard wanted.contains(src) else { continue }
                merge(into: &infos[src, default: BonjourInfo()], Array(buf[0..<n]))
            }
        }
        for (ip, info) in infos where !info.services.isEmpty { onInfo(ip, info) }
    }

    static func merge(into info: inout BonjourInfo, _ packet: [UInt8]) {
        let known = Set(types.map(\.0))
        var instances: [String: String] = [:]   // tipo → nombre de instancia
        var txt: [String: [String: String]] = [:] // instancia completa → TXT
        for r in DNSPacket.records(packet) {
            let owner = r.name.lowercased()
            if r.type == 12, let (target, _) = DNSPacket.readName(packet, r.rdata) {
                let type = owner.replacingOccurrences(of: ".local", with: "")
                guard known.contains(type) else { continue }
                info.services.insert(type)
                let instance = target.hasSuffix("." + r.name) ? String(target.dropLast(r.name.count + 1))
                    : String(target.split(separator: ".").first ?? "")
                if instances[type] == nil { instances[type] = instance }
            } else if r.type == 16 {
                txt[r.name.lowercased(), default: [:]].merge(DNSPacket.txt(packet, r.rdata, r.rdlen)) { a, _ in a }
            }
        }
        // "fn" y "md" solo significan nombre y modelo en Chromecast (en AirPlay, "md" son tipos de metadatos).
        let castTXT = txt.filter { $0.key.contains("._googlecast.") }.values.reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
        let otherTXT = txt.filter { !$0.key.contains("._googlecast.") }.values.reduce(into: [String: String]()) { $0.merge($1) { a, _ in a } }
        if info.name == nil {
            if let fn = castTXT["fn"], !fn.isEmpty { info.name = fn }
            else if let t = namePriority.first(where: { instances[$0] != nil }), var inst = instances[t] {
                if t == "_raop._tcp", let at = inst.firstIndex(of: "@") { inst = String(inst[inst.index(after: at)...]) }
                info.name = inst
            }
        }
        if info.model == nil {
            let candidates = [otherTXT["ty"], castTXT["md"], otherTXT["usb_mdl"], otherTXT["model"], otherTXT["product"]]
            info.model = candidates.compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: "() ")) }
                .first { !$0.isEmpty }
        }
    }
}

extension DNSPacket {
    struct Record { let name: String; let type: Int; let rdata: Int; let rdlen: Int }

    /// Todos los registros (respuestas, autoridad y adicionales) de un paquete DNS.
    static func records(_ b: [UInt8]) -> [Record] {
        guard b.count >= 12 else { return [] }
        let qd = Int(b[4]) << 8 | Int(b[5])
        let rr = (Int(b[6]) << 8 | Int(b[7])) + (Int(b[8]) << 8 | Int(b[9])) + (Int(b[10]) << 8 | Int(b[11]))
        var off = 12
        for _ in 0..<qd {
            guard let (_, e) = readName(b, off) else { return [] }
            off = e + 4
        }
        var out: [Record] = []
        for _ in 0..<rr {
            guard let (name, e) = readName(b, off), e + 10 <= b.count else { break }
            let type = Int(b[e]) << 8 | Int(b[e + 1])
            let rdlen = Int(b[e + 8]) << 8 | Int(b[e + 9])
            guard e + 10 + rdlen <= b.count else { break }
            out.append(Record(name: name, type: type, rdata: e + 10, rdlen: rdlen))
            off = e + 10 + rdlen
        }
        return out
    }

    static func txt(_ b: [UInt8], _ start: Int, _ len: Int) -> [String: String] {
        var out: [String: String] = [:]
        var i = start
        while i < start + len {
            let l = Int(b[i])
            guard i + 1 + l <= start + len else { break }
            let s = String(decoding: b[(i + 1)..<(i + 1 + l)], as: UTF8.self)
            if let eq = s.firstIndex(of: "=") {
                out[s[..<eq].lowercased()] = String(s[s.index(after: eq)...])
            }
            i += 1 + l
        }
        return out
    }
}

// MARK: - UPnP / SSDP

struct UPnPInfo: Hashable {
    var name: String?
    var manufacturer: String?
    var model: String?
}

enum SSDP {
    /// M-SEARCH multicast; devuelve la primera URL de descripción de cada IP que responde.
    static func discover(wanted: Set<UInt32>, timeout: Double = 2.5, cancel: CancelFlag) -> [UInt32: URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        setNonBlocking(fd)
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        let msg = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\nUSER-AGENT: macOS UPnP/1.1 RadarIP/1.0\r\n\r\n".utf8)
        var out: [UInt32: URL] = [:]
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = monotonicNow() + timeout
        var sends = 0, nextSend = 0.0
        while monotonicNow() < deadline, !cancel.isCancelled {
            if sends < 2, monotonicNow() >= nextSend {
                var g = makeSockaddr(0xEFFF_FFFA, port: 1900) // 239.255.255.250
                _ = withSockaddr(&g) { sendto(fd, msg, msg.count, 0, $0, $1) }
                sends += 1
                nextSend = monotonicNow() + 0.4
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 50)
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n <= 0 { break }
                let src = UInt32(bigEndian: from.sin_addr.s_addr)
                guard wanted.contains(src), out[src] == nil,
                      let loc = header("location", in: String(decoding: buf[0..<n], as: UTF8.self)),
                      let url = URL(string: loc), url.host == src.ipString else { continue }
                out[src] = url
            }
        }
        return out
    }

    static func header(_ name: String, in response: String) -> String? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func describe(_ url: URL) async -> UPnPInfo? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, _) = try? await HTTPProbe.session.data(for: req) else { return nil }
        return parse(String(decoding: data.prefix(65_536), as: UTF8.self))
    }

    static func parse(_ xml: String) -> UPnPInfo? {
        func tag(_ t: String) -> String? {
            guard let open = xml.range(of: "<\(t)>"), let close = xml.range(of: "</\(t)>", range: open.upperBound..<xml.endIndex)
            else { return nil }
            let v = xml[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        // Windows publica el servicio de Windows Media Player: es software, no el modelo del equipo.
        let software = ["windows media", "media player", "dlna media server"]
        let isSoftware = tag("modelName").map { m in software.contains { m.lowercased().contains($0) } } ?? false
        let model = isSoftware ? [] : [tag("modelName"), tag("modelNumber")].compactMap { $0 }
        let info = UPnPInfo(name: tag("friendlyName"), manufacturer: tag("manufacturer"),
                            model: model.isEmpty ? nil : (model.count == 2 && !model[0].contains(model[1]) ? model.joined(separator: " ") : model[0]))
        return info.name == nil && info.model == nil ? nil : info
    }
}
