import SwiftUI
import AppKit

// MARK: - Clasificación de cada IP del rango

enum IPUse: Equatable {
    case outOfRange      // no pertenece al rango mostrado (p. ej. .0 y .255)
    case thisMac, gateway, inUse
    case recent(Date)    // en el inventario, visto hace poco: probablemente apagado, no libre
    case stale(Date)     // en el inventario, pero hace mucho que no aparece
    case free            // escaneada, sin respuesta y sin historial
    case unknown         // no se ha escaneado y no hay historial

    var label: String {
        switch self {
        case .outOfRange: return "Fuera del rango"
        case .thisMac: return "Este Mac"
        case .gateway: return "Router"
        case .inUse: return "En uso"
        case .recent: return "Reservada (vista hace poco)"
        case .stale: return "Sin uso reciente"
        case .free: return "Libre"
        case .unknown: return "Sin datos"
        }
    }

    var fill: Color {
        switch self {
        case .outOfRange: return .clear
        case .thisMac: return .blue.opacity(0.75)
        case .gateway: return .purple.opacity(0.75)
        case .inUse: return .green.opacity(0.7)
        case .recent: return .orange.opacity(0.55)
        case .stale: return .orange.opacity(0.2)
        case .free: return Color.secondary.opacity(0.07)
        case .unknown: return Color.secondary.opacity(0.2)
        }
    }

    var strongText: Bool {
        switch self { case .thisMac, .gateway, .inUse: return true; default: return false }
    }

    static func classify(inRange: Bool, scanned: Bool, alive: Device?, item: InventoryItem?,
                         now: Date = Date(), staleDays: Int) -> IPUse {
        guard inRange else { return .outOfRange }
        if let d = alive {
            if d.isSelf { return .thisMac }
            if d.isGateway { return .gateway }
            return .inUse
        }
        if let it = item {
            let days = now.timeIntervalSince(it.lastSeen) / 86_400
            return days <= Double(staleDays) ? .recent(it.lastSeen) : .stale(it.lastSeen)
        }
        return scanned ? .free : .unknown
    }
}

// MARK: - Ventana del mapa

struct IPMapView: View {
    @EnvironmentObject var model: ScanModel
    private var _block = State<UInt32?>(initialValue: nil)
    private var _selected = State<UInt32?>(initialValue: nil)
    private var _staleDays = State<Int>(initialValue: 30)

    private let columns = Array(repeating: GridItem(.fixed(46), spacing: 4), count: 16)

