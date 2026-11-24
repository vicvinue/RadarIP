import Foundation
import AppKit
import Network

// MARK: - Servicios conocidos

struct ServiceDef { let port: UInt16; let name: String }

enum Services {
    static let all: [ServiceDef] = [
        .init(port: 21, name: "FTP"), .init(port: 22, name: "SSH"), .init(port: 23, name: "Telnet"),
        .init(port: 80, name: "HTTP"), .init(port: 139, name: "NetBIOS"), .init(port: 443, name: "HTTPS"),
        .init(port: 445, name: "SMB"), .init(port: 548, name: "AFP"), .init(port: 554, name: "RTSP"),
        .init(port: 631, name: "IPP"), .init(port: 3389, name: "RDP"), .init(port: 5900, name: "VNC"),
        .init(port: 8080, name: "HTTP:8080"), .init(port: 8443, name: "HTTPS:8443"),
        .init(port: 9100, name: "Impresión"), .init(port: 62078, name: "iOS"),
    ]

    static func name(_ port: UInt16) -> String {
        all.first { $0.port == port }?.name ?? PortCatalog.name(port) ?? "\(port)"
    }

    /// URL para abrir el servicio con la app predeterminada de macOS (nil si no tiene cliente).
    static func url(port: UInt16, ip: UInt32) -> URL? {
        let h = ip.ipString
        switch port {
        case 21: return URL(string: "ftp://\(h)")
        case 22: return URL(string: "ssh://\(h)")
        case 23: return URL(string: "telnet://\(h)")
        case 80: return URL(string: "http://\(h)/")
        case 443: return URL(string: "https://\(h)/")
        case 139, 445: return URL(string: "smb://\(h)")
        case 548: return URL(string: "afp://\(h)")
        case 554: return URL(string: "rtsp://\(h)")
        case 631: return URL(string: "http://\(h):631/")
        case 3389: return URL(string: "rdp://full%20address=s:\(h)")
        case 5900: return URL(string: "vnc://\(h)")
        case 8080: return URL(string: "http://\(h):8080/")
        case 8443: return URL(string: "https://\(h):8443/")
        default:
            if PortCatalog.httpPorts.contains(port) { return URL(string: "http://\(h):\(port)/") }
            if PortCatalog.httpsPorts.contains(port) { return URL(string: "https://\(h):\(port)/") }
            return nil
        }
    }

    static func actionTitle(_ port: UInt16) -> String {
        switch port {
        case 80, 443, 8080, 8443, 631: return "Abrir en el navegador (\(name(port)))"
        case 139, 445: return "Explorar carpetas compartidas (SMB)"
        case 548: return "Conectar por AFP"
        case 5900: return "Compartir pantalla (VNC)"
        case 3389: return "Escritorio remoto (RDP)"
        case 22: return "Conectar por SSH"
        case 21: return "Abrir FTP"
        case 23: return "Conectar por Telnet"
        case 554: return "Abrir vídeo RTSP"
        default: return "Abrir \(name(port))"
        }
    }
}

// MARK: - Dispositivo

enum DeviceKind {
    case thisMac, router, network, phone, voip, mac, windows, printer, camera, tv, nas, server, generic

    var symbol: String {
        switch self {
        case .thisMac: return "laptopcomputer"
        case .router: return "wifi.router"
        case .network: return "rectangle.connected.to.line.below"
        case .phone: return "iphone"
        case .voip: return "phone"
        case .mac: return "desktopcomputer"
        case .windows: return "pc"
        case .printer: return "printer"
        case .camera: return "web.camera"
        case .tv: return "tv"
        case .nas: return "externaldrive.connected.to.line.below"
        case .server: return "server.rack"
        case .generic: return "network"
        }
    }

    var label: String {
        switch self {
        case .thisMac: return "Este Mac"
        case .router: return "Router / puerta de enlace"
        case .network: return "Switch / equipo de red"
        case .phone: return "Teléfono o tableta"
        case .voip: return "Teléfono IP"
        case .mac: return "Mac / Apple"
        case .windows: return "PC Windows"
        case .printer: return "Impresora"
        case .camera: return "Cámara"
        case .tv: return "TV / multimedia"
        case .nas: return "Almacenamiento (NAS)"
        case .server: return "Servidor / Linux"
        case .generic: return "Dispositivo"
        }
    }
}

