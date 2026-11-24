import Foundation
import SwiftUI
import Charts

// MARK: - Test de velocidad (usa networkQuality, la herramienta de Apple incluida en macOS)

struct SpeedResult: Codable, Identifiable, Hashable {
    var id: Date { date }
    var date: Date
    var download: Double          // Mbps
    var upload: Double            // Mbps
    var idleLatency: Double       // ms
    var downloadRPM: Double?      // respuestas por minuto con la descarga saturada
    var uploadRPM: Double?
    var interface: String
    var interfaceType: String?
    var endpoint: String?

    /// Latencia con carga = 60 000 / RPM.
    var loadedLatency: Double? {
        let values = [downloadRPM, uploadRPM].compactMap { $0 }.filter { $0 > 0 }
        guard !values.isEmpty else { return nil }
        return values.map { 60_000 / $0 }.max()
    }

    var connectionLabel: String {
        switch interfaceType {
        case "wired": return "\(interface) · cable"
        case "wifi": return "\(interface) · Wi-Fi"
        case "cellular": return "\(interface) · móvil"
        default: return interface
        }
    }
}

final class SpeedTestRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var history: [SpeedResult] = []
    @Published private(set) var error: String?

    private var process: Process?
    private var timer: Timer?
    private let url: URL

    var last: SpeedResult? { history.first }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RadarIP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = Demo.enabled ? Demo.tempURL("speedtests") : dir.appendingPathComponent("speedtests.json")
        if Demo.enabled { history = Demo.speedHistory(); return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let list = try? d.decode([SpeedResult].self, from: data) {
            history = list
        }
    }

    func start() {
        guard !running else { return }
        error = nil
        elapsed = 0
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        // -s: descarga y subida por separado (más exacto); -c: salida JSON; -M: duración máxima.
        p.arguments = ["-s", "-c", "-M", "30"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(started) }
        }
        p.terminationHandler = { [weak self] proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async { self?.finished(proc, data, errData) }
        }
        do {
            try p.run()
            process = p
            running = true
        } catch {
            timer?.invalidate()
            self.error = "No se pudo iniciar networkQuality: \(error.localizedDescription)"
        }
    }

    func cancel() {
        process?.terminate()
    }

    private func finished(_ proc: Process, _ data: Data, _ errData: Data) {
        timer?.invalidate()
        timer = nil
        running = false
        process = nil
        if proc.terminationReason == .uncaughtSignal {
            error = "Test cancelado."
            return
        }
        guard let result = Self.parse(data) else {
            let msg = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            error = msg.isEmpty ? "El test no devolvió resultados. ¿Hay conexión a Internet?" : "Error: \(msg.prefix(300))"
            return
        }
        history.insert(result, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        save()
    }

    /// Interpreta la salida JSON de `networkQuality -c`.
    static func parse(_ data: Data, date: Date = Date()) -> SpeedResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dl = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let ul = (json["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let ifName = json["interface_name"] as? String ?? ""
        let display = NetInfo.interfaces().first { $0.id == ifName }?.displayName ?? ifName
        let type = ((json["other"] as? [String: Any])?["interface-type"] as? [String: Any])?.keys.first
        return SpeedResult(
            date: date, download: dl / 1_000_000, upload: ul / 1_000_000,
            idleLatency: (json["base_rtt"] as? NSNumber)?.doubleValue ?? 0,
            downloadRPM: (json["dl_responsiveness"] as? NSNumber)?.doubleValue,
            uploadRPM: (json["ul_responsiveness"] as? NSNumber)?.doubleValue,
            interface: display, interfaceType: type, endpoint: json["test_endpoint"] as? String)
    }

    func delete(_ ids: Set<Date>) {
        history.removeAll { ids.contains($0.date) }
        save()
    }

    func clear() { history = []; save() }

    private func save() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        if let data = try? e.encode(history) { try? data.write(to: url, options: .atomic) }
    }
}

struct SpeedTestView: View {
    @EnvironmentObject var runner: SpeedTestRunner
    private var _selection = State<Set<Date>>(initialValue: [])

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            historySection
                .padding(16)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    // MARK: Resultado actual

