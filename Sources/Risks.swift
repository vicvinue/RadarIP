import SwiftUI
import AppKit

// MARK: - Reglas de riesgo (basadas en los puertos y datos que ya detecta el escaneo)

enum RiskLevel: Int, Comparable, CaseIterable {
    case high = 0, medium, low

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self { case .high: return "Alto"; case .medium: return "Medio"; case .low: return "Bajo" }
    }

    var color: Color {
        switch self { case .high: return .red; case .medium: return .orange; case .low: return .yellow }
    }

    var symbol: String {
        switch self {
        case .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "info.circle.fill"
        }
    }
}

struct RiskRule: Identifiable {
    let id: String
    let level: RiskLevel
    let title: String
    let why: String
    let fix: String
    /// Devuelve los puertos implicados si la regla aplica al equipo, o nil.
    let match: (Device) -> [UInt16]?
}

struct RiskHit: Identifiable {
    let ruleID: String
    let device: Device
    let ports: [UInt16]
    /// Único entre reglas: el mismo equipo puede aparecer en varias secciones de la lista.
    var id: String { "\(ruleID)-\(device.ip)" }
}

struct RiskGroup: Identifiable {
    let rule: RiskRule
    let hits: [RiskHit]
    var id: String { rule.id }
}

enum RiskAnalyzer {
    private static func ports(_ wanted: Set<UInt16>) -> (Device) -> [UInt16]? {
        { d in
            let found = d.ports.intersection(wanted).sorted()
            return found.isEmpty ? nil : found
        }
    }

    static let rules: [RiskRule] = [
        RiskRule(id: "telnet", level: .high, title: "Telnet abierto",
                 why: "Telnet envía el usuario y la contraseña sin cifrar: cualquier equipo de la red puede capturarlos.",
                 fix: "Desactiva Telnet en el equipo y administra por SSH o por el panel web con HTTPS.",
                 match: ports([23])),
        RiskRule(id: "docker", level: .high, title: "API de Docker sin protección",
                 why: "El puerto 2375 da control total del servidor Docker (y del equipo) sin contraseña.",
                 fix: "Cierra el puerto 2375 o usa 2376 con certificados TLS.",
                 match: ports([2375])),
        RiskRule(id: "database", level: .high, title: "Base de datos accesible desde la red",
                 why: "Las bases de datos expuestas a toda la red son un objetivo directo; algunas (Redis, Memcached, Elasticsearch) no piden contraseña por defecto.",
                 fix: "Limita el acceso con el firewall a los equipos que la necesitan y exige contraseña.",
                 match: ports([1433, 1521, 3306, 5432, 6379, 9200, 11211, 27017])),
        RiskRule(id: "ftp", level: .medium, title: "FTP sin cifrar",
                 why: "FTP transmite contraseñas y archivos en texto claro. En impresoras suele usarse para «escanear a carpeta».",
                 fix: "Desactívalo si no se usa, o cámbialo por SFTP/FTPS o por SMB.",
                 match: ports([21])),
        RiskRule(id: "http", level: .medium, title: "Panel web sin cifrar (solo HTTP)",
                 why: "Las contraseñas del panel de administración viajan sin cifrar cada vez que alguien inicia sesión.",
                 fix: "Activa HTTPS en el equipo y, si es posible, desactiva el acceso por HTTP.",
                 match: { d in
                     let web = d.ports.filter { $0 == 80 || PortCatalog.httpPorts.contains($0) }
                     let secure = d.ports.contains { PortCatalog.httpsPorts.contains($0) }
                     return web.isEmpty || secure ? nil : web.sorted()
                 }),
        RiskRule(id: "rdp", level: .medium, title: "Escritorio remoto (RDP) abierto",
                 why: "RDP es uno de los blancos favoritos de ataques de fuerza bruta y de ransomware.",
                 fix: "Exige NLA y contraseñas robustas, no lo publiques hacia Internet y desactívalo en los equipos que no lo usan.",
                 match: ports([3389])),
        RiskRule(id: "vnc", level: .medium, title: "Pantalla compartida (VNC) abierta",
                 why: "Muchos servidores VNC se protegen solo con una contraseña corta y sin cifrado.",
                 fix: "Desactívalo si no se usa; si se usa, limita quién puede conectarse y usa una contraseña larga.",
                 match: ports([5900, 5901, 5800])),
        RiskRule(id: "rtsp", level: .medium, title: "Vídeo de cámara (RTSP) accesible",
                 why: "Muchas cámaras permiten ver el vídeo con la contraseña de fábrica, o incluso sin ninguna.",
                 fix: "Cambia la contraseña de fábrica y, idealmente, separa las cámaras en su propia red (VLAN).",
                 match: ports([554, 8554, 7070])),
        RiskRule(id: "mqtt", level: .medium, title: "MQTT sin cifrar",
                 why: "El broker MQTT suele aceptar conexiones sin contraseña y transmite en claro.",
                 fix: "Exige usuario y contraseña y usa el puerto con TLS (8883).",
                 match: ports([1883])),
        RiskRule(id: "smb-device", level: .low, title: "Carpetas compartidas (SMB) en un equipo que no es PC",
                 why: "Impresoras y NAS con SMB suelen usar versiones antiguas del protocolo o carpetas sin contraseña.",
                 fix: "Comprueba que el SMB del equipo no permita acceso de invitado y que SMB1 esté desactivado.",
                 match: { d in
                     guard d.ports.contains(445), [.printer, .nas, .camera].contains(d.kind) else { return nil }
                     return [445]
                 }),
        RiskRule(id: "raw-print", level: .low, title: "Impresión directa abierta (9100)",
                 why: "Cualquier equipo de la red puede enviar trabajos a la impresora sin identificarse.",
                 fix: "Es normal en impresoras de oficina; si la impresora lo permite, restringe las IP que pueden imprimir.",
                 match: ports([9100])),
    ]

