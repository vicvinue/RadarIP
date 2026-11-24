import Foundation
import SwiftUI
import Charts

// MARK: - Ping continuo con estadísticas

struct PingSample: Identifiable, Hashable {
    let seq: Int
    var ms: Double?   // nil = sin respuesta
    var id: Int { seq }
}

struct PingStats {
    var sent = 0, received = 0
    var min: Double?, avg: Double?, max: Double?, jitter: Double?, last: Double?
    var loss: Double { sent == 0 ? 0 : Double(sent - received) / Double(sent) * 100 }

    init(_ samples: [PingSample]) {
        sent = samples.count
        let values = samples.compactMap(\.ms)
        received = values.count
        guard !values.isEmpty else { return }
        min = values.min(); max = values.max()
        avg = values.reduce(0, +) / Double(values.count)
        last = samples.last?.ms
        if values.count > 1 {
            // Jitter: variación media entre respuestas consecutivas (como RFC 3550, sin suavizado).
            var total = 0.0
            for i in 1..<values.count { total += abs(values[i] - values[i - 1]) }
            jitter = total / Double(values.count - 1)
        }
    }
}

final class PingRunner: ObservableObject {
    @Published private(set) var samples: [PingSample] = []
    @Published private(set) var running = false
    @Published private(set) var error: String?
    private var process: Process?
    private var buffer = ""
    private let maxSamples = 3600

    private static let reply = try! NSRegularExpression(pattern: #"icmp_seq=(\d+).*time=([\d.]+) ms"#)
    private static let timeout = try! NSRegularExpression(pattern: #"Request timeout for icmp_seq (\d+)"#)

    var stats: PingStats { PingStats(samples) }

    func start(ip: String, interval: Double) {
        stop()
        samples = []
        buffer = ""
        error = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-i", String(format: "%.1f", interval), "-W", "2000", ip]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(s) }
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
            self.error = error.localizedDescription
        }
    }

    func stop() {
        if let p = process, p.isRunning { p.interrupt() }
        process = nil
        running = false
    }

    func consume(_ chunk: String) {
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            parse(line)
        }
    }

    private func parse(_ line: String) {
        let range = NSRange(line.startIndex..., in: line)
        if let m = Self.reply.firstMatch(in: line, range: range),
           let seq = Int(line[Range(m.range(at: 1), in: line)!]),
           let ms = Double(line[Range(m.range(at: 2), in: line)!]) {
            record(seq, ms)
        } else if let m = Self.timeout.firstMatch(in: line, range: range),
                  let seq = Int(line[Range(m.range(at: 1), in: line)!]) {
            record(seq, nil)
        } else if line.contains("cannot resolve") || line.contains("No route") || line.contains("Unknown host") {
            error = line
        }
    }

    private func record(_ seq: Int, _ ms: Double?) {
        // Una respuesta tardía reemplaza al "sin respuesta" ya anotado para esa secuencia.
        if let i = samples.lastIndex(where: { $0.seq == seq }) {
            if samples[i].ms == nil, let ms { samples[i].ms = ms }
            return
        }
        samples.append(PingSample(seq: seq, ms: ms))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }
}

struct PingView: View {
    let ip: String
    @StateObject private var runner = PingRunner()
    private var _interval = State<Double>(initialValue: 1.0)
    private var interval: Double { _interval.wrappedValue }

    var body: some View {
        let stats = runner.stats
        let window = Array(runner.samples.suffix(120))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Intervalo", selection: _interval.projectedValue) {
                    Text("1 s").tag(1.0)
                    Text("0,5 s").tag(0.5)
                    Text("0,2 s").tag(0.2)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                Button("Reiniciar") { runner.start(ip: ip, interval: interval) }
                Button(runner.running ? "Detener" : "Iniciar") {
                    runner.running ? runner.stop() : runner.start(ip: ip, interval: interval)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    stat("Enviados", "\(stats.sent)")
                    stat("Recibidos", "\(stats.received)")
                    stat("Pérdida", String(format: "%.1f %%", stats.loss), tint: stats.loss > 5 ? .red : (stats.loss > 0 ? .orange : nil))
                    stat("Última", ms(stats.last))
                }
                GridRow {
                    stat("Mínima", ms(stats.min))
                    stat("Media", ms(stats.avg))
                    stat("Máxima", ms(stats.max))
                    stat("Jitter", ms(stats.jitter), tint: (stats.jitter ?? 0) > 30 ? .orange : nil)
                }
            }

            Chart {
                ForEach(window) { s in
                    if let v = s.ms {
                        LineMark(x: .value("Secuencia", s.seq), y: .value("ms", v))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.accentColor)
                        PointMark(x: .value("Secuencia", s.seq), y: .value("ms", v))
                            .symbolSize(12)
                            .foregroundStyle(Color.accentColor)
                    } else {
                        RuleMark(x: .value("Secuencia", s.seq))
                            .foregroundStyle(Color.red.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                if let avg = stats.avg {
                    RuleMark(y: .value("Media", avg))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("media \(ms(avg))").font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            .chartYAxisLabel("ms")
            .chartXAxis(.hidden)
            .frame(minHeight: 180)
            .overlay {
                if window.isEmpty {
                    Text(runner.running ? "Esperando respuestas…" : "Detenido").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Rectangle().fill(Color.red.opacity(0.55)).frame(width: 2, height: 12)
                Text("sin respuesta").font(.caption).foregroundStyle(.secondary)
                if let e = runner.error {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Text("Últimas \(window.count) de \(runner.samples.count) muestras").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { runner.start(ip: ip, interval: interval) }
        .onChange(of: interval) { runner.start(ip: ip, interval: interval) }
        .onDisappear { runner.stop() }
    }

    private func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
    }

    private func stat(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(tint ?? .primary)
        }
    }
}