    var body: some View {
        let range = displayRange
        let blocks = Array(Set(range.map { $0 >> 8 })).sorted()
        let block = _block.wrappedValue.flatMap { blocks.contains($0) ? $0 : nil } ?? blocks.first
        let inRange = Set(range)
        let scanned = Set(model.lastScanRange)
        let alive = Dictionary(model.devices.filter(\.alive).map { ($0.ip, $0) }, uniquingKeysWith: { a, _ in a })
        var byIP: [UInt32: InventoryItem] = [:]
        for it in model.inventory.items.values where inRange.contains(it.ip) {
            if let prev = byIP[it.ip], prev.lastSeen > it.lastSeen { continue }
            byIP[it.ip] = it
        }
        let staleDays = _staleDays.wrappedValue
        func use(_ ip: UInt32) -> IPUse {
            IPUse.classify(inRange: inRange.contains(ip), scanned: scanned.contains(ip), alive: alive[ip],
                           item: byIP[ip], staleDays: staleDays)
        }
        let uses = range.map { ($0, use($0)) }
        let free = uses.filter { $0.1 == .free }.map(\.0)
        let stale = uses.filter { if case .stale = $0.1 { return true }; return false }.map(\.0)

        return VStack(alignment: .leading, spacing: 12) {
            summary(uses: uses, free: free, stale: stale)
            if blocks.count > 1, let block {
                Picker("Bloque", selection: Binding(get: { block }, set: { _block.wrappedValue = $0 })) {
                    ForEach(blocks, id: \.self) { b in Text("\((b << 8).ipString)/24").tag(b) }
                }
                .frame(width: 240)
            }
            if let block {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                        ForEach(0..<256, id: \.self) { octet in
                            let ip = block << 8 | UInt32(octet)
                            cell(ip: ip, use: use(ip), device: alive[ip], item: byIP[ip])
                        }
                    }
                    .padding(2)
                }
            } else {
                ContentUnavailableView("Sin rango", systemImage: "square.grid.3x3",
                                       description: Text("Escribe un rango en la ventana principal o escanea la red."))
            }
            legend
            detail(use: _selected.wrappedValue.map(use), ip: _selected.wrappedValue,
                   device: _selected.wrappedValue.flatMap { alive[$0] }, item: _selected.wrappedValue.flatMap { byIP[$0] })
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 640)
        .toolbar {
            ToolbarItemGroup {
                Picker("Sin uso reciente tras", selection: _staleDays.projectedValue) {
                    Text("7 días").tag(7)
                    Text("30 días").tag(30)
                    Text("90 días").tag(90)
                    Text("1 año").tag(365)
                }
                .help("Las IP del inventario que no aparecen desde hace más tiempo se consideran probablemente libres")
                Button { copy(free.map(\.ipString).joined(separator: "\n")) } label: {
                    Label("Copiar IP libres", systemImage: "doc.on.doc")
                }
                .disabled(free.isEmpty)
            }
        }
    }

    /// Rango a mostrar: el del último escaneo; si no hay, el escrito en la ventana principal.
    private var displayRange: [UInt32] {
        if !model.lastScanRange.isEmpty { return model.lastScanRange }
        return (try? RangeParser.parse(model.rangeText)) ?? []
    }

    // MARK: Partes

    private func summary(uses: [(UInt32, IPUse)], free: [UInt32], stale: [UInt32]) -> some View {
        let inUse = uses.filter { [.inUse, .thisMac, .gateway].contains($0.1) }.count
        let recent = uses.filter { if case .recent = $0.1 { return true }; return false }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 22) {
                number("\(uses.count)", "direcciones")
                number("\(inUse)", "en uso", .green)
                number("\(recent)", "reservadas", .orange)
                number("\(stale.count)", "sin uso reciente", .orange.opacity(0.6))
                number("\(free.count)", "libres", .primary)
                Spacer()
            }
            if model.isScanning {
                Label("Escaneando: el mapa se completa al terminar.", systemImage: "hourglass").foregroundStyle(.secondary)
            } else if let date = model.lastScanDate {
                Text("Último escaneo: \(date.formatted(date: .omitted, time: .shortened)) · «Libre» = no respondió y nunca se ha visto. Un equipo apagado sin historial también aparece libre, y la app no conoce el rango DHCP del router: antes de fijar una IP, conviene comprobar ese rango.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Label("Aún no hay un escaneo completo: solo se muestra lo que sabe el inventario.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Button("Escanear ahora") { model.start() }
                }
            }
            if !free.isEmpty {
                HStack(spacing: 6) {
                    Text("Primeras libres:").foregroundStyle(.secondary)
                    ForEach(free.prefix(8), id: \.self) { ip in
                        Button(ip.ipString) { copy(ip.ipString); _selected.wrappedValue = ip }
                            .buttonStyle(.link)
                            .help("Copiar \(ip.ipString)")
                    }
                }
                .font(.callout)
            }
        }
    }

    private func number(_ value: String, _ label: String, _ tint: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(label).foregroundStyle(tint == .primary ? .secondary : tint)
        }
    }

    private func cell(ip: UInt32, use: IPUse, device: Device?, item: InventoryItem?) -> some View {
        let selected = _selected.wrappedValue == ip
        return Text("\(ip & 255)")
            .font(.system(.callout, design: .monospaced).weight(use.strongText ? .semibold : .regular))
            .foregroundStyle(use == .outOfRange ? Color.secondary.opacity(0.35) : (use.strongText ? Color.white : Color.primary))
            .frame(width: 46, height: 30)
            .background(use.fill, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Color.accentColor : (use == .free ? Color.green.opacity(0.5) : Color.clear),
                        lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if item?.critical == true {
                    Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(.yellow).padding(2)
                }
            }
            .help(tooltip(ip: ip, use: use, device: device, item: item))
            .contentShape(Rectangle())
            .onTapGesture { if use != .outOfRange { _selected.wrappedValue = ip } }
            .contextMenu {
                if use != .outOfRange {
                    Button("Copiar \(ip.ipString)") { copy(ip.ipString) }
                    if let m = device?.mac ?? item?.mac { Button("Copiar MAC") { copy(m) } }
                }
            }
    }

    private func tooltip(ip: UInt32, use: IPUse, device: Device?, item: InventoryItem?) -> String {
        var parts = [ip.ipString, use.label]
        if let n = device?.name ?? item?.displayName, !n.isEmpty { parts.append(n) }
        switch use {
        case .recent(let d), .stale(let d): parts.append("visto \(d.formatted(date: .abbreviated, time: .omitted))")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([IPUse.inUse, .gateway, .thisMac, .recent(Date()), .stale(Date()), .free, .unknown], id: \.label) { u in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(u.fill)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(u == .free ? Color.green.opacity(0.5) : Color.clear))
                        .frame(width: 14, height: 14)
                    Text(u.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(use: IPUse?, ip: UInt32?, device: Device?, item: InventoryItem?) -> some View {
        if let ip, let use {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ip.ipString).font(.headline.monospacedDigit())
                    Text(use.label).foregroundStyle(.secondary)
                }
                .frame(width: 180, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    if let n = device?.name ?? item?.displayName, !n.isEmpty { Text(n) }
                    if let m = device?.mac ?? item?.mac { Text(m).font(.system(.callout, design: .monospaced)) }
                    if let v = device?.vendorText ?? item?.vendor, !v.isEmpty { Text(v).foregroundStyle(.secondary) }
                    if let it = item {
                        Text("Visto por última vez: \(it.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        if !it.note.isEmpty { Text(it.note).font(.caption) }
                    }
                    if use == .free {
                        Text("Nadie respondió en esta IP y no hay registros de que se haya usado.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Copiar IP") { copy(ip.ipString) }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text("Haz clic en una celda para ver su detalle.").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }
}