    static func groups(for devices: [Device]) -> [RiskGroup] {
        rules.compactMap { rule in
            let hits = devices.filter(\.alive).compactMap { d in rule.match(d).map { RiskHit(ruleID: rule.id, device: d, ports: $0) } }
            return hits.isEmpty ? nil : RiskGroup(rule: rule, hits: hits.sorted { $0.device.ip < $1.device.ip })
        }
        .sorted { ($0.rule.level, -$0.hits.count) < ($1.rule.level, -$1.hits.count) }
    }

    static func rules(for d: Device) -> [(RiskRule, [UInt16])] {
        guard d.alive else { return [] }
        return rules.compactMap { r in r.match(d).map { (r, $0) } }
    }

    static func worstLevel(_ d: Device) -> RiskLevel? { rules(for: d).map(\.0.level).min() }

    static func report(_ groups: [RiskGroup]) -> String {
        var out = "Informe de riesgos — RadarIP — \(Date().formatted(date: .abbreviated, time: .shortened))\n"
        for g in groups {
            out += "\n[\(g.rule.level.label)] \(g.rule.title) — \(g.hits.count) equipo\(g.hits.count == 1 ? "" : "s")\n"
            out += "  Por qué: \(g.rule.why)\n  Qué hacer: \(g.rule.fix)\n"
            for h in g.hits {
                let name = h.device.name.isEmpty ? "" : " \(h.device.name)"
                out += "   • \(h.device.ip.ipString)\(name) (puertos \(h.ports.map(String.init).joined(separator: ", ")))\n"
            }
        }
        return out
    }
}

// MARK: - Ventana del informe

struct RisksView: View {
    @EnvironmentObject var model: ScanModel
    private var _collapsed = State<Set<String>>(initialValue: [])

