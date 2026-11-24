import SwiftUI
import AppKit

// MARK: - Estado de una impresora (tarjeta reutilizable)

struct PrinterStatusView: View {
    @EnvironmentObject var model: ScanModel
    let device: Device
    let status: PrinterStatus
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(compact ? "Impresora" : (device.name.isEmpty ? device.ip.ipString : device.name))
                    .font(.headline)
                if !compact {
                    Text(device.ip.ipString).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button {
                    model.refreshPrinters(only: device.ip)
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.refreshingPrinters)
                .help("Volver a leer el estado de la impresora")
            }
            HStack(spacing: 6) {
                Circle().fill(status.errors.isEmpty ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(status.stateText)
                if let panel = status.display.first { Text("· «\(panel)»").foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.callout)
            ForEach(status.errors, id: \.self) { e in
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            }
            ForEach(Array(status.supplies.enumerated()), id: \.offset) { _, s in supplyRow(s) }
            HStack(spacing: 14) {
                if let pages = status.pageCount {
                    Label("\(pages.formatted()) páginas", systemImage: "doc.on.doc").font(.callout)
                }
                if let serial = status.serial {
                    Text("N.º de serie \(serial)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !compact {
                HStack {
                    if let m = status.model { Text(m).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text("Leído \(status.updated.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    if let url = Services.url(port: device.ports.contains(443) ? 443 : 80, ip: device.ip),
                       device.ports.contains(80) || device.ports.contains(443) {
                        Button("Panel web") { NSWorkspace.shared.open(url) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func supplyRow(_ s: PrinterSupply) -> some View {
        let pct = s.percent
        let tint: Color = s.isWaste ? .gray : (pct.map { $0 <= 10 ? .red : ($0 <= 20 ? .orange : colorFor(s)) } ?? .gray)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.description).lineLimit(1)
                Text(s.typeName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(s.levelText).monospacedDigit().foregroundStyle(pct.map { $0 <= 20 && !s.isWaste } == true ? tint : .primary)
            }
            .font(.callout)
            if let pct {
                ProgressView(value: Double(pct), total: 100).tint(tint)
            }
        }
    }

    private func colorFor(_ s: PrinterSupply) -> Color {
        let c = (s.colorant ?? s.description).lowercased()
        if c.contains("cyan") { return .cyan }
        if c.contains("magenta") { return Color(red: 0.85, green: 0.2, blue: 0.6) }
        if c.contains("yellow") || c.contains("amarill") { return .yellow }
        return .accentColor
    }
}

// MARK: - Ventana de impresoras

struct PrintersView: View {
    @EnvironmentObject var model: ScanModel
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14, alignment: .top)]

    var body: some View {
        // Primero las que necesitan atención; luego por menor nivel de consumible.
        let printers = model.printers.sorted {
            ($0.printer!.needsAttention ? 0 : 1, $0.printer!.lowestPercent ?? 101, $0.ip)
                < ($1.printer!.needsAttention ? 0 : 1, $1.printer!.lowestPercent ?? 101, $1.ip)
        }
        Group {
            if printers.isEmpty {
                ContentUnavailableView {
                    Label(model.isScanning ? "Escaneando…" : "Sin impresoras con SNMP", systemImage: "printer")
                } description: {
                    Text(model.isScanning
                         ? "El estado de las impresoras aparece al final del escaneo."
                         : "Escanea la red. Las impresoras deben tener SNMP activado; la comunidad se configura en Ajustes (⌘,). Ahora se usa: \(model.communityList.joined(separator: ", ")).")
                } actions: {
                    if !model.isScanning { Button("Escanear ahora") { model.start() } }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(printers) { d in
                            PrinterStatusView(device: d, status: d.printer!)
                                .padding(12)
                                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(d.printer!.needsAttention ? Color.orange.opacity(0.6) : Color.clear, lineWidth: 1.5))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .toolbar {
            ToolbarItemGroup {
                if model.refreshingPrinters { ProgressView().controlSize(.small) }
                Button { model.refreshPrinters() } label: { Label("Actualizar", systemImage: "arrow.clockwise") }
                    .disabled(printers.isEmpty || model.refreshingPrinters)
                    .help("Volver a leer tóner, contadores y errores")
                Button { export(printers) } label: { Label("Exportar CSV", systemImage: "square.and.arrow.up") }
                    .disabled(printers.isEmpty)
                    .help("Exportar contadores y niveles (útil para el control de páginas)")
            }
        }
    }

    private func export(_ printers: [Device]) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let rows = printers.map { d -> [String] in
            let p = d.printer!
            let supplies = p.supplies.map { "\($0.description): \($0.levelText)" }.joined(separator: " | ")
            return [d.name, d.ip.ipString, p.model ?? "", p.serial ?? "", p.pageCount.map(String.init) ?? "",
                    p.lowestPercent.map { "\($0)" } ?? "", supplies, p.stateText, p.errors.joined(separator: ", ")]
        }
        model.saveCSV(name: "RadarIP_impresoras_\(f.string(from: Date())).csv",
                      header: ["Nombre", "IP", "Modelo", "N.º de serie", "Páginas", "Consumible más bajo (%)",
                               "Consumibles", "Estado", "Errores"], rows: rows)
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        Form {
            Section {
                TextField("Comunidades SNMP", text: $model.snmpCommunities, prompt: Text("public"))
                Text("SNMP v2c, solo lectura. Se prueban en orden, separadas por comas (p. ej. «public, lectura»). Se usan para leer el nombre y el modelo de switches e impresoras, y el tóner y los contadores de las impresoras. Se aplican en el siguiente escaneo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("SNMP")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
