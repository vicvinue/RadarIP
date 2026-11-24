import SwiftUI
import AppKit

struct InventoryView: View {
    @EnvironmentObject var model: ScanModel
    private var _selection = State<Set<String>>(initialValue: Set([Demo.enabled ? Demo.argument("--select-mac") : nil].compactMap { $0 }))
    private var _sortOrder = State<[KeyPathComparator<InventoryItem>]>(initialValue: [KeyPathComparator(\InventoryItem.ip)])
    private var _search = State<String>(initialValue: "")
    private var _onlyCritical = State<Bool>(initialValue: false)
    private var _confirmForget = State<Bool>(initialValue: false)
    private var _showDetail = State<Bool>(initialValue: true)

    private var selection: Set<String> { _selection.wrappedValue }

    var body: some View {
        let online = Set(model.devices.compactMap(\.mac))
        let items = filtered()
        VStack(spacing: 0) {
            Table(items, selection: _selection.projectedValue, sortOrder: _sortOrder.projectedValue) {
                TableColumn("", value: \.criticalRank) { it in
                    Image(systemName: it.critical ? "star.fill" : "star")
                        .foregroundStyle(it.critical ? Color.yellow : Color.secondary.opacity(0.4))
                        .onTapGesture { model.editInventory(mac: it.mac) { $0.critical.toggle() } }
                        .help(it.critical ? "Crítico: avisar si no responde" : "Marcar como crítico")
                }
                .width(24)
                TableColumn("Estado") { it in
                    Circle()
                        .fill(online.contains(it.mac) ? Color.green : (it.missingSince != nil ? Color.red : Color.gray.opacity(0.5)))
                        .frame(width: 9, height: 9)
                        .frame(maxWidth: .infinity)
                        .help(online.contains(it.mac) ? "Activo en el último escaneo" : "No visto en el último escaneo")
                }
                .width(46)
                TableColumn("Nombre", value: \.sortName) { it in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(it.displayName.isEmpty ? "—" : it.displayName)
                        if !it.alias.isEmpty && !it.name.isEmpty {
                            Text(it.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("Última IP", value: \.ip) { it in Text(it.ip.ipString).monospacedDigit() }
                    .width(min: 100, ideal: 115)
                TableColumn("MAC", value: \.mac) { it in Text(it.mac).font(.system(.body, design: .monospaced)) }
                    .width(min: 140, ideal: 150)
                TableColumn("Fabricante", value: \.sortVendor) { it in
                    Text(it.vendor ?? (OUIDatabase.isRandomized(it.mac) ? "MAC privada (aleatoria)" : ""))
                        .foregroundStyle(it.vendor == nil ? Color.secondary : Color.primary)
                }
                .width(min: 110, ideal: 170)
                TableColumn("Modelo", value: \.sortModel) { it in Text(it.model ?? "").help(it.model ?? "") }
                    .width(min: 90, ideal: 150)
                TableColumn("Visto por última vez", value: \.lastSeen) { it in
                    Text(it.lastSeen.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 120, ideal: 140)
                TableColumn("Primera vez", value: \.firstSeen) { it in
                    Text(it.firstSeen.formatted(date: .abbreviated, time: .omitted))
                }
                .width(min: 80, ideal: 100)
                TableColumn("Nota", value: \.note) { it in
                    Text(it.note.replacingOccurrences(of: "\n", with: " · ")).foregroundStyle(.secondary).help(it.note)
                }
            }
            .contextMenu(forSelectionType: String.self) { macs in
                if macs.count == 1, let mac = macs.first, let it = model.inventory.item(mac) {
                    Button(it.critical ? "Quitar marca de crítico" : "Marcar como crítico") {
                        model.editInventory(mac: mac) { $0.critical.toggle() }
                    }
                    Button("Encender (Wake-on-LAN)") { _ = model.wake(mac: mac) }
                    Divider()
                    Button("Copiar IP") { copy(it.ip.ipString) }
                    Button("Copiar MAC") { copy(mac) }
                }
                if !macs.isEmpty {
                    Divider()
                    Button("Olvidar \(macs.count == 1 ? "equipo" : "\(macs.count) equipos")…") {
                        _selection.wrappedValue = macs
                        _confirmForget.wrappedValue = true
                    }
                }
            }
            .onDeleteCommand { if !selection.isEmpty { _confirmForget.wrappedValue = true } }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(model.inventory.items.isEmpty ? "Inventario vacío" : "Sin resultados",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text(model.inventory.items.isEmpty
                                                             ? "Los equipos se añaden automáticamente al terminar cada escaneo."
                                                             : "Ningún equipo coincide con el filtro."))
                }
            }
            HStack {
                Text("\(items.count) de \(model.inventory.items.count) equipos · \(model.inventory.items.values.filter(\.critical).count) críticos")
                Spacer()
                Button("Mostrar archivo") { NSWorkspace.shared.activateFileViewerSelecting([model.inventory.fileURL]) }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        .inspector(isPresented: _showDetail.projectedValue) {
            Group {
                if selection.count == 1, let mac = selection.first, model.inventory.item(mac) != nil {
                    ScrollView {
                        InventoryEditor(mac: mac)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(mac)
                } else {
                    ContentUnavailableView("Sin selección", systemImage: "cursorarrow.click",
                                           description: Text("Selecciona un equipo para editar su alias, nota e historial."))
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: _onlyCritical.projectedValue) { Label("Solo críticos", systemImage: "star") }
                    .help("Mostrar solo los equipos críticos")
                Button { model.exportInventoryCSV(items) } label: { Label("Exportar CSV", systemImage: "square.and.arrow.up") }
                    .disabled(items.isEmpty)
                Button { _showDetail.wrappedValue.toggle() } label: { Label("Detalles", systemImage: "sidebar.right") }
            }
        }
        .searchable(text: _search.projectedValue, placement: .toolbar, prompt: "Buscar en el inventario")
        .confirmationDialog("¿Olvidar \(selection.count == 1 ? "este equipo" : "\(selection.count) equipos")?",
                            isPresented: _confirmForget.projectedValue) {
            Button("Olvidar", role: .destructive) {
                for mac in selection { model.forget(mac: mac) }
                _selection.wrappedValue = []
            }
        } message: {
            Text("Se borran su alias, nota e historial. Si vuelve a aparecer en un escaneo, se registrará como nuevo.")
        }
        .frame(minWidth: 820, minHeight: 420)
    }

    private func filtered() -> [InventoryItem] {
        let q = _search.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        return model.inventory.items.values
            .filter { !_onlyCritical.wrappedValue || $0.critical }
            .filter { it in
                q.isEmpty || [it.displayName, it.name, it.ip.ipString, it.mac, it.vendor ?? "", it.model ?? "", it.note]
                    .contains { $0.lowercased().contains(q) }
            }
            .sorted(using: _sortOrder.wrappedValue)
    }
}