    var body: some View {
        let devices = model.rows(search: "", sort: [KeyPathComparator(\Device.ip)]).filter(\.alive)
        let groups = RiskAnalyzer.groups(for: devices)
        VStack(spacing: 0) {
            header(groups, deviceCount: devices.count)
                .padding(16)
            Divider()
            if devices.isEmpty {
                ContentUnavailableView("Sin datos", systemImage: "shield",
                                       description: Text("Escanea la red para generar el informe de riesgos."))
            } else if groups.isEmpty {
                ContentUnavailableView("Sin riesgos detectados", systemImage: "checkmark.shield",
                                       description: Text("Ninguno de los \(devices.count) equipos tiene servicios de riesgo entre los puertos revisados."))
            } else {
                List {
                    ForEach(groups) { g in
                        Section {
                            if !_collapsed.wrappedValue.contains(g.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(g.rule.why)
                                    Text("Qué hacer: ").bold() + Text(g.rule.fix)
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 2)
                                ForEach(g.hits) { h in hitRow(h, rule: g.rule) }
                            }
                        } header: {
                            groupHeader(g)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .toolbar {
            ToolbarItemGroup {
                Button { copy(RiskAnalyzer.report(groups)) } label: { Label("Copiar informe", systemImage: "doc.on.doc") }
                    .help("Copiar el informe como texto (para un correo o un ticket)")
                    .disabled(groups.isEmpty)
                Button { exportCSV(groups) } label: { Label("Exportar CSV", systemImage: "square.and.arrow.up") }
                    .disabled(groups.isEmpty)
            }
        }
    }

    private func header(_ groups: [RiskGroup], deviceCount: Int) -> some View {
        let count = { (lvl: RiskLevel) in groups.filter { $0.rule.level == lvl }.reduce(0) { $0 + $1.hits.count } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                ForEach(RiskLevel.allCases, id: \.self) { lvl in
                    HStack(spacing: 6) {
                        Image(systemName: lvl.symbol).foregroundStyle(lvl.color)
                        Text("\(count(lvl))").font(.title2.monospacedDigit().weight(.semibold))
                        Text("riesgo \(lvl.label.lowercased())").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small); Text("Escaneando…").foregroundStyle(.secondary) }
            }
            Text("Basado en los puertos detectados en \(deviceCount) equipos activos del último escaneo. El escaneo normal revisa ~16 puertos; usa «Escanear puertos…» en un equipo para revisarlo a fondo. RadarIP no prueba contraseñas ni ataca los equipos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupHeader(_ g: RiskGroup) -> some View {
        let collapsed = _collapsed.wrappedValue.contains(g.id)
        return Button {
            if collapsed { _collapsed.wrappedValue.remove(g.id) } else { _collapsed.wrappedValue.insert(g.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption).frame(width: 10)
                Image(systemName: g.rule.level.symbol).foregroundStyle(g.rule.level.color)
                Text(g.rule.title).font(.headline)
                Text(g.rule.level.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(g.rule.level.color.opacity(0.2), in: Capsule())
                Spacer()
                Text("\(g.hits.count) equipo\(g.hits.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func hitRow(_ h: RiskHit, rule: RiskRule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: h.device.kind.symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(h.device.ip.ipString).monospacedDigit().frame(width: 110, alignment: .leading)
            Text(h.device.name.isEmpty ? "—" : h.device.name).lineLimit(1)
            if h.device.critical { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
            Spacer()
            Text(h.ports.map { "\($0)" }.joined(separator: ", ")).monospacedDigit().foregroundStyle(.secondary)
            if rule.id == "http", let p = h.ports.first, let url = Services.url(port: p, ip: h.device.ip) {
                Button("Abrir") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        }
        .contextMenu {
            Button("Copiar IP") { copy(h.device.ip.ipString) }
            if let m = h.device.mac { Button("Copiar MAC") { copy(m) } }
        }
    }

    private func exportCSV(_ groups: [RiskGroup]) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let rows = groups.flatMap { g in
            g.hits.map { h in
                [g.rule.level.label, g.rule.title, h.device.ip.ipString, h.device.name, h.device.mac ?? "",
                 h.ports.map(String.init).joined(separator: ", "), g.rule.fix]
            }
        }
        model.saveCSV(name: "RadarIP_riesgos_\(f.string(from: Date())).csv",
                      header: ["Nivel", "Riesgo", "IP", "Nombre", "MAC", "Puertos", "Qué hacer"], rows: rows)
    }
}