struct Device: Identifiable, Hashable {
    let ip: UInt32
    var id: UInt32 { ip }
    var alive = false
    var latency: Double?
    var mac: String?
    var vendor: String?
    var dnsName: String?
    var mdnsName: String?
    var netbiosName: String?
    var workgroup: String?
    var httpTitle: String?
    var snmp: SNMPInfo?
    var printer: PrinterStatus?
    var bonjour: BonjourInfo?
    var upnp: UPnPInfo?
    var cachedName: String?
    var ports: Set<UInt16> = []
    var isSelf = false
    var isGateway = false
    var offlineKnown = false
    var lastSeen: Date?
    // Datos del inventario (se añaden al mostrar la lista)
    var alias = ""
    var note = ""
    var critical = false
    var change: DeviceChange?
    var inInventory = false

    init(ip: UInt32) { self.ip = ip }

    init(item: InventoryItem) {
        ip = item.ip; mac = item.mac; vendor = item.vendor; cachedName = item.name
        lastSeen = item.lastSeen; offlineKnown = true
    }

    /// Nombre a mostrar: el alias del usuario o, si no hay, el detectado en la red.
    var name: String { alias.isEmpty ? detectedName : alias }

    var detectedName: String {
        if isSelf, let c = cachedName { return c }
        let snmpName = snmp?.name.map { n in n.contains(".") && ipFromString(n) == nil ? String(n.split(separator: ".")[0]) : n }
        let candidates = [mdnsName.map(Device.cleanMDNS), netbiosName, dnsName, snmpName, bonjour?.name, upnp?.name, cachedName]
        return candidates.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    mutating func apply(_ item: InventoryItem?, change: DeviceChange?) {
        self.change = change
        guard let item else { return }
        inInventory = true
        alias = item.alias
        note = item.note
        critical = item.critical
        if lastSeen == nil { lastSeen = item.lastSeen }
    }

    static func cleanMDNS(_ s: String) -> String {
        var n = s
        if n.hasSuffix(".") { n.removeLast() }
        if n.lowercased().hasSuffix(".local") { n.removeLast(6) }
        return n
    }

    /// Modelo según la fuente más específica disponible.
    var model: String? {
        let options = [printer?.model, snmp?.model, bonjour?.model, upnp?.model, snmp?.descr.map(Device.shortDescr)]
        return options.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Primera línea de sysDescr, recortada (p. ej. "Cisco IOS Software, C2960S Software (…)").
    static func shortDescr(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        let parts = line.components(separatedBy: ", ")
        let short = parts.prefix(2).joined(separator: ", ")
        return short.count > 70 ? String(short.prefix(70)) + "…" : short
    }

    var sortModel: String { (model ?? "\u{10FFFF}").lowercased() }

    var bonjourLabels: [String] { (bonjour?.services ?? []).map(Bonjour.label).sorted() }

    var randomMAC: Bool { mac.map(OUIDatabase.isRandomized) ?? false }

    var vendorText: String {
        if let v = vendor { return v }
        if randomMAC { return "MAC privada (aleatoria)" }
        return ""
    }

    var changeText: String {
        switch change {
        case .new: return "Nuevo"
        case .ipChanged(let from): return "IP cambió (antes \(from.ipString))"
        case nil: return critical && !alive ? "Crítico sin respuesta" : ""
        }
    }

    var sortedPorts: [UInt16] { ports.sorted() }
    var servicesText: String { sortedPorts.map(Services.name).joined(separator: ", ") }

    var kind: DeviceKind {
        if isSelf { return .thisMac }
        if isGateway { return .router }
        let services = bonjour?.services ?? []
        let text = [name, vendor ?? "", httpTitle ?? "", model ?? "", snmp?.descr ?? "", upnp?.manufacturer ?? ""]
            .joined(separator: " ").lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if printer != nil || snmp?.isPrinter == true ||
            !services.isDisjoint(with: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_uscan._tcp"]) { return .printer }
        if !services.isDisjoint(with: ["_googlecast._tcp", "_amzn-wplay._tcp", "_androidtvremote2._tcp"]) { return .tv }
        if services.contains("_dhnap._tcp") { return .camera }
        if ports.contains(9100) || ports.contains(631) ||
            has(["printer", "impresora", "epson", "brother", "kyocera", "laserjet", "officejet", "canon", "xerox", "ricoh", "lexmark"]) { return .printer }
        if has(["yealink", "grandstream", "polycom", "voip", "sip phone", "fanvil", "snom", "cisco ip phone", "gigaset"]) { return .voip }
        if ports.contains(62078) || has(["iphone", "ipad", "android", "galaxy", "pixel", "redmi", "xiaomi", "huawei", "motorola"]) { return .phone }
        if ports.contains(554) || has(["camera", "cámara", "ipcam", "hikvision", "dahua", "ezviz", "tapo", "reolink", "imou"]) { return .camera }
        if has(["appletv", "apple-tv", "apple tv", "roku", "chromecast", "bravia", "webos", "firetv", "fire tv", "smarttv", "smart tv", "-tv", " tv", "tv-"]) { return .tv }
        if has(["cisco", "d-link", "tp-link", "tplink", "managed switch", " switch", "-port gigabit", "access point", "ubiquiti", "mikrotik", "routerboard", "aruba", "juniper",
                 "netgear", "zyxel", "level_15", "fortinet", "fortigate", "ruckus"]) { return .network }
        if has(["synology", "qnap", "diskstation", "nas"]) { return .nas }
        if ports.contains(3389) || has(["desktop-", "laptop-", "windows"]) { return .windows }
        if ports.contains(548) || has(["macbook", "imac", "mac-mini", "macmini", "mac mini", "mac-pro", "mac studio", "apple"]) { return .mac }
        if netbiosName != nil && (ports.contains(445) || ports.contains(139)) { return .windows }
        if ports.contains(22) || has(["raspberry", "ubuntu", "debian", "linux"]) { return .server }
        return .generic
    }

    // Claves de ordenación para la tabla
    var statusRank: Int { isSelf ? 0 : (alive ? (change == nil ? 2 : 1) : (critical ? 3 : 4)) }
    var sortName: String { name.isEmpty ? "\u{10FFFF}" : name.lowercased() }
    var sortVendor: String { vendorText.isEmpty ? "\u{10FFFF}" : vendorText.lowercased() }
    var sortMAC: String { mac ?? "\u{10FFFF}" }
    var sortLatency: Double { latency ?? .infinity }
    var sortServices: Int { ports.count }

    func matches(_ q: String) -> Bool {
        let q = q.lowercased()
        return [name, detectedName, note, ip.ipString, vendorText, mac ?? "", servicesText, httpTitle ?? "", workgroup ?? "",
                dnsName ?? "", model ?? "", snmp?.descr ?? "", bonjourLabels.joined(separator: " ")]
            .contains { $0.lowercased().contains(q) }
    }
}

// MARK: - Resultados compartidos entre hilos

final class ResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [UInt32: Device] = [:]
    private var version = 0
    private var progress: Double = 0
    private var phase = ""

    func update(_ ip: UInt32, _ body: (inout Device) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var d = devices[ip] ?? Device(ip: ip)
        body(&d)
        if d.vendor == nil, let m = d.mac { d.vendor = OUIDatabase.shared.vendor(for: m) }
        devices[ip] = d
        version += 1
    }

    func device(_ ip: UInt32) -> Device? { lock.lock(); defer { lock.unlock() }; return devices[ip] }
    func aliveIPs() -> [UInt32] { lock.lock(); defer { lock.unlock() }; return devices.values.filter(\.alive).map(\.ip).sorted() }

    func setStatus(_ phase: String, _ progress: Double) {
        lock.lock(); self.phase = phase; self.progress = progress; lock.unlock()
    }

    func setProgress(_ p: Double) { lock.lock(); progress = max(progress, p); lock.unlock() }

    func state() -> (devices: [Device], version: Int, progress: Double, phase: String) {
        lock.lock(); defer { lock.unlock() }
        return (devices.values.filter(\.alive), version, progress, phase)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// Ejecuta trabajo bloqueante (sockets, procesos) en un hilo propio sin ocupar el pool de Swift Concurrency.
func blocking<T>(_ body: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in
        Thread.detachNewThread { c.resume(returning: body()) }
    }
}

// MARK: - Motor de escaneo

enum ScanEngine {
    static func run(ips: [UInt32], iface: NetInterface?, gateway: UInt32?, computerName: String, communities: [String] = ["public"],
                    store: ResultStore, cancel: CancelFlag) async {
        let ipSet = Set(ips)
        store.setStatus("Buscando dispositivos…", 0.02)

        if let i = iface, ipSet.contains(i.ip) {
            store.update(i.ip) { $0.alive = true; $0.isSelf = true; $0.mac = i.mac; $0.cachedName = computerName; $0.latency = 0 }
        }

        // Fase 1: ping + sondeo TCP rápido (las respuestas o rechazos TCP también delatan equipos sin ping).
        let discovery: [UInt16] = ips.count <= 2048 ? [80, 443, 22, 445, 3389, 62078] : [80, 445]
        let targets = ips.flatMap { ip in discovery.map { (ip, $0) } }
        let total = Double(max(targets.count, 1))
        let counter = Counter()

        async let icmp: Void = blocking {
            ICMPSweep.run(ips, cancel: cancel) { ip, ms in
                store.update(ip) { $0.alive = true; $0.latency = $0.latency.map { min($0, ms) } ?? ms }
            }
        }
        async let tcp: Void = blocking {
            TCPScan.run(targets, timeout: 1.0, cancel: cancel) { ip, port, r in
                let n = counter.increment()
                if n % 32 == 0 { store.setProgress(0.02 + 0.55 * Double(n) / total) }
                switch r {
                case .open: store.update(ip) { $0.alive = true; $0.ports.insert(port) }
                case .refused: store.update(ip) { $0.alive = true }
                case .failed: break
                }
            }
        }
        _ = await (icmp, tcp)
        if cancel.isCancelled { return }

        // Fase 2: la tabla ARP revela equipos de la red local aunque bloqueen todo (firewall).
        store.setStatus("Leyendo tabla ARP…", 0.6)
        let arp = await blocking { ARP.table() }
        for (ip, e) in arp where ipSet.contains(ip) {
            let known = store.device(ip)?.alive ?? false
            if e.fresh || known {
                store.update(ip) { $0.alive = true; if $0.mac == nil { $0.mac = e.mac } }
            }
        }
        if let g = gateway, store.device(g)?.alive == true {
            store.update(g) { $0.isGateway = true }
        }

        // Fase 3: servicios y nombres en paralelo.
        let alive = store.aliveIPs()
        store.setStatus("Identificando \(alive.count) dispositivos…", 0.65)
        let ports = Services.all.map(\.port)
        let svcTargets = alive.flatMap { ip -> [(UInt32, UInt16)] in
            let have = store.device(ip)?.ports ?? []
            return ports.filter { !have.contains($0) && !discovery.contains($0) }.map { (ip, $0) }
        }
        let svcTotal = Double(max(svcTargets.count, 1))
        let svcCounter = Counter()

        async let svc: Void = blocking {
            TCPScan.run(svcTargets, timeout: 1.5, window: 384, cancel: cancel) { ip, port, r in
                let n = svcCounter.increment()
                if n % 16 == 0 { store.setProgress(0.65 + 0.25 * Double(n) / svcTotal) }
                if r == .open { store.update(ip) { $0.ports.insert(port) } }
            }
        }
        async let names: Void = blocking {
            NameProbe.run(alive, cancel: cancel,
                          onMDNS: { ip, n in store.update(ip) { $0.mdnsName = n } },
                          onNetBIOS: { ip, info in
                              store.update(ip) {
                                  $0.netbiosName = info.name
                                  $0.workgroup = info.group
                                  if $0.mac == nil { $0.mac = info.mac }
                              }
                          })
        }
        async let dns: Void = blocking {
            ReverseDNS.lookup(alive, cancel: cancel) { ip, n in store.update(ip) { $0.dnsName = n } }
        }
        async let rtt: Void = blocking {
            ICMPSweep.run(alive, timeout: 0.8, cancel: cancel) { ip, ms in
                store.update(ip) { $0.latency = $0.latency.map { min($0, ms) } ?? ms }
            }
        }
        async let snmp: Void = blocking {
            SNMPIdentify.run(alive, communities: communities, cancel: cancel) { ip, info in store.update(ip) { $0.snmp = info } }
        }
        let aliveSet = Set(alive)
        let localOnly = alive.count <= 1024
        async let bonjour: Void = blocking {
            guard localOnly else { return }
            Bonjour.browse(wanted: aliveSet, cancel: cancel) { ip, info in store.update(ip) { $0.bonjour = info } }
        }
        async let ssdp: [UInt32: URL] = blocking {
            localOnly ? SSDP.discover(wanted: aliveSet, cancel: cancel) : [:]
        }
        let upnpURLs = await ssdp
        _ = await (svc, names, dns, rtt, snmp, bonjour)
        if cancel.isCancelled { return }

        // Fase 4: títulos web, descripciones UPnP y estado de impresoras, en paralelo.
        enum Job { case title(UInt32, URL), upnp(UInt32, URL), printer(UInt32, String) }
        enum Outcome { case title(UInt32, String?), upnp(UInt32, UPnPInfo?), printer(UInt32, PrinterStatus?) }
        var jobs: [Job] = []
        for ip in alive {
            guard let d = store.device(ip), !d.isSelf else { continue }
            if let p = ([80, 443, 8080, 8443] as [UInt16]).first(where: { d.ports.contains($0) }), let u = Services.url(port: p, ip: ip) {
                jobs.append(.title(ip, u))
            }
            if let u = upnpURLs[ip] { jobs.append(.upnp(ip, u)) }
            if let info = d.snmp, info.isPrinter || d.kind == .printer { jobs.append(.printer(ip, info.community)) }
        }
        if !jobs.isEmpty {
            store.setStatus("Leyendo páginas web, UPnP e impresoras…", 0.9)
            await withTaskGroup(of: Outcome.self) { group in
                var iterator = jobs.makeIterator()
                func add(_ job: Job) {
                    group.addTask {
                        switch job {
                        case .title(let ip, let url): return .title(ip, await HTTPProbe.describe(url))
                        case .upnp(let ip, let url): return .upnp(ip, await SSDP.describe(url))
                        case .printer(let ip, let c): return .printer(ip, await blocking { PrinterProbe.fetch(ip: ip, community: c) })
                        }
                    }
                }
                for _ in 0..<12 { if let j = iterator.next() { add(j) } }
                while let outcome = await group.next() {
                    switch outcome {
                    case .title(let ip, let t): if let t { store.update(ip) { $0.httpTitle = t } }
                    case .upnp(let ip, let u): if let u { store.update(ip) { $0.upnp = u } }
                    case .printer(let ip, let p): if let p { store.update(ip) { $0.printer = p } }
                    }
                    if cancel.isCancelled { group.cancelAll(); continue }
                    if let j = iterator.next() { add(j) }
                }
            }
        }
        store.setStatus("Listo", 1)
    }
}

// MARK: - Modelo de la interfaz

@MainActor
final class ScanModel: ObservableObject {
    @Published private(set) var interfaces: [NetInterface] = []
    @Published private(set) var interfaceID = ""
    @Published var rangeText = ""
    @Published private(set) var devices: [Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var phase = ""
    @Published var errorMessage: String?
    @Published private(set) var summary = ""
    @Published private(set) var permissionHint = false
    @Published private(set) var inventoryVersion = 0
    @Published private(set) var lastChanges = ScanChanges()
    @Published var showChangesBanner = false
    /// Comunidades SNMP (v2c) a probar, separadas por comas.
    @Published var snmpCommunities: String {
        didSet { UserDefaults.standard.set(snmpCommunities, forKey: "snmpCommunities") }
    }
    @Published private(set) var refreshingPrinters = false
    /// Rango del último escaneo completo y cuándo terminó (para el mapa de IPs).
    @Published private(set) var lastScanRange: [UInt32] = []
    @Published private(set) var lastScanDate: Date?
    @Published var showKnownOffline: Bool {
        didSet { UserDefaults.standard.set(showKnownOffline, forKey: "showKnownOffline") }
    }

    let inventory = InventoryStore(fileURL: Demo.enabled ? Demo.tempURL("inventory") : nil)
    private var store: ResultStore?
    private var cancelFlag: CancelFlag?
    private var timer: Timer?
    private var lastVersion = -1
    private var startedAt = Date()
    private var scannedCount = 0
    private var scannedIPs = Set<UInt32>()
    private var primaryInterfaceID: String?
    private var gateway: UInt32?
    private let pathMonitor = NWPathMonitor()

    init() {
        showKnownOffline = UserDefaults.standard.object(forKey: "showKnownOffline") as? Bool ?? false
        snmpCommunities = UserDefaults.standard.string(forKey: "snmpCommunities") ?? "public"
        raiseFileLimit()
        DispatchQueue.global(qos: .utility).async { OUIDatabase.shared.loadIfNeeded() }
        if Demo.enabled {
            interfaces = [Demo.interface]
            interfaceID = Demo.interface.id
            rangeText = "192.168.1.1-192.168.1.254"
            devices = Demo.devices()
            lastChanges = Demo.prepareInventory(inventory)
            lastScanRange = (1...254).map(Demo.ip)
            lastScanDate = Date()
            summary = "\(devices.count) activos de 254 direcciones · 6,2 s"
            showChangesBanner = true
            inventoryVersion += 1
            return
        }
        refreshInterfaces()
        watchNetworkChanges()
        if let saved = UserDefaults.standard.string(forKey: "lastRange"), !saved.isEmpty,
           let i = selectedInterface, (try? RangeParser.parse(saved))?.contains(where: i.contains) == true {
            rangeText = saved
        }
    }

    var selectedInterface: NetInterface? { interfaces.first { $0.id == interfaceID } }

    func refreshInterfaces() {
        if Demo.enabled { return }
        let primary = NetInfo.primary()
        primaryInterfaceID = primary.interface
        gateway = primary.router
        let list = NetInfo.interfaces().sorted {
            ($0.id == primary.interface ? 0 : 1, $0.id) < ($1.id == primary.interface ? 0 : 1, $1.id)
        }
        // Mismo contenido: no publicar nada (evita redibujos innecesarios).
        guard list != interfaces else { return }
        // Si la interfaz elegida desapareció o cambió de IP, pasar a la principal antes de publicar
        // la lista, para que el selector nunca apunte a una opción inexistente.
        let current = list.first { $0.id == interfaceID }
        if current == nil || current != selectedInterface, let pick = current ?? list.first {
            interfaceID = pick.id
            rangeText = pick.suggestedRange
        } else if list.isEmpty {
            interfaceID = ""
        }
        interfaces = list
    }

    /// Vuelve a detectar las interfaces cuando cambia la red (Wi-Fi ↔ hotspot, cable, VPN…).
    private func watchNetworkChanges() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self, !self.isScanning else { return }
                self.refreshInterfaces()
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    func selectInterface(_ id: String) {
        interfaceID = id
        if let i = selectedInterface { rangeText = i.suggestedRange }
    }

    func start() {
        guard !isScanning, !Demo.enabled else { return }
        errorMessage = nil
        let ips: [UInt32]
        do { ips = try RangeParser.parse(rangeText) } catch {
            errorMessage = error.localizedDescription
            return
        }
        UserDefaults.standard.set(rangeText, forKey: "lastRange")
        let iface = interfaces.first { i in ips.contains(where: i.contains) } ?? selectedInterface
        let gw = iface?.id == primaryInterfaceID ? gateway : nil
        let store = ResultStore(), cancel = CancelFlag()
        self.store = store
        cancelFlag = cancel
        devices = []
        lastVersion = -1
        isScanning = true
        progress = 0
        phase = "Preparando…"
        summary = ""
        permissionHint = false
        scannedCount = ips.count
        scannedIPs = Set(ips)
        showChangesBanner = false
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pull() }
        }
        let computerName = NetInfo.computerName()
        let communities = communityList
        Task.detached(priority: .userInitiated) { [weak self] in
            await ScanEngine.run(ips: ips, iface: iface, gateway: gw, computerName: computerName, communities: communities,
                                 store: store, cancel: cancel)
            await self?.finish()
        }
    }

    func stop() {
        guard isScanning else { return }
        cancelFlag?.cancel()
        phase = "Deteniendo…"
    }

    private func pull() {
        guard let s = store?.state() else { return }
        if s.version != lastVersion { devices = s.devices; lastVersion = s.version }
        if abs(progress - s.progress) >= 0.005 || s.progress == 1 { progress = s.progress }
        if cancelFlag?.isCancelled != true, phase != s.phase { phase = s.phase }
    }

    private func finish() {
        pull()
        timer?.invalidate()
        timer = nil
        isScanning = false
        let cancelled = cancelFlag?.isCancelled ?? false
        let elapsed = Date().timeIntervalSince(startedAt)
        let alive = devices.count
        summary = "\(alive) activo\(alive == 1 ? "" : "s") de \(scannedCount) direcciones · \(String(format: "%.1f", elapsed)) s"
            + (cancelled ? " · detenido" : "")
        if !cancelled {
            lastChanges = inventory.record(devices, scanned: scannedIPs)
            lastScanRange = scannedIPs.sorted()
            lastScanDate = Date()
            inventoryVersion += 1
            showChangesBanner = !lastChanges.isEmpty || lastChanges.firstInventory
            permissionHint = !devices.contains { !$0.isSelf }
        }
        phase = ""
    }

    /// Filas visibles: activos + críticos sin respuesta (siempre) + resto del inventario (opcional).
    func rows(search: String, sort: [KeyPathComparator<Device>], onlyChanges: Bool = false) -> [Device] {
        var list = devices.map { d -> Device in
            var d = d
            d.apply(inventory.item(d.mac), change: d.mac.flatMap { lastChanges.changes[$0] })
            return d
        }
        let aliveMACs = Set(list.compactMap(\.mac)), aliveIPs = Set(list.map(\.ip))
        var byIP: [UInt32: InventoryItem] = [:]
        for it in inventory.items.values where !aliveMACs.contains(it.mac) && !aliveIPs.contains(it.ip) {
            guard showKnownOffline || it.critical else { continue }
            if let prev = byIP[it.ip] {
                // Misma IP en varios equipos del inventario: preferir el crítico y, si empatan, el más reciente.
                let keepPrev = prev.critical != it.critical ? prev.critical : prev.lastSeen > it.lastSeen
                if keepPrev { continue }
            }
            byIP[it.ip] = it
        }
        list += byIP.values.map { it in
            var d = Device(item: it)
            d.apply(it, change: nil)
            return d
        }
        if onlyChanges { list = list.filter { $0.change != nil || ($0.critical && !$0.alive) } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.matches(q) } }
        return list.sorted(using: sort)
    }

    var communityList: [String] {
        let list = snmpCommunities.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return list.isEmpty ? ["public"] : list
    }

    /// Impresoras con estado SNMP del último escaneo.
    var printers: [Device] {
        rows(search: "", sort: [KeyPathComparator(\Device.ip)]).filter { $0.alive && $0.printer != nil }
    }

    /// Vuelve a leer el estado de las impresoras (o solo de una) sin repetir el escaneo.
    func refreshPrinters(only ip: UInt32? = nil) {
        guard let store, !refreshingPrinters else { return }
        let targets = devices.filter { d in d.printer != nil && (ip == nil || d.ip == ip) }
            .compactMap { d in d.snmp.map { (d.ip, $0.community) } }
        guard !targets.isEmpty else { return }
        refreshingPrinters = true
        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (ip, community) in targets {
                    group.addTask {
                        if let st = await blocking({ PrinterProbe.fetch(ip: ip, community: community) }) {
                            store.update(ip) { $0.printer = st }
                        }
                    }
                }
            }
            await self?.didRefreshPrinters()
        }
    }

    private func didRefreshPrinters() {
        refreshingPrinters = false
        pull()
    }

    // MARK: Inventario

    func inventoryItem(_ d: Device) -> InventoryItem? { inventory.item(d.mac) }

    /// Modifica un equipo del inventario (lo añade si aún no estaba).
    func editInventory(_ d: Device, _ body: (inout InventoryItem) -> Void) {
        guard let mac = d.mac else { return }
        inventory.ensure(d)
        inventory.update(mac, body)
        inventoryVersion += 1
    }

    func editInventory(mac: String, _ body: (inout InventoryItem) -> Void) {
        inventory.update(mac, body)
        inventoryVersion += 1
    }

    func forget(_ d: Device) {
        guard let m = d.mac else { return }
        forget(mac: m)
    }

    func forget(mac: String) {
        inventory.forget(mac)
        lastChanges.changes[mac] = nil
        lastChanges.missingCritical.removeAll { $0 == mac }
        inventoryVersion += 1
    }

    func clearKnown() {
        inventory.clear()
        lastChanges = ScanChanges()
        inventoryVersion += 1
    }

    /// Añade puertos encontrados por el escaneo detallado al equipo de la lista.
    func mergePorts(_ ip: UInt32, _ ports: Set<UInt16>) {
        guard !ports.isEmpty, let store, store.device(ip) != nil else { return }
        store.update(ip) { $0.ports.formUnion(ports) }
        pull()
    }

    func wake(mac: String) -> Bool { WakeOnLAN.send(mac: mac, broadcasts: interfaces.map(\.broadcast)) }

    @discardableResult
    func wake(_ d: Device) -> Bool {
        guard let m = d.mac else { return false }
        return WakeOnLAN.send(mac: m, broadcasts: interfaces.map(\.broadcast))
    }

    func exportInventoryCSV(_ items: [InventoryItem]) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let header = ["Crítico", "Nombre", "Alias", "Nombre detectado", "Última IP", "MAC", "Fabricante",
                      "Primera vez", "Última vez", "Nota"]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = items.map { it in
            [it.critical ? "Sí" : "", it.displayName, it.alias, it.name, it.ip.ipString, it.mac, it.vendor ?? "",
             df.string(from: it.firstSeen), df.string(from: it.lastSeen), it.note]
        }
        saveCSV(name: "RadarIP_inventario_\(f.string(from: Date())).csv", header: header, rows: rows)
    }

    func saveCSV(name: String, header: [String], rows: [[String]]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ([header] + rows).map { $0.map(esc).joined(separator: ";") }
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            errorMessage = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    func exportCSV(_ rows: [Device]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        panel.nameFieldStringValue = "RadarIP_\(f.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = [["Estado", "Nombre", "IP", "Fabricante", "Modelo", "MAC", "Tipo", "Servicios", "Latencia (ms)",
                      "Nombre DNS", "Nombre mDNS", "Nombre NetBIOS", "Grupo de trabajo", "Web", "Crítico", "Cambio", "Nota"].map(esc).joined(separator: ";")]
        for d in rows {
            let status = d.isSelf ? "Este Mac" : (d.alive ? "Activo" : "Desconectado")
            let lat = d.latency.map { String(format: "%.1f", $0).replacingOccurrences(of: ".", with: ",") } ?? ""
            lines.append([status, d.name, d.ip.ipString, d.vendorText, d.model ?? "", d.mac ?? "", d.kind.label, d.servicesText, lat,
                          d.dnsName ?? "", d.mdnsName.map(Device.cleanMDNS) ?? "", d.netbiosName ?? "", d.workgroup ?? "", d.httpTitle ?? "",
                          d.critical ? "Sí" : "", d.changeText, d.note]
                .map(esc).joined(separator: ";"))
        }
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            errorMessage = "No se pudo guardar: \(error.localizedDescription)"
        }
    }
}
