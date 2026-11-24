import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: ScanModel
    // Estado de vista con el `State` real de SwiftUI, declarado sin el macro `@State`
    // (su plugin solo viene con Xcode). Un ObservableObject aquí provocaba
    // "Publishing changes from within view updates" y la tabla quedaba en blanco.
    private var _selection = State<Set<UInt32>>(initialValue: Demo.selectedIP)
    private var _sortOrder = State<[KeyPathComparator<Device>]>(initialValue: [KeyPathComparator(\Device.ip)])
    private var _search = State<String>(initialValue: "")
    private var _showInspector = State<Bool>(initialValue: true)
    private var _toolTarget = State<Device?>(initialValue: nil)
    private var _alertText = State<String?>(initialValue: nil)
    private var selection: Set<UInt32> { get { _selection.wrappedValue } nonmutating set { _selection.wrappedValue = newValue } }
    private var sortOrder: [KeyPathComparator<Device>] { get { _sortOrder.wrappedValue } nonmutating set { _sortOrder.wrappedValue = newValue } }
    private var search: String { get { _search.wrappedValue } nonmutating set { _search.wrappedValue = newValue } }
    private var showInspector: Bool { get { _showInspector.wrappedValue } nonmutating set { _showInspector.wrappedValue = newValue } }
    private var toolTarget: Device? { get { _toolTarget.wrappedValue } nonmutating set { _toolTarget.wrappedValue = newValue } }
    private var alertText: String? { get { _alertText.wrappedValue } nonmutating set { _alertText.wrappedValue = newValue } }
    private var _onlyChanges = State<Bool>(initialValue: false)
    private var _portScanTarget = State<Device?>(initialValue: nil)
    private var onlyChanges: Bool { get { _onlyChanges.wrappedValue } nonmutating set { _onlyChanges.wrappedValue = newValue } }
    private var portScanTarget: Device? { get { _portScanTarget.wrappedValue } nonmutating set { _portScanTarget.wrappedValue = newValue } }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rows = model.rows(search: search, sort: sortOrder, onlyChanges: onlyChanges)
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let e = model.errorMessage {
                Banner(text: e, symbol: "exclamationmark.triangle.fill", tint: .red) { model.errorMessage = nil }
            }
            if model.permissionHint {
                Banner(text: "No apareció ningún otro dispositivo. Si macOS preguntó si RadarIP puede acceder a la red local, acepta y vuelve a escanear. Revísalo en Ajustes del Sistema › Privacidad y seguridad › Red local.",
                       symbol: "lock.shield", tint: .orange, actionTitle: "Abrir Ajustes") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                }
            }
            if model.showChangesBanner {
                changesBanner
            }
            table(rows)
            statusBar(rows)
            Divider()
            AppFooter()
        }
        .onAppear {
            guard Demo.enabled else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                for w in Demo.windowsToOpen { if w == "about" { AppInfo.showAbout() } else { openWindow(id: w) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.activate(ignoringOtherApps: true)
                    if let size = Demo.windowSize, let w = NSApp.keyWindow {
                        w.setContentSize(size)
                        w.center()
                    }
                }
            }
        }
        .inspector(isPresented: _showInspector.projectedValue) {
            Inspector(device: selectedDevice(rows), open: open, ping: { toolTarget = $0 }, portScan: { portScanTarget = $0 },
                      wake: wake, forget: model.forget)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { openWindow(id: "inventory") } label: { Label("Inventario", systemImage: "list.bullet.rectangle") }
                    .help("Inventario de equipos: notas, alias, críticos e historial (⌘I)")
                Button { openWindow(id: "printers") } label: { Label("Impresoras", systemImage: "printer") }
                    .help("Tóner, contador de páginas y errores de las impresoras (⌘K)")
                Button { openWindow(id: "ipmap") } label: { Label("Mapa de IPs", systemImage: "square.grid.3x3.fill") }
                    .help("Mapa de IPs libres y en uso del rango (⌘L)")
                Button { openWindow(id: "risks") } label: { Label("Riesgos", systemImage: "exclamationmark.shield") }
                    .help("Informe de riesgos de seguridad de la red (⌘J)")
                Button { openWindow(id: "speedtest") } label: { Label("Test de velocidad", systemImage: "speedometer") }
                    .help("Medir la velocidad de Internet (⌘T)")
                Toggle(isOn: $model.showKnownOffline) {
                    Label("Conocidos desconectados", systemImage: "clock.arrow.circlepath")
                }
                .help("Mostrar también equipos del inventario que ahora no responden (útil para Wake-on-LAN). Los críticos se muestran siempre.")
                Button { model.exportCSV(rows) } label: { Label("Exportar CSV", systemImage: "square.and.arrow.up") }
                    .help("Exportar la lista a CSV (Excel)")
                    .disabled(rows.isEmpty)
                Button { showInspector.toggle() } label: { Label("Detalles", systemImage: "sidebar.right") }
                    .help("Mostrar u ocultar el panel de detalles")
            }
        }
        .searchable(text: _search.projectedValue, placement: .toolbar, prompt: "Filtrar")
        .sheet(item: _toolTarget.projectedValue) { ToolSheet(device: $0) }
        .sheet(item: _portScanTarget.projectedValue) { d in
            PortScanSheet(device: d, onFinished: { model.mergePorts(d.ip, $0) }, open: { open($0, d) })
        }
        .alert(alertText ?? "", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: Barra de control

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button {
                model.isScanning ? model.stop() : model.start()
            } label: {
                Label(model.isScanning ? "Detener" : "Escanear",
                      systemImage: model.isScanning ? "stop.fill" : "dot.radiowaves.left.and.right")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isScanning ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(model.isScanning ? "." : "r", modifiers: .command)

            Picker("Red", selection: Binding(get: { model.interfaceID }, set: { model.selectInterface($0) })) {
                ForEach(model.interfaces) { Text($0.label).tag($0.id) }
                if model.selectedInterface == nil {
                    Text(model.interfaces.isEmpty ? "Sin conexión de red" : "Elige una red").tag(model.interfaceID)
                }
            }
            .labelsHidden()
            .frame(width: 240)
            .help("Interfaz de red: rellena el rango automáticamente")

            TextField("Rango, p. ej. 192.168.1.1-254 o 10.0.0.0/24", text: $model.rangeText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { model.start() }
                .disabled(model.isScanning)

            Button { model.refreshInterfaces() } label: { Image(systemName: "arrow.clockwise") }
                .help("Volver a detectar las interfaces de red")
                .disabled(model.isScanning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Aviso de cambios

    private var changesBanner: some View {
        let c = model.lastChanges
        let critical = !c.missingCritical.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: c.firstInventory ? "tray.full" : (critical ? "exclamationmark.triangle.fill" : "sparkles"))
                .foregroundStyle(critical ? Color.red : Color.accentColor)
            if c.firstInventory {
                Text("Inventario creado con los equipos encontrados. Desde el próximo escaneo se marcarán los equipos nuevos y los cambios de IP.")
            } else {
                Text("Cambios desde el último escaneo: \(c.summary)")
            }
            Spacer()
            if !c.firstInventory {
                Toggle("Solo cambios", isOn: _onlyChanges.projectedValue).toggleStyle(.button)
            }
            Button("Cerrar") {
                model.showChangesBanner = false
                onlyChanges = false
            }
        }
        .font(.callout)
        .padding(10)
        .background((critical ? Color.red : Color.accentColor).opacity(0.1))
    }

    // MARK: Tabla

    private func table(_ rows: [Device]) -> some View {
        Table(rows, selection: _selection.projectedValue, sortOrder: _sortOrder.projectedValue) {
            TableColumn("Estado", value: \.statusRank) { d in
                StatusDot(device: d)
            }
            .width(min: 50, ideal: 56, max: 70)

            TableColumn("Nombre", value: \.sortName) { d in
                HStack(spacing: 6) {
                    Image(systemName: d.kind.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(d.name.isEmpty ? "—" : d.name)
                        .foregroundStyle(d.name.isEmpty ? Color.secondary : Color.primary)
                    if d.isGateway { Tag("router") }
                    if d.isSelf { Tag("este Mac") }
                    if let c = d.change {
                        Tag(c.label, tint: c == .new ? .green : .orange)
                            .help(d.changeText)
                    }
                    if d.critical {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                            .help(d.alive ? "Equipo crítico" : "Equipo crítico SIN RESPUESTA")
                    }
                    if !d.note.isEmpty {
                        Image(systemName: "note.text").foregroundStyle(.secondary).font(.caption)
                            .help(d.note)
                    }
                    if let pr = d.printer, pr.needsAttention {
                        Image(systemName: "drop.halffull").foregroundStyle(pr.errors.isEmpty ? Color.orange : Color.red).font(.caption)
                            .help((pr.errors + (pr.lowestPercent.map { ["Consumible al \($0) %"] } ?? [])).joined(separator: "\n"))
                    }
                    if let lvl = RiskAnalyzer.worstLevel(d), lvl != .low {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(lvl.color).font(.caption)
                            .help(RiskAnalyzer.rules(for: d).map { "\($0.0.level.label): \($0.0.title)" }.joined(separator: "\n"))
                    }
                }
                .help(d.alias.isEmpty ? d.kind.label : "\(d.kind.label) · detectado como «\(d.detectedName)»")
            }
            .width(min: 160, ideal: 230)

            TableColumn("IP", value: \.ip) { d in
                Text(d.ip.ipString).monospacedDigit()
            }
            .width(min: 100, ideal: 118)

            TableColumn("Fabricante", value: \.sortVendor) { d in
                Text(d.vendorText)
                    .foregroundStyle(d.vendor == nil ? Color.secondary : Color.primary)
                    .help(d.vendorText)
            }
            .width(min: 120, ideal: 190)

            TableColumn("Modelo", value: \.sortModel) { d in
                Text(d.model ?? "").help(d.snmp?.descr ?? d.model ?? "")
            }
            .width(min: 90, ideal: 160)

            TableColumn("MAC", value: \.sortMAC) { d in
                Text(d.mac ?? "").font(.system(.body, design: .monospaced))
            }
            .width(min: 140, ideal: 150)

            TableColumn("Servicios", value: \.sortServices) { d in
                Text(d.servicesText).help(d.servicesText)
            }
            .width(min: 90, ideal: 170)

            TableColumn("Latencia", value: \.sortLatency) { d in
                Text(d.latency.map { $0 < 1 ? "<1 ms" : String(format: "%.0f ms", $0) } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70, max: 90)
        }
        .contextMenu(forSelectionType: UInt32.self) { ids in
            contextMenu(rows.filter { ids.contains($0.ip) })
        } primaryAction: { ids in
            guard ids.count == 1, let d = rows.first(where: { ids.contains($0.ip) }) else { return }
            openDefault(d)
        }
        .overlay {
            if rows.isEmpty && !model.isScanning {
                if search.isEmpty {
                    ContentUnavailableView("Red sin escanear", systemImage: "dot.radiowaves.left.and.right",
                                           description: Text("Pulsa Escanear (⌘R) para buscar los dispositivos conectados a tu red."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ items: [Device]) -> some View {
        if items.count == 1, let d = items.first {
            let openable = d.sortedPorts.filter { Services.url(port: $0, ip: d.ip) != nil }
            ForEach(openable, id: \.self) { p in
                Button(Services.actionTitle(p)) { open(p, d) }
            }
            if !openable.isEmpty { Divider() }
            Button("Ping / Traceroute…") { toolTarget = d }
            Button("Escanear puertos…") { portScanTarget = d }
            if d.mac != nil {
                Button("Encender (Wake-on-LAN)") { wake(d) }
            }
            if d.mac != nil, !d.isSelf {
                Button(d.critical ? "Quitar marca de crítico" : "Marcar como crítico") {
                    let value = !d.critical
                    model.editInventory(d) { $0.critical = value }
                }
            }
            Divider()
            Button("Copiar IP") { copy(d.ip.ipString) }
            if let m = d.mac { Button("Copiar MAC") { copy(m) } }
            if !d.name.isEmpty { Button("Copiar nombre") { copy(d.name) } }
            if d.offlineKnown {
                Divider()
                Button("Olvidar (quitar del inventario)") { model.forget(d) }
            }
        } else if !items.isEmpty {
            Button("Copiar \(items.count) IPs") { copy(items.map(\.ip.ipString).joined(separator: "\n")) }
            Button("Copiar como tabla") {
                copy(items.map { [$0.name, $0.ip.ipString, $0.vendorText, $0.mac ?? "", $0.servicesText].joined(separator: "\t") }
                    .joined(separator: "\n"))
            }
            let wakeable = items.filter { $0.mac != nil }
            if !wakeable.isEmpty {
                Button("Encender \(wakeable.count) (Wake-on-LAN)") {
                    wakeable.forEach { model.wake($0) }
                    alertText = "Paquete Wake-on-LAN enviado a \(wakeable.count) dispositivos."
                }
            }
        }
    }

    // MARK: Barra de estado

    private func statusBar(_ rows: [Device]) -> some View {
        HStack(spacing: 10) {
            if model.isScanning {
                ProgressView(value: model.progress).frame(width: 160)
                Text(model.phase)
            } else {
                Text(model.summary.isEmpty ? "Listo para escanear" : model.summary)
            }
            Spacer()
            Text("\(rows.count) en la lista")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Acciones

    private func selectedDevice(_ rows: [Device]) -> Device? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first { $0.ip == id }
    }

    private func openDefault(_ d: Device) {
        for p: UInt16 in [80, 443, 8080, 8443, 445, 5900, 3389, 22, 21] where d.ports.contains(p) {
            open(p, d)
            return
        }
        showInspector = true
    }

    private func open(_ port: UInt16, _ d: Device) {
        guard let url = Services.url(port: port, ip: d.ip) else { return }
        if !NSWorkspace.shared.open(url) {
            alertText = port == 3389
                ? "No hay ninguna app de escritorio remoto. Instala «Windows App» de Microsoft desde la App Store."
                : "Ninguna app de este Mac sabe abrir \(url.scheme ?? "")://"
        }
    }

    private func wake(_ d: Device) {
        alertText = model.wake(d)
            ? "Paquete Wake-on-LAN enviado a \(d.mac ?? "")."
            : "No se pudo enviar el paquete Wake-on-LAN."
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Componentes

struct StatusDot: View {
    let device: Device
    var body: some View {
        HStack {
            Circle()
                .fill(device.offlineKnown ? (device.critical ? Color.red : Color.gray.opacity(0.5)) : (device.isSelf ? Color.blue : Color.green))
                .frame(width: 9, height: 9)
        }
        .frame(maxWidth: .infinity)
        .help(device.offlineKnown ? "Sin respuesta · visto \(device.lastSeen.map(relative) ?? "")" : "Activo")
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es")
        return f.localizedString(for: d, relativeTo: Date())
    }
}

struct Tag: View {
    let text: String
    let tint: Color
    init(_ text: String, tint: Color = .accentColor) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var actionTitle: String = "Cerrar"
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(actionTitle, action: action)
        }
        .font(.callout)
        .padding(10)
        .background(tint.opacity(0.1))
    }
}

// MARK: - Panel de detalles

struct Inspector: View {
    @EnvironmentObject var model: ScanModel
    let device: Device?
    let open: (UInt16, Device) -> Void
    let ping: (Device) -> Void
    let portScan: (Device) -> Void
    let wake: (Device) -> Void
    let forget: (Device) -> Void

    var body: some View {
        if let d = device {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(d)
                    if let c = d.change {
                        Label(d.changeText, systemImage: c == .new ? "sparkles" : "arrow.left.arrow.right")
                            .foregroundStyle(c == .new ? Color.green : Color.orange)
                    }
                    if d.critical && !d.alive {
                        Label("Equipo crítico sin respuesta", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    section("Red") {
                        row("IP", d.ip.ipString)
                        row("MAC", d.mac)
                        row("Fabricante", d.vendorText.isEmpty ? nil : d.vendorText)
                        row("Latencia", d.latency.map { String(format: "%.1f ms", $0) })
                        if d.offlineKnown, let seen = d.lastSeen {
                            row("Visto por última vez", seen.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if d.dnsName != nil || d.mdnsName != nil || d.netbiosName != nil || d.workgroup != nil {
                        section("Nombres") {
                            row("DNS", d.dnsName)
                            row("Bonjour", d.mdnsName.map(Device.cleanMDNS))
                            row("NetBIOS", d.netbiosName)
                            row("Grupo", d.workgroup)
                        }
                    }
                    if let t = d.httpTitle {
                        section("Página web") { Text(t).textSelection(.enabled) }
                    }
                    if let pr = d.printer {
                        PrinterStatusView(device: d, status: pr, compact: true)
                    }
                    if d.model != nil || d.snmp != nil || d.bonjour != nil || d.upnp != nil {
                        section("Identificación") {
                            row("Modelo", d.model)
                            row("SNMP", d.snmp.map { [$0.name, $0.descr.map(Device.shortDescr)].compactMap { $0 }.joined(separator: " · ") })
                            row("Bonjour", d.bonjour.map { b in ([b.name].compactMap { $0 } + [d.bonjourLabels.joined(separator: ", ")]).joined(separator: " · ") })
                            row("UPnP", d.upnp.map { [$0.name, $0.manufacturer, $0.model].compactMap { $0 }.joined(separator: " · ") })
                        }
                    }
                    let risks = RiskAnalyzer.rules(for: d)
                    if !risks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Riesgos").font(.headline)
                            ForEach(risks, id: \.0.id) { rule, ports in
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(rule.title, systemImage: rule.level.symbol)
                                        .foregroundStyle(rule.level.color)
                                    Text("Puerto \(ports.map(String.init).joined(separator: ", ")) · \(rule.fix)")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .help(rule.why)
                            }
                        }
                    }
                    if !d.ports.isEmpty {
                        section("Servicios") {
                            ForEach(d.sortedPorts, id: \.self) { p in
                                HStack {
                                    Text(Services.name(p))
                                    Text("\(p)").foregroundStyle(.secondary).monospacedDigit()
                                    Spacer()
                                    if Services.url(port: p, ip: d.ip) != nil {
                                        Button("Abrir") { open(p, d) }.controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button { ping(d) } label: { Label("Ping / Traceroute…", systemImage: "waveform.path.ecg") }
                        Button { portScan(d) } label: { Label("Escanear puertos…", systemImage: "door.left.hand.open") }
                        if d.mac != nil {
                            Button { wake(d) } label: { Label("Encender (Wake-on-LAN)", systemImage: "power") }
                        }
                        Button { copy(d.ip.ipString) } label: { Label("Copiar IP", systemImage: "doc.on.doc") }
                        if d.offlineKnown {
                            Button(role: .destructive) { forget(d) } label: { Label("Olvidar (quitar del inventario)", systemImage: "trash") }
                        }
                    }
                    .buttonStyle(.link)
                    Divider()
                    InventoryEditor(device: d)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(d.id) // al cambiar de equipo, recrear los campos de edición
        } else {
            ContentUnavailableView("Sin selección", systemImage: "cursorarrow.click",
                                   description: Text("Selecciona un dispositivo para ver sus detalles."))
        }
    }

    private func header(_ d: Device) -> some View {
        HStack(spacing: 12) {
            Image(systemName: d.kind.symbol)
                .font(.system(size: 26))
                .frame(width: 52, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(d.name.isEmpty ? d.ip.ipString : d.name)
                    .font(.title3.bold())
                    .textSelection(.enabled)
                Text(d.offlineKnown ? "\(d.kind.label) · sin respuesta" : d.kind.label)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) { content() }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let v = value, !v.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(v).textSelection(.enabled)
            }
        }
    }
}

/// Alias, nota, marca de crítico e historial de un equipo del inventario.
struct InventoryEditor: View {
    @EnvironmentObject var model: ScanModel
    let mac: String?
    let device: Device?

    init(device: Device) { self.device = device; self.mac = device.mac }
    init(mac: String) { self.device = nil; self.mac = mac }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inventario").font(.headline)
            if let mac, !(device?.isSelf ?? false) {
                let item = model.inventory.item(mac)
                TextField("Nombre propio (alias)", text: binding(\.alias, item))
                    .textFieldStyle(.roundedBorder)
                Toggle("Equipo crítico (avisar si no responde)", isOn: binding(\.critical, item))
                Text("Nota").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: binding(\.note, item))
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                if let item {
                    Text("En el inventario desde \(item.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !item.events.isEmpty {
                        Text("Historial").font(.subheadline.weight(.semibold)).padding(.top, 4)
                        ForEach(Array(item.events.reversed().prefix(25).enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: symbol(e.kind)).foregroundStyle(color(e.kind)).font(.caption)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(e.text).font(.callout)
                                    Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Text("Se añadirá al inventario al terminar el escaneo o al editar estos datos.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(device?.isSelf == true
                     ? "Este Mac no se guarda en el inventario."
                     : "Sin dirección MAC conocida (equipo fuera de la red local): no se puede inventariar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<InventoryItem, T>, _ item: InventoryItem?) -> Binding<T> where T: DefaultValue {
        Binding(
            get: { model.inventory.item(mac)?[keyPath: key] ?? T.defaultValue },
            set: { value in
                if let device { model.editInventory(device) { $0[keyPath: key] = value } }
                else if let mac { model.editInventory(mac: mac) { $0[keyPath: key] = value } }
            })
    }

    private func symbol(_ k: InventoryEvent.Kind) -> String {
        switch k {
        case .firstSeen: return "sparkles"
        case .ipChanged: return "arrow.left.arrow.right"
        case .missing: return "exclamationmark.triangle.fill"
        case .back: return "checkmark.circle.fill"
        }
    }

    private func color(_ k: InventoryEvent.Kind) -> Color {
        switch k {
        case .firstSeen: return .green
        case .ipChanged: return .orange
        case .missing: return .red
        case .back: return .blue
        }
    }
}

protocol DefaultValue { static var defaultValue: Self { get } }
extension String: DefaultValue { static var defaultValue: String { "" } }
extension Bool: DefaultValue { static var defaultValue: Bool { false } }

// MARK: - Ping / Traceroute

final class CommandRunner: ObservableObject {
    @Published var output = ""
    @Published var running = false
    private var process: Process?

    func run(_ path: String, _ args: [String]) {
        stop()
        output = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.append(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc || self.process == nil else { return }
                self.running = false
            }
        }
        do {
            try p.run()
            process = p
            running = true
        } catch {
            output = "Error: \(error.localizedDescription)"
        }
    }

    private func append(_ s: String) {
        output += s
        if output.count > 200_000 { output = String(output.suffix(150_000)) }
    }

    func stop() {
        if let p = process, p.isRunning { p.interrupt() }
        process = nil
    }
}

struct ToolSheet: View {
    let device: Device
    @StateObject private var runner = CommandRunner()
    private var _tool = State<Int>(initialValue: 0)
    private var tool: Int { _tool.wrappedValue }
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: _tool.projectedValue) {
                    Text("Ping").tag(0)
                    Text("Traceroute").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Text(device.name.isEmpty ? device.ip.ipString : "\(device.name) (\(device.ip.ipString))")
                    .lineLimit(1)
                Spacer()
                if tool == 1 {
                    Button(runner.running ? "Detener" : "Iniciar") { runner.running ? runner.stop() : traceroute() }
                }
            }
            if tool == 0 {
                PingView(ip: device.ip.ipString)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(runner.output)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: runner.output) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear(perform: traceroute)
                .onDisappear { runner.stop() }
            }
            HStack {
                Spacer()
                Button("Cerrar") { runner.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 720, height: 500)
        .onDisappear { runner.stop() }
    }

    private func traceroute() {
        runner.run("/usr/sbin/traceroute", ["-w", "2", "-q", "1", "-m", "30", device.ip.ipString])
    }
}
