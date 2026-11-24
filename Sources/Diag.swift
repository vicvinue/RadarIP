import Foundation

/// Diagnóstico: `RadarIP --diag <archivo>` escribe lo que la app puede ver del sistema y termina.
enum Diagnostics {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--diag"), i + 1 < args.count else { return }
        let out = args[i + 1]
        var lines: [String] = []
        let p = NetInfo.primary()
        if let g = p.router {
            // Tráfico a la red local para provocar/usar el permiso de Red local.
            TCPScan.run([(g, 80), (g, 443), (g, 22)], timeout: 1, cancel: CancelFlag()) { ip, port, r in
                lines.append("tcp \(ip.ipString):\(port) \(r)")
            }
        }
        for iface in NetInfo.interfaces() { lines.append("iface \(iface.id) mac=\(iface.mac ?? "-")") }
        let sys = ARP.sysctlTable()
        lines.append("sysctl entries=\(sys.map { String($0.count) } ?? "nil")")
        for (ip, e) in (sys ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines.append("  \(ip.ipString) \(e.mac) fresh=\(e.fresh) \(e.iface)")
        }
        lines.append("cmd entries=\(ARP.commandTable().count)")
        if args.contains("--scan"), let iface = NetInfo.interfaces().first(where: { $0.id == p.interface }),
           let ips = try? RangeParser.parse(iface.suggestedRange) {
            let store = ResultStore()
            let t0 = Date()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await ScanEngine.run(ips: ips, iface: iface, gateway: p.router, computerName: NetInfo.computerName(),
                                     store: store, cancel: CancelFlag())
                done.signal()
            }
            done.wait()
            let devs = store.state().devices.sorted { $0.ip < $1.ip }
            for d in devs {
                lines.append([d.ip.ipString, d.name, d.mac ?? "-", d.vendorText, d.latency.map { String(format: "%.0fms", $0) } ?? "-",
                              d.servicesText, d.httpTitle ?? "", d.kind.label].joined(separator: " | "))
            }
            lines.append("\(devs.count) activos, \(devs.filter { $0.mac != nil }.count) con MAC, en \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        }
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        exit(0)
    }
}