    private var header: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 28) {
                bigNumber("Descarga", value: runner.running ? nil : runner.last?.download, unit: "Mbps", symbol: "arrow.down.circle.fill", tint: .blue)
                bigNumber("Subida", value: runner.running ? nil : runner.last?.upload, unit: "Mbps", symbol: "arrow.up.circle.fill", tint: .purple)
                VStack(alignment: .leading, spacing: 8) {
                    smallStat("Latencia en reposo", runner.running ? nil : runner.last.map { "\(Int($0.idleLatency.rounded())) ms" })
                    smallStat("Latencia con carga", runner.running ? nil : runner.last?.loadedLatency.map { "\(Int($0.rounded())) ms" })
                    if let r = runner.last, !runner.running {
                        Text(r.connectionLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Button {
                    runner.running ? runner.cancel() : runner.start()
                } label: {
                    Label(runner.running ? "Cancelar" : "Iniciar test", systemImage: runner.running ? "xmark" : "speedometer")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                if runner.running {
                    ProgressView(value: min(runner.elapsed / 30, 0.97))
                        .frame(width: 180)
                    Text("Midiendo descarga, subida y latencia… \(Int(runner.elapsed)) s")
                        .foregroundStyle(.secondary)
                } else if let e = runner.error {
                    Text(e).foregroundStyle(.red).lineLimit(2)
                } else if let r = runner.last {
                    Text(verdict(r)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            Text("Usa networkQuality de macOS, que mide contra servidores de Apple. Consume unos 300–600 MB por test en conexiones rápidas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verdict(_ r: SpeedResult) -> String {
        if let loaded = r.loadedLatency, r.idleLatency > 0, loaded > r.idleLatency * 4, loaded > 100 {
            return "La latencia sube mucho al saturar la conexión (bufferbloat): las videollamadas pueden cortarse mientras alguien descarga."
        }
        return "Medido \(r.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func bigNumber(_ title: String, value: Double?, unit: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).foregroundStyle(tint).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { $0 >= 100 ? String(format: "%.0f", $0) : String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                Text(unit).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 160, alignment: .leading)
    }

    private func smallStat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title3.monospacedDigit().weight(.semibold))
        }
    }

    // MARK: Historial

    private var historySection: some View {
        let recent = Array(runner.history.prefix(30).reversed())
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Historial").font(.headline)
                Spacer()
                if !_selection.wrappedValue.isEmpty {
                    Button("Borrar seleccionados") {
                        runner.delete(_selection.wrappedValue)
                        _selection.wrappedValue = []
                    }
                }
            }
            if recent.count >= 2 {
                Chart {
                    ForEach(recent) { r in
                        LineMark(x: .value("Fecha", r.date), y: .value("Mbps", r.download), series: .value("Tipo", "Descarga"))
                            .foregroundStyle(by: .value("Tipo", "Descarga"))
                        PointMark(x: .value("Fecha", r.date), y: .value("Mbps", r.download))
                            .foregroundStyle(by: .value("Tipo", "Descarga"))
                        LineMark(x: .value("Fecha", r.date), y: .value("Mbps", r.upload), series: .value("Tipo", "Subida"))
                            .foregroundStyle(by: .value("Tipo", "Subida"))
                        PointMark(x: .value("Fecha", r.date), y: .value("Mbps", r.upload))
                            .foregroundStyle(by: .value("Tipo", "Subida"))
                    }
                }
                .chartForegroundStyleScale(["Descarga": Color.blue, "Subida": Color.purple])
                .chartYAxisLabel("Mbps")
                .frame(height: 140)
            }
            Table(runner.history, selection: _selection.projectedValue) {
                TableColumn("Fecha") { r in Text(r.date.formatted(date: .abbreviated, time: .shortened)) }
                    .width(min: 120, ideal: 150)
                TableColumn("Conexión") { r in Text(r.connectionLabel) }
                    .width(min: 100, ideal: 160)
                TableColumn("Descarga") { r in Text(String(format: "%.1f Mbps", r.download)).monospacedDigit() }
                TableColumn("Subida") { r in Text(String(format: "%.1f Mbps", r.upload)).monospacedDigit() }
                TableColumn("Latencia") { r in Text("\(Int(r.idleLatency.rounded())) ms").monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Con carga") { r in Text(r.loadedLatency.map { "\(Int($0.rounded())) ms" } ?? "—").monospacedDigit() }
                    .width(min: 60, ideal: 80)
            }
            .overlay {
                if runner.history.isEmpty {
                    Text("Aún no hay tests. Pulsa «Iniciar test».").foregroundStyle(.secondary)
                }
            }
        }
    }
}
