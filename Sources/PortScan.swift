import Foundation
import Darwin
import SwiftUI

// MARK: - Catálogo de puertos

enum PortCatalog {
    static let names: [UInt16: String] = [
        7: "Echo", 20: "FTP-datos", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 37: "Time", 43: "Whois",
        53: "DNS", 67: "DHCP", 69: "TFTP", 79: "Finger", 80: "HTTP", 81: "HTTP-alt", 82: "HTTP-alt", 88: "Kerberos",
        102: "Siemens S7", 110: "POP3", 111: "RPC", 113: "Ident", 119: "NNTP", 123: "NTP", 135: "MS-RPC", 137: "NetBIOS-ns",
        139: "NetBIOS", 143: "IMAP", 161: "SNMP", 179: "BGP", 389: "LDAP", 427: "SLP", 443: "HTTPS", 445: "SMB",
        465: "SMTPS", 502: "Modbus", 515: "LPD", 548: "AFP", 554: "RTSP", 587: "SMTP-envío", 593: "RPC-HTTP",
        631: "IPP", 636: "LDAPS", 873: "rsync", 902: "VMware", 990: "FTPS", 993: "IMAPS", 995: "POP3S",
        1080: "SOCKS", 1194: "OpenVPN", 1433: "SQL Server", 1521: "Oracle", 1701: "L2TP", 1723: "PPTP",
        1883: "MQTT", 1900: "UPnP", 2000: "Cisco SCCP", 2049: "NFS", 2082: "cPanel", 2083: "cPanel SSL",
        2222: "SSH-alt", 2375: "Docker", 2376: "Docker TLS", 3000: "HTTP-dev", 3128: "Proxy", 3260: "iSCSI",
        3306: "MySQL", 3389: "RDP", 3478: "STUN", 3689: "DAAP", 4000: "HTTP-alt", 4443: "HTTPS-alt", 4840: "OPC UA",
        5000: "UPnP/Synology", 5001: "Synology HTTPS", 5060: "SIP", 5061: "SIP-TLS", 5222: "XMPP", 5353: "mDNS",
        5357: "WSD", 5432: "PostgreSQL", 5555: "ADB", 5672: "AMQP", 5800: "VNC-web", 5900: "VNC", 5901: "VNC-1",
        5985: "WinRM", 5986: "WinRM-TLS", 6000: "X11", 6379: "Redis", 6443: "Kubernetes", 6667: "IRC",
        7000: "AirPlay", 7070: "RTSP-alt", 7547: "TR-069", 8000: "HTTP-alt", 8008: "HTTP-alt", 8009: "AJP/Cast",
        8010: "HTTP-alt", 8080: "HTTP-proxy", 8081: "HTTP-alt", 8086: "InfluxDB", 8088: "HTTP-alt", 8090: "HTTP-alt",
        8123: "Home Assistant", 8291: "MikroTik Winbox", 8443: "HTTPS-alt", 8554: "RTSP-alt", 8728: "MikroTik API",
        8834: "Nessus", 8883: "MQTT-TLS", 8888: "HTTP-alt", 9000: "HTTP-alt", 9090: "HTTP-admin", 9091: "Transmission",
        9100: "Impresión RAW", 9200: "Elasticsearch", 9443: "HTTPS-alt", 10000: "Webmin", 10050: "Zabbix agent",
        11211: "Memcached", 27017: "MongoDB", 32400: "Plex", 37777: "Dahua DVR", 49152: "UPnP", 51820: "WireGuard",
        62078: "iOS sync",
    ]

    static let common: [UInt16] = names.keys.sorted()
    static let httpPorts: Set<UInt16> = [80, 81, 82, 3000, 4000, 5000, 7000, 8000, 8008, 8010, 8080, 8081, 8088, 8090, 8123, 8888, 9000, 9090, 9091, 32400]
    static let httpsPorts: Set<UInt16> = [443, 4443, 5001, 8443, 9443, 10000, 2083, 6443, 8834]

    static func name(_ port: UInt16) -> String? { names[port] }

