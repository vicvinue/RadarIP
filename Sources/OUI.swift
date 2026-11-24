import Foundation

/// Base de fabricantes (archivo `manuf` de Wireshark incluido en el bundle).
final class OUIDatabase: @unchecked Sendable {
    static let shared = OUIDatabase()

    private let lock = NSLock()
    private var table: [UInt64: String] = [:] // clave: (bits << 56) | prefijo
    private var loaded = false

    func loadIfNeeded() {
        lock.lock()
        if loaded { lock.unlock(); return }
        lock.unlock()
        var t: [UInt64: String] = [:]
        if let url = Bundle.main.url(forResource: "manuf", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            t.reserveCapacity(60_000)
            for line in text.split(separator: "\n") {
                guard let first = line.first, first != "#" else { continue }
                let f = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard f.count >= 2 else { continue }
                let prefix = f[0].trimmingCharacters(in: .whitespaces)
                let long = f.count >= 3 ? f[2].trimmingCharacters(in: .whitespaces) : ""
                let name = long.isEmpty ? f[1].trimmingCharacters(in: .whitespaces) : long
                let pieces = prefix.split(separator: "/")
                let hex = pieces[0].replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
                guard hex.count <= 12, let raw = UInt64(hex, radix: 16) else { continue }
                let bits = pieces.count > 1 ? Int(pieces[1]) ?? hex.count * 4 : hex.count * 4
                guard [24, 28, 36].contains(bits) else { continue }
                let full = raw << UInt64(48 - hex.count * 4)
                t[UInt64(bits) << 56 | full >> UInt64(48 - bits)] = name
            }
        }
        lock.lock(); table = t; loaded = true; lock.unlock()
    }

    func vendor(for mac: String) -> String? {
        guard let b = macBytes(mac) else { return nil }
        if b[0] & 0x02 != 0 { return nil } // dirección administrada localmente (privada/aleatoria)
        let v = b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        loadIfNeeded()
        lock.lock(); defer { lock.unlock() }
        for bits in [36, 28, 24] {
            if let s = table[UInt64(bits) << 56 | v >> UInt64(48 - bits)] { return s }
        }
        return nil
    }

    static func isRandomized(_ mac: String) -> Bool {
        guard let b = macBytes(mac) else { return false }
        return b[0] & 0x02 != 0
    }
}
