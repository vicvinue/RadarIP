import Foundation

// MARK: - Inventario persistente de equipos (clave: MAC)

struct InventoryEvent: Codable, Hashable {
    enum Kind: String, Codable { case firstSeen, ipChanged, missing, back }
    var date: Date
    var kind: Kind
    var text: String
}

struct InventoryItem: Codable, Identifiable, Hashable {
    var id: String { mac }
    var mac: String
    var ip: UInt32
    var name: String            // nombre detectado en el último escaneo
    var vendor: String?
    var model: String?          // modelo detectado (SNMP, Bonjour, UPnP)
    var alias: String = ""      // nombre puesto por el usuario
    var note: String = ""
    var critical = false
    var firstSeen: Date
    var lastSeen: Date
    var missingSince: Date?     // solo se usa para equipos críticos
    var events: [InventoryEvent] = []

    var displayName: String { alias.isEmpty ? name : alias }

    // Claves de ordenación
    var sortName: String { displayName.isEmpty ? "\u{10FFFF}" : displayName.lowercased() }
    var sortVendor: String { (vendor ?? "\u{10FFFF}").lowercased() }
    var sortModel: String { (model ?? "\u{10FFFF}").lowercased() }
    var criticalRank: Int { critical ? 0 : 1 }

    mutating func log(_ kind: InventoryEvent.Kind, _ text: String, at date: Date) {
        events.append(InventoryEvent(date: date, kind: kind, text: text))
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }
}

/// Cambio detectado en un equipo respecto del inventario anterior.
enum DeviceChange: Hashable {
    case new
    case ipChanged(from: UInt32)

    var label: String {
        switch self {
        case .new: return "nuevo"
        case .ipChanged: return "IP cambió"
        }
    }
}

struct ScanChanges {
    var changes: [String: DeviceChange] = [:]   // MAC → cambio
    var missingCritical: [String] = []          // MACs de críticos sin respuesta
    var firstInventory = false
    var newCount = 0

    var ipChangedCount: Int { changes.values.filter { if case .ipChanged = $0 { return true }; return false }.count }
    var isEmpty: Bool { changes.isEmpty && missingCritical.isEmpty }

    var summary: String {
        var parts: [String] = []
        if newCount > 0 { parts.append("\(newCount) nuevo\(newCount == 1 ? "" : "s")") }
        let ipc = ipChangedCount
        if ipc > 0 { parts.append("\(ipc) cambi\(ipc == 1 ? "ó" : "aron") de IP") }
        let mc = missingCritical.count
        if mc > 0 { parts.append("\(mc) crítico\(mc == 1 ? "" : "s") sin respuesta") }
        return parts.joined(separator: " · ")
    }
}

final class InventoryStore {
    private(set) var items: [String: InventoryItem] = [:]
    private let url: URL
    private var pendingSave: DispatchWorkItem?

    /// `fileURL` permite usar otro archivo (pruebas); por defecto, Application Support/RadarIP.
    init(fileURL: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RadarIP", isDirectory: true)
        url = fileURL ?? dir.appendingPathComponent("inventory.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let list = try? decoder.decode([InventoryItem].self, from: data) {
            items = Dictionary(uniqueKeysWithValues: list.map { ($0.mac, $0) })
        } else if fileURL == nil {
            migrateFromUserDefaults()
        }
    }

    /// Migra los "dispositivos conocidos" de la versión 1.0 (UserDefaults).
    private func migrateFromUserDefaults() {
        struct Old: Codable { var ip: UInt32; var mac: String; var name: String; var vendor: String?; var lastSeen: Date }
        guard let data = UserDefaults.standard.data(forKey: "knownDevices.v1"),
              let old = try? JSONDecoder().decode([String: Old].self, from: data) else { return }
        for o in old.values {
            items[o.mac] = InventoryItem(mac: o.mac, ip: o.ip, name: o.name, vendor: o.vendor,
                                         firstSeen: o.lastSeen, lastSeen: o.lastSeen)
        }
        saveNow()
    }

    func item(_ mac: String?) -> InventoryItem? { mac.flatMap { items[$0] } }

    /// Incorpora un escaneo terminado y devuelve qué cambió.
    func record(_ devices: [Device], scanned: Set<UInt32>) -> ScanChanges {
        let now = Date()
        var result = ScanChanges()
        result.firstInventory = items.isEmpty
        var seen = Set<String>()
        for d in devices where d.alive && !d.isSelf {
            guard let mac = d.mac else { continue }
            seen.insert(mac)
            if var it = items[mac] {
                if it.ip != d.ip {
                    result.changes[mac] = .ipChanged(from: it.ip)
                    it.log(.ipChanged, "IP cambió de \(it.ip.ipString) a \(d.ip.ipString)", at: now)
                    it.ip = d.ip
                }
                if let since = it.missingSince {
                    it.log(.back, "Volvió a responder (sin respuesta desde \(since.formatted(date: .abbreviated, time: .shortened)))", at: now)
                    it.missingSince = nil
                }
                if !d.detectedName.isEmpty { it.name = d.detectedName }
                if let v = d.vendor { it.vendor = v }
                if let m = d.model { it.model = m }
                it.lastSeen = now
                items[mac] = it
            } else {
                var it = InventoryItem(mac: mac, ip: d.ip, name: d.detectedName, vendor: d.vendor, firstSeen: now, lastSeen: now)
                it.model = d.model
                it.log(.firstSeen, "Detectado por primera vez en \(d.ip.ipString)", at: now)
                items[mac] = it
                if !result.firstInventory {
                    result.changes[mac] = .new
                    result.newCount += 1
                }
            }
        }
        // Críticos que estaban en el rango escaneado y no respondieron.
        for (mac, var it) in items where it.critical && !seen.contains(mac) && scanned.contains(it.ip) {
            result.missingCritical.append(mac)
            if it.missingSince == nil {
                it.missingSince = now
                it.log(.missing, "Sin respuesta en \(it.ip.ipString)", at: now)
                items[mac] = it
            }
        }
        saveNow()
        return result
    }

    func update(_ mac: String, _ body: (inout InventoryItem) -> Void) {
        guard var it = items[mac] else { return }
        body(&it)
        items[mac] = it
        scheduleSave()
    }

    /// Añade al inventario un equipo visto en pantalla que aún no estaba (p. ej. para anotarlo antes de terminar el escaneo).
    func ensure(_ d: Device) {
        guard let mac = d.mac, items[mac] == nil, !d.isSelf else { return }
        var it = InventoryItem(mac: mac, ip: d.ip, name: d.detectedName, vendor: d.vendor, firstSeen: Date(), lastSeen: Date())
        it.log(.firstSeen, "Detectado por primera vez en \(d.ip.ipString)", at: Date())
        items[mac] = it
        scheduleSave()
    }

    func forget(_ mac: String) { items[mac] = nil; saveNow() }
    func clear() { items = [:]; saveNow() }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let list = items.values.sorted { $0.ip < $1.ip }
        if let data = try? encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }

    var fileURL: URL { url }
}