    /// Interpreta "22, 80, 8000-8100".
    static func parse(_ text: String) -> [UInt16]? {
        var out = Set<UInt16>()
        for token in text.split(whereSeparator: { ", ;\n".contains($0) }) {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 1, let p = UInt16(parts[0]), p > 0 {
                out.insert(p)
            } else if parts.count == 2, let a = UInt16(parts[0]), let b = UInt16(parts[1]), a > 0, a <= b {
                for p in a...b { out.insert(p) }
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out.sorted()
    }
}

// MARK: - Captura de banners

enum BannerGrab {
    /// Puertos donde no se debe enviar nada: una impresora imprimiría el texto enviado.
    static let neverSend: Set<UInt16> = [515, 9100, 9101, 9102, 9103, 9104, 9105, 9106, 9107]
    static let tls: Set<UInt16> = PortCatalog.httpsPorts.union([465, 636, 990, 993, 995, 2376, 5061, 5986, 8883])

    static func grab(ip: UInt32, port: UInt16) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var lg = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &lg, socklen_t(MemoryLayout<linger>.size))
        setNonBlocking(fd)
        var a = makeSockaddr(ip, port: port)
        let r = withSockaddr(&a) { connect(fd, $0, $1) }
        if r != 0 {
            guard errno == EINPROGRESS else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, 2000) > 0 else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return nil }
        }
        // Muchos servicios saludan primero (SSH, FTP, SMTP, Telnet, POP3…).
        if let greeting = read(fd, waitMs: 1500), let s = summarize(greeting) { return s }
        guard !neverSend.contains(port), !tls.contains(port) else { return nil }
        let probe = "HEAD / HTTP/1.0\r\nHost: \(ip.ipString)\r\nUser-Agent: RadarIP\r\n\r\n"
        _ = probe.withCString { send(fd, $0, strlen($0), 0) }
        if let reply = read(fd, waitMs: 2000) { return summarize(reply) }
        return nil
    }

    private static func read(_ fd: Int32, waitMs: Int32) -> [UInt8]? {
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        var wait = waitMs
        while out.count < 8192 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, wait) > 0 else { break }
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            out += buf[0..<n]
            wait = 150 // tras el primer bloque, esperar poco por el resto
        }
        return out.isEmpty ? nil : out
    }

    static func summarize(_ bytes: [UInt8]) -> String? {
        // Respuesta HTTP: línea de estado + cabecera Server.
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix("HTTP/") {
            let lines = text.components(separatedBy: "\r\n")
            var parts = [lines[0]]
            if let server = lines.first(where: { $0.lowercased().hasPrefix("server:") }) {
                parts.append(server.dropFirst(7).trimmingCharacters(in: .whitespaces))
            }
            return parts.joined(separator: " · ")
        }
        // Texto genérico: quitar la negociación Telnet (IAC = 255) y quedarse con lo imprimible.
        var plain: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 255, i + 1 < bytes.count {
                let cmd = bytes[i + 1]
                if cmd == 250 { // subnegociación: hasta IAC SE (255 240)
                    var j = i + 2
                    while j + 1 < bytes.count, !(bytes[j] == 255 && bytes[j + 1] == 240) { j += 1 }
                    i = j + 2
                } else if (251...254).contains(cmd) {
                    i += 3 // WILL/WONT/DO/DONT + opción
                } else {
                    i += 2
                }
                continue
            }
            plain.append(bytes[i])
            i += 1
        }
        var cleaned = ""
        for b in plain {
            if b == 10 || b == 13 { cleaned.append("\n") }
            else if b >= 32 && b < 127 { cleaned.append(Character(UnicodeScalar(b))) }
        }
        let lines = cleaned.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
        guard !lines.isEmpty else { return nil }
        let joined = lines.prefix(2).joined(separator: " · ")
        return joined.count > 180 ? String(joined.prefix(180)) + "…" : joined
    }
}

// MARK: - Escaneo detallado de un equipo

@MainActor
final class PortScanRunner: ObservableObject {
    struct OpenPort: Identifiable, Hashable {
        let port: UInt16
        var banner: String?
        var id: UInt16 { port }
        var service: String { Services.name(port) }
    }

    @Published private(set) var open: [OpenPort] = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var running = false
    @Published private(set) var status = ""
    private var cancel: CancelFlag?

    func start(ip: UInt32, ports: [UInt16], onFinished: @escaping @MainActor (Set<UInt16>) -> Void) {
        guard !running else { return }
        let cancel = CancelFlag()
        self.cancel = cancel
        open = []
        progress = 0
        running = true
        status = "Probando \(ports.count) puertos…"
        let started = Date()
        let total = Double(ports.count)
        Task.detached(priority: .userInitiated) { [weak self] in
            let counter = Counter()
            await blocking {
                TCPScan.run(ports.map { (ip, $0) }, timeout: 1.2, window: 1024, cancel: cancel) { _, port, r in
                    let n = counter.increment()
                    if r == .open {
                        Task { @MainActor in self?.addOpen(port) }
                    }
                    if n % 128 == 0 || n == ports.count {
                        Task { @MainActor in self?.setProgress(Double(n) / total * 0.85) }
                    }
                }
            }
            // Dejar que se apliquen las últimas altas encoladas antes de leer la lista.
            try? await Task.sleep(nanoseconds: 100_000_000)
            let found = await self?.beginBanners() ?? []
            if !cancel.isCancelled && !found.isEmpty {
                await withTaskGroup(of: (UInt16, String?).self) { group in
                    var it = found.makeIterator()
                    func add(_ p: UInt16) {
                        group.addTask {
                            if BannerGrab.tls.contains(p), PortCatalog.httpsPorts.contains(p),
                               let url = URL(string: "https://\(ip.ipString):\(p)/") {
                                return (p, await HTTPProbe.describe(url))
                            }
                            return (p, await blocking { BannerGrab.grab(ip: ip, port: p) })
                        }
                    }
                    for _ in 0..<8 { if let p = it.next() { add(p) } }
                    var done = 0
                    while let (p, banner) = await group.next() {
                        done += 1
                        let fraction = 0.85 + 0.15 * Double(done) / Double(found.count)
                        await self?.setBanner(p, banner, progress: fraction)
                        if !cancel.isCancelled, let next = it.next() { add(next) }
                    }
                }
            }
            await self?.finish(started: started, cancelled: cancel.isCancelled, onFinished: onFinished)
        }
    }

