import Foundation
import AppKit

/// Modo demostración: `open RadarIP.app --args --demo [--open printers,inventory,…] [--select 192.168.1.10]`.
/// Muestra una red ficticia (para capturas de pantalla) sin escanear ni tocar el inventario real.
enum Demo {
    static let enabled = CommandLine.arguments.contains("--demo")

    static func argument(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    /// Tamaño de contenido para la ventana activa (p. ej. "1440x820").
    static var windowSize: NSSize? {
        guard let parts = argument("--size")?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }

    static var windowsToOpen: [String] { argument("--open")?.split(separator: ",").map(String.init) ?? [] }
    static var selectedIP: Set<UInt32> { enabled ? Set([argument("--select").flatMap(ipFromString)].compactMap { $0 }) : [] }

    static func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("radarip-demo-\(name).json")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    static let interface = NetInterface(id: "en0", displayName: "Wi-Fi", ip: ip(20), mask: 0xFFFF_FF00, mac: "A4:83:E7:5C:21:9D")

    static func ip(_ last: UInt32) -> UInt32 { 0xC0A8_0100 | last } // 192.168.1.x

    private static func device(_ last: UInt32, _ mac: String?, vendor: String?, ports: Set<UInt16>, ms: Double,
                               _ configure: (inout Device) -> Void = { _ in }) -> Device {
        var d = Device(ip: ip(last))
        d.alive = true; d.mac = mac; d.vendor = vendor; d.ports = ports; d.latency = ms
        configure(&d)
        return d
    }

    private static func printer(model: String, serial: String, pages: Int, supplies: [PrinterSupply],
                                errors: [String] = [], display: String = "Preparada") -> PrinterStatus {
        PrinterStatus(model: model, serial: serial, pageCount: pages, state: errors.contains("Sin papel") ? 1 : 3, errors: errors,
                      display: [display], supplies: supplies, updated: Date())
    }

    /// Equipos activos del "último escaneo".
    static func devices() -> [Device] {
        [
            device(1, "50:C7:BF:3A:10:01", vendor: "TP-Link", ports: [53, 80, 443], ms: 1.2) {
                $0.isGateway = true; $0.dnsName = "router.oficina.lan"; $0.httpTitle = "Archer AX55"
                $0.upnp = UPnPInfo(name: "Archer AX55", manufacturer: "TP-Link", model: "AX55")
            },
            device(2, "00:1B:54:8C:22:02", vendor: "Cisco Systems", ports: [22, 80, 443], ms: 1.8) {
                $0.snmp = SNMPInfo(name: "SW-CORE", descr: "SG350-28P 28-Port Gigabit PoE Managed Switch", model: nil,
                                   community: "public", isPrinter: false)
            },
            device(3, "1C:7E:E5:41:03:33", vendor: "D-Link", ports: [23, 80], ms: 2.4) {
                $0.snmp = SNMPInfo(name: "SW-BODEGA", descr: "DGS-1210-24 Gigabit Smart Switch", model: nil,
                                   community: "public", isPrinter: false)
                $0.httpTitle = "D-Link DGS-1210-24"
            },
            device(5, "24:5A:4C:10:55:05", vendor: "Ubiquiti", ports: [22, 80, 443], ms: 2.1) {
                $0.mdnsName = "AP-Piso2.local"; $0.httpTitle = "UniFi AP"; $0.bonjour = BonjourInfo(services: ["_http._tcp"], name: nil, model: "U6-Lite")
            },
            device(10, "00:17:C8:6A:10:10", vendor: "Kyocera Document Solutions", ports: [80, 443, 631, 9100], ms: 3.4) {
                $0.netbiosName = "IMP-RECEPCION"; $0.httpTitle = "Command Center RX"
                $0.snmp = SNMPInfo(name: nil, descr: "KYOCERA Document Solutions Printing System", model: "ECOSYS M2640idw",
                                   community: "public", isPrinter: true)
                $0.bonjour = BonjourInfo(services: ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_uscan._tcp", "_http._tcp"],
                                         name: "Kyocera ECOSYS M2640idw (Recepción)", model: "Kyocera ECOSYS M2640idw")
                $0.printer = printer(model: "ECOSYS M2640idw", serial: "VXA1234567", pages: 48_213, supplies: [
                    PrinterSupply(description: "TK-1175", type: 3, level: 8_640, max: 12_000, colorant: "black"),
                    PrinterSupply(description: "Waste Toner Box", type: 4, level: -3, max: -2),
                ], display: "En reposo")
            },
            device(11, "B0:5C:DA:2E:11:11", vendor: "HP Inc.", ports: [80, 443, 631, 9100], ms: 2.9) {
                $0.mdnsName = "IMP-DISENO.local"
                $0.snmp = SNMPInfo(name: "IMP-DISENO", descr: "HP ETHERNET MULTI-ENVIRONMENT", model: "HP Color LaserJet Pro M454dw",
                                   community: "public", isPrinter: true)
                $0.bonjour = BonjourInfo(services: ["_ipp._tcp", "_ipps._tcp", "_pdl-datastream._tcp", "_http._tcp"],
                                         name: "HP Color LaserJet Pro M454dw", model: "HP Color LaserJet Pro M454dw")
                $0.printer = printer(model: "HP Color LaserJet Pro M454dw", serial: "CNBRR4K2X9", pages: 21_507, supplies: [
                    PrinterSupply(description: "Black Cartridge HP W2030A", type: 3, level: 58, max: 100, colorant: "black"),
                    PrinterSupply(description: "Cyan Cartridge HP W2031A", type: 3, level: 31, max: 100, colorant: "cyan"),
                    PrinterSupply(description: "Magenta Cartridge HP W2033A", type: 3, level: 64, max: 100, colorant: "magenta"),
                    PrinterSupply(description: "Yellow Cartridge HP W2032A", type: 3, level: 8, max: 100, colorant: "yellow"),
                ], errors: ["Poco tóner"], display: "Amarillo muy bajo")
            },
            device(12, "30:05:5C:71:12:12", vendor: "Brother Industries", ports: [80, 443, 631, 9100], ms: 3.1) {
                $0.mdnsName = "IMP-BODEGA.local"
                $0.snmp = SNMPInfo(name: "IMP-BODEGA", descr: "Brother NC-8300w", model: "Brother HL-L5100DN series",
                                   community: "public", isPrinter: true)
                $0.bonjour = BonjourInfo(services: ["_ipp._tcp", "_printer._tcp", "_pdl-datastream._tcp"],
                                         name: "Brother HL-L5100DN", model: "Brother HL-L5100DN series")
                $0.printer = printer(model: "Brother HL-L5100DN series", serial: "E78123K9N456", pages: 93_884, supplies: [
                    PrinterSupply(description: "Toner TN-3480", type: 3, level: 54, max: 100, colorant: "black"),
                    PrinterSupply(description: "Drum Unit DR-3400", type: 9, level: 22, max: 100),
                ], errors: ["Sin papel", "Bandeja de entrada vacía"], display: "Sin papel Bandeja 1")
            },
            device(15, "00:11:32:9A:15:15", vendor: "Synology", ports: [22, 80, 139, 443, 445, 548], ms: 1.6) {
                $0.mdnsName = "NAS-OFICINA.local"; $0.netbiosName = "NAS-OFICINA"; $0.httpTitle = "Synology DiskStation"
                $0.bonjour = BonjourInfo(services: ["_smb._tcp", "_afpovertcp._tcp", "_adisk._tcp", "_http._tcp"], name: "NAS-OFICINA", model: "DS920+")
            },
            device(20, interface.mac, vendor: "Apple", ports: [22, 445], ms: 0.1) {
                $0.isSelf = true; $0.mdnsName = "MacBook-Pro-de-Ana.local"
            },
            device(21, "3C:22:FB:6E:21:21", vendor: "Apple", ports: [22, 445, 5900], ms: 4.2) {
                $0.mdnsName = "iMac-Diseno.local"
                $0.bonjour = BonjourInfo(services: ["_smb._tcp", "_rfb._tcp", "_airplay._tcp", "_companion-link._tcp"],
                                         name: "iMac Diseño", model: "iMac21,1")
            },
            device(30, "D4:81:D7:12:30:30", vendor: "Dell", ports: [139, 445, 3389], ms: 1.9) {
                $0.netbiosName = "PC-CONTABILIDAD"; $0.workgroup = "OFICINA"
            },
            device(31, "E4:54:E8:33:31:31", vendor: "Dell", ports: [139, 445, 3389], ms: 2.2) {
                $0.netbiosName = "PC-GERENCIA"; $0.workgroup = "OFICINA"
            },
            device(32, "8C:16:45:A1:32:32", vendor: "Lenovo", ports: [139, 445], ms: 6.8) {
                $0.netbiosName = "NB-VENTAS-01"; $0.workgroup = "OFICINA"
            },
            device(34, "8C:16:45:A1:34:34", vendor: "Lenovo", ports: [139, 445], ms: 7.5) {
                $0.netbiosName = "NB-VENTAS-02"; $0.workgroup = "OFICINA"
            },
            device(35, "98:FA:9B:20:35:35", vendor: "HP Inc.", ports: [139, 445, 3389, 5900], ms: 2.6) {
                $0.netbiosName = "PC-RECEPCION"; $0.workgroup = "OFICINA"
            },
            device(40, "BC:AD:28:4F:40:40", vendor: "Hikvision", ports: [80, 554, 8000], ms: 3.8) {
                $0.httpTitle = "Hikvision Web"; $0.dnsName = "cam-entrada.oficina.lan"
            },
            device(41, "3C:EF:8C:72:41:41", vendor: "Dahua Technology", ports: [80, 554], ms: 4.0) {
                $0.bonjour = BonjourInfo(services: ["_dhnap._tcp"], name: "CAM-ESTACIONAMIENTO", model: "IPC-HDW2431T")
            },
            device(50, "F0:B3:EC:11:50:50", vendor: "Apple", ports: [7000], ms: 5.1) {
                $0.bonjour = BonjourInfo(services: ["_airplay._tcp", "_raop._tcp", "_companion-link._tcp"],
                                         name: "TV Sala de reuniones", model: "AppleTV11,1")
            },
            device(51, "54:60:09:8D:51:51", vendor: "Google", ports: [8008, 8009], ms: 6.3) {
                $0.bonjour = BonjourInfo(services: ["_googlecast._tcp"], name: "TV Comedor", model: "Chromecast with Google TV")
            },
            device(60, "6E:1D:93:4A:60:60", vendor: nil, ports: [62078], ms: 38.0) {
                $0.mdnsName = "iPhone-de-Carlos.local"
            },
            device(61, "DA:7F:02:B5:61:61", vendor: nil, ports: [], ms: 52.0) {
                $0.dnsName = "Galaxy-S24.oficina.lan"
            },
            device(70, "80:5E:C0:3B:70:70", vendor: "Yealink", ports: [80, 443], ms: 2.7) {
                $0.httpTitle = "Yealink SIP-T46U"; $0.dnsName = "sip-recepcion.oficina.lan"
            },
            device(80, "DC:A6:32:0C:80:80", vendor: "Raspberry Pi Trading", ports: [22, 53, 80], ms: 1.4) {
                $0.mdnsName = "pihole.local"; $0.httpTitle = "Pi-hole"
            },
            device(90, "00:15:5D:44:90:90", vendor: "Microsoft", ports: [139, 445, 1433, 3389], ms: 1.1) {
                $0.netbiosName = "SRV-ERP"; $0.workgroup = "OFICINA"
            },
        ]
    }

    /// Equipos del inventario que no aparecen en el último escaneo.
    static let offline: [(UInt32, String, String, String, Int)] = [   // ip, mac, nombre, fabricante, días sin verse
        (91, "00:15:5D:44:91:91", "SRV-BACKUP", "Microsoft", 1),
        (45, "8C:16:45:A1:45:45", "NB-PRACTICA", "Lenovo", 12),
        (46, "8C:16:45:A1:46:46", "NB-PRACTICA-2", "Lenovo", 21),
        (120, "D4:81:D7:12:12:0A", "PC-ANTIGUO", "Dell", 240),
        (121, "D4:81:D7:12:12:0B", "PC-BODEGA-VIEJO", "Dell", 180),
    ]

    static func speedHistory() -> [SpeedResult] {
        let samples: [(Double, Double, Double, Double, Double)] = [
            (612, 318, 9, 1420, 980), (588, 301, 11, 1350, 910), (541, 296, 10, 1180, 880), (603, 322, 8, 1510, 1020),
            (420, 210, 14, 640, 520), (575, 305, 10, 1290, 940), (598, 311, 9, 1400, 990), (566, 290, 12, 1220, 870),
            (610, 325, 8, 1480, 1050), (480, 260, 13, 820, 640), (590, 314, 9, 1380, 960), (604, 320, 9, 1450, 1000),
        ]
        let now = Date()
        return samples.enumerated().map { i, s in
            SpeedResult(date: now.addingTimeInterval(-Double(i) * 86_400 * 1.6 - 3_600), download: s.0, upload: s.1,
                        idleLatency: s.2, downloadRPM: s.3, uploadRPM: s.4, interface: "en0", interfaceType: "wifi",
                        endpoint: "Apple CDN")
        }
    }
}

extension Demo {
    /// Llena el inventario (temporal) con historia y devuelve los cambios del "último escaneo".
    static func prepareInventory(_ inventory: InventoryStore) -> ScanChanges {
        let current = Demo.devices()
        let scanned = Set((1...254).map(Demo.ip))
        let day: TimeInterval = 86_400
        // Escaneo "anterior": sin el teléfono Android (será nuevo), con NB-VENTAS-02 en otra IP y SRV-BACKUP activo.
        var previous = current.filter { $0.ip != Demo.ip(61) }.map { d -> Device in
            d.netbiosName == "NB-VENTAS-02" ? { var x = Device(ip: Demo.ip(36)); x.alive = true; x.mac = d.mac; x.vendor = d.vendor
                x.netbiosName = d.netbiosName; return x }() : d
        }
        for (last, mac, name, vendor, _) in Demo.offline {
            var d = Device(ip: Demo.ip(last)); d.alive = true; d.mac = mac; d.vendor = vendor; d.netbiosName = name
            previous.append(d)
        }
        _ = inventory.record(previous, scanned: scanned)
        for it in inventory.items.values {
            let days = Demo.offline.first { $0.1 == it.mac }?.4 ?? 1
            inventory.update(it.mac) { i in
                i.firstSeen = Date().addingTimeInterval(-day * Double(90 + Int(i.ip & 0x3F)))
                i.lastSeen = Date().addingTimeInterval(-day * Double(days))
            }
        }
        let edits: [(UInt32, String, String, Bool)] = [   // ip, alias, nota, crítico
            (1, "Router principal", "Fibra 600/300 Mbps. Soporte ISP: 600 600 0000.", true),
            (2, "Switch central", "Rack principal, puerto 24 → router.", true),
            (10, "Impresora Recepción", "Arriendo: contador mensual el día 1.", false),
            (15, "", "Respaldo diario a las 02:00.", true),
            (90, "Servidor ERP", "", true),
            (91, "Servidor de respaldos", "Se apaga los fines de semana.", true),
        ]
        for (last, alias, note, critical) in edits {
            guard let mac = inventory.items.values.first(where: { $0.ip == Demo.ip(last) })?.mac else { continue }
            inventory.update(mac) { $0.alias = alias; $0.note = note; $0.critical = critical }
        }
        return inventory.record(current, scanned: scanned)
    }
}