    private func addOpen(_ port: UInt16) {
        guard !open.contains(where: { $0.port == port }) else { return }
        open.append(OpenPort(port: port))
        open.sort { $0.port < $1.port }
    }

    private func setProgress(_ p: Double) { progress = max(progress, p) }

    private func beginBanners() -> [UInt16] {
        status = "Leyendo respuestas de los servicios…"
        return open.map(\.port)
    }

    private func setBanner(_ port: UInt16, _ banner: String?, progress p: Double) {
        if let i = open.firstIndex(where: { $0.port == port }) { open[i].banner = banner }
        setProgress(p)
    }

    private func finish(started: Date, cancelled: Bool, onFinished: @MainActor (Set<UInt16>) -> Void) {
        running = false
        progress = 1
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        let n = open.count
        status = (cancelled ? "Detenido · " : "") + "\(n) puerto\(n == 1 ? "" : "s") abierto\(n == 1 ? "" : "s") · \(secs) s"
        onFinished(Set(open.map(\.port)))
    }

    func stop() { cancel?.cancel() }
}

struct PortScanSheet: View {
    let device: Device
    let onFinished: (Set<UInt16>) -> Void
    let open: (UInt16) -> Void

    @StateObject private var runner = PortScanRunner()
    private var _preset = State<Int>(initialValue: 0)
    private var _custom = State<String>(initialValue: "1-1024, 3389, 5900, 8000-8100")
    private var _error = State<String?>(initialValue: nil)
    @Environment(\.dismiss) private var dismiss

    init(device: Device, onFinished: @escaping (Set<UInt16>) -> Void, open: @escaping (UInt16) -> Void) {
        self.device = device
        self.onFinished = onFinished
        self.open = open
    }

    private var preset: Int { _preset.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Puertos de \(device.name.isEmpty ? device.ip.ipString : "\(device.name) (\(device.ip.ipString))")")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            HStack {
                Picker("", selection: _preset.projectedValue) {
                    Text("Comunes (\(PortCatalog.common.count))").tag(0)
                    Text("1–1024").tag(1)
                    Text("Todos (1–65535)").tag(2)
                    Text("Personalizado").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(runner.running)
                Button(runner.running ? "Detener" : "Escanear") { runner.running ? runner.stop() : start() }
                    .keyboardShortcut(.defaultAction)
            }
            if preset == 3 {
                TextField("Ej.: 22, 80, 443, 8000-8100", text: _custom.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(runner.running)
                    .onSubmit(start)
            }
            if let e = _error.wrappedValue {
                Text(e).foregroundStyle(.red).font(.callout)
            }
            HStack {
                ProgressView(value: runner.progress).frame(width: 180)
                Text(runner.status).foregroundStyle(.secondary).font(.callout)
                Spacer()
            }
            .opacity(runner.status.isEmpty ? 0 : 1)

            Table(runner.open) {
                TableColumn("Puerto") { p in Text("\(p.port)").monospacedDigit() }
                    .width(min: 50, ideal: 60, max: 70)
                TableColumn("Servicio") { p in Text(p.service) }
                    .width(min: 90, ideal: 120, max: 160)
                TableColumn("Respuesta del servicio") { p in
                    Text(p.banner ?? (runner.running ? "…" : "—"))
                        .foregroundStyle(p.banner == nil ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .help(p.banner ?? "")
                }
                TableColumn("") { p in
                    if Services.url(port: p.port, ip: device.ip) != nil {
                        Button("Abrir") { open(p.port) }.controlSize(.small)
                    }
                }
                .width(56)
            }
            .overlay {
                if runner.open.isEmpty {
                    Text(runner.running ? "Buscando puertos abiertos…" : (runner.status.isEmpty ? "Elige qué puertos probar y pulsa Escanear." : "No se encontraron puertos abiertos."))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Solo se conecta a cada puerto; al puerto de impresión 9100 nunca se le envían datos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cerrar") { runner.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 760, height: 520)
        .onDisappear { runner.stop() }
    }

    private func start() {
        let ports: [UInt16]
        switch preset {
        case 0: ports = PortCatalog.common
        case 1: ports = Array(1...1024)
        case 2: ports = Array(1...65535)
        default:
            guard let p = PortCatalog.parse(_custom.wrappedValue) else {
                _error.wrappedValue = "Lista no válida. Usa números y rangos: 22, 80, 8000-8100"
                return
            }
            ports = p
        }
        _error.wrappedValue = nil
        runner.start(ip: device.ip, ports: ports, onFinished: onFinished)
    }
}
