import Foundation

// Pruebas de la lógica de RadarIP (sin interfaz). Uso: ./build.sh test
var failures = 0
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if cond { print("  ✓ \(msg)") } else { failures += 1; print("  ✗ \(msg)  (línea \(line))") }
}

func dev(_ ip: String, _ mac: String?, name: String = "") -> Device {
    var d = Device(ip: ipFromString(ip)!)
    d.alive = true; d.mac = mac; d.netbiosName = name.isEmpty ? nil : name
    return d
}

print("Inventario")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("radarip-test-\(UUID().uuidString).json")
defer { try? FileManager.default.removeItem(at: tmp) }
let range = Set((1...254).map { 0xC0A8_0A00 | UInt32($0) }) // 192.168.10.0/24
var inv = InventoryStore(fileURL: tmp)
var c = inv.record([dev("192.168.10.5", "AA:00:00:00:00:01", name: "PC1"), dev("192.168.10.6", "AA:00:00:00:00:02")], scanned: range)
check(c.firstInventory && c.changes.isEmpty, "primer escaneo crea el inventario sin marcar nada como nuevo")
check(inv.items.count == 2, "2 equipos registrados")
inv.update("AA:00:00:00:00:02") { $0.critical = true; $0.alias = "Impresora"; $0.note = "Sala 3" }
c = inv.record([dev("192.168.10.7", "AA:00:00:00:00:01"), dev("192.168.10.8", "AA:00:00:00:00:03")], scanned: range)
check(c.changes["AA:00:00:00:00:03"] == .new && c.newCount == 1, "equipo desconocido se marca como nuevo")
check(c.changes["AA:00:00:00:00:01"] == .ipChanged(from: ipFromString("192.168.10.5")!), "cambio de IP detectado con la IP anterior")
check(c.missingCritical == ["AA:00:00:00:00:02"], "crítico ausente detectado")
check(c.summary == "1 nuevo · 1 cambió de IP · 1 crítico sin respuesta", "resumen: \(c.summary)")
check(inv.items["AA:00:00:00:00:01"]?.name == "PC1", "conserva el nombre detectado si el nuevo escaneo no trae nombre")
c = inv.record([dev("192.168.10.7", "AA:00:00:00:00:01")], scanned: range)
check(inv.items["AA:00:00:00:00:02"]?.events.filter { $0.kind == .missing }.count == 1, "la ausencia de un crítico se anota una sola vez")
c = inv.record([dev("192.168.10.6", "AA:00:00:00:00:02")], scanned: range)
let ev = inv.items["AA:00:00:00:00:02"]!.events.map(\.kind)
check(ev.last == .back && inv.items["AA:00:00:00:00:02"]?.missingSince == nil, "al volver se anota «volvió a responder»")
c = inv.record([dev("10.0.0.9", "AA:00:00:00:00:01")], scanned: Set([ipFromString("10.0.0.9")!]))
check(c.missingCritical.isEmpty, "un crítico fuera del rango escaneado no cuenta como ausente")
inv.saveNow()
let reloaded = InventoryStore(fileURL: tmp)
check(reloaded.items["AA:00:00:00:00:02"]?.alias == "Impresora" && reloaded.items["AA:00:00:00:00:02"]?.note == "Sala 3"
      && reloaded.items["AA:00:00:00:00:02"]?.critical == true, "alias, nota y crítico persisten en disco")
var d = dev("192.168.10.6", "AA:00:00:00:00:02", name: "KM123")
d.apply(reloaded.items["AA:00:00:00:00:02"], change: nil)
check(d.name == "Impresora" && d.detectedName == "KM123", "el alias reemplaza al nombre detectado")
check(d.matches("sala 3"), "la búsqueda encuentra texto de la nota")

print("Catálogo y lista de puertos")
check(PortCatalog.parse("22, 80,8000-8002") == [22, 80, 8000, 8001, 8002], "interpreta lista y rangos")
check(PortCatalog.parse("80-70") == nil && PortCatalog.parse("abc") == nil && PortCatalog.parse("0") == nil, "rechaza entradas inválidas")
check(Services.name(3306) == "MySQL" && Services.name(12345) == "12345", "nombres de servicio")
check(Services.url(port: 8000, ip: ipFromString("10.0.0.1")!)?.absoluteString == "http://10.0.0.1:8000/", "URL para puertos HTTP alternativos")

print("Banners")
check(BannerGrab.summarize(Array("SSH-2.0-OpenSSH_9.6\r\n".utf8)) == "SSH-2.0-OpenSSH_9.6", "saludo SSH")
check(BannerGrab.summarize(Array("HTTP/1.1 200 OK\r\nServer: nginx/1.24\r\nX: y\r\n\r\n".utf8)) == "HTTP/1.1 200 OK · nginx/1.24", "respuesta HTTP con Server")
check(BannerGrab.summarize([255, 251, 1, 255, 251, 3] + Array("\r\nLogin: ".utf8)) == "Login:", "Telnet sin bytes de negociación")
check(BannerGrab.summarize([255, 251, 33, 255, 250, 24, 1, 255, 240] + Array("!login: ".utf8)) == "!login:", "IAC con opción 33 («!») no se cuela; el texto real sí")
check(BannerGrab.summarize([255, 251, 33] + Array("login: ".utf8)) == "login:", "negociación WILL 33 eliminada")
check(BannerGrab.neverSend.contains(9100), "nunca se envían datos al puerto de impresión 9100")

print("Ping")
let pr = PingRunner()
pr.consume("PING 1.1.1.1 (1.1.1.1): 56 data bytes\n64 bytes from 1.1.1.1: icmp_seq=0 ttl=57 time=10.000 ms\n")
pr.consume("Request timeout for icmp_seq 1\n64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=30.0")
pr.consume("00 ms\n64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=20.000 ms\n")
let st = pr.stats
check(st.sent == 4 && st.received == 3, "4 enviados, 3 recibidos (línea partida en dos bloques)")
check(abs(st.loss - 25) < 0.01, "pérdida 25 %")
check(st.min == 10 && st.max == 30 && abs((st.avg ?? 0) - 20) < 0.001, "mín/media/máx")
check(abs((st.jitter ?? 0) - 15) < 0.001, "jitter = media de |Δ| consecutivos (20+10)/2")
pr.consume("64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=900.000 ms\n")
check(pr.stats.received == 4 && pr.stats.sent == 4, "respuesta tardía reemplaza al timeout sin duplicar")

print("Test de velocidad")
let sample = #"{"dl_throughput":149518976,"ul_throughput":198209536,"base_rtt":80.67,"dl_responsiveness":224.2,"ul_responsiveness":464.7,"interface_name":"en99","test_endpoint":"x.aaplimg.com","other":{"interface-type":{"wired":537}}}"#
if let r = SpeedTestRunner.parse(Data(sample.utf8)) {
    check(abs(r.download - 149.52) < 0.01 && abs(r.upload - 198.21) < 0.01, "Mbps de descarga y subida")
    check(abs((r.loadedLatency ?? 0) - 60_000 / 224.2) < 0.01, "latencia con carga = 60000/RPM peor")
    check(r.interfaceType == "wired" && r.connectionLabel == "en99 · cable", "tipo de conexión")
} else { check(false, "interpreta el JSON de networkQuality") }
check(SpeedTestRunner.parse(Data("{}".utf8)) == nil, "JSON sin datos → nil")

print("Riesgos")
func withPorts(_ ip: String, _ ports: [UInt16], netbios: String? = nil) -> Device {
    var d = dev(ip, "BB:00:00:00:00:\(ip.split(separator: ".").last!)")
    d.ports = Set(ports); d.netbiosName = netbios
    return d
}
let sw = withPorts("192.168.10.24", [23, 80, 443])
let printer = withPorts("192.168.10.9", [21, 80, 445, 631, 9100])
let pc = withPorts("192.168.10.45", [139, 445, 3389], netbios: "NB-01")
let cam = withPorts("192.168.10.12", [80, 554])
let phone = withPorts("192.168.10.46", [80, 443])
var off = withPorts("192.168.10.99", [23]); off.alive = false
let ids = { (d: Device) in Set(RiskAnalyzer.rules(for: d).map(\.0.id)) }
check(ids(sw) == ["telnet"], "switch: Telnet; con HTTPS no cuenta como panel sin cifrar")
check(ids(printer) == ["ftp", "http", "smb-device", "raw-print"], "impresora: FTP, HTTP sin cifrar, SMB, 9100 → \(ids(printer).sorted())")
check(ids(pc) == ["rdp"], "PC Windows: RDP, pero su SMB no se marca")
check(ids(cam) == ["http", "rtsp"], "cámara: HTTP sin cifrar y RTSP")
check(!ids(withPorts("192.168.10.87", [139, 445])).contains("smb-device"), "equipo sin nombre con SMB no se marca (puede ser un PC)")
check(ids(phone).isEmpty, "teléfono con HTTP y HTTPS: sin riesgos")
check(RiskAnalyzer.rules(for: off).isEmpty, "equipos sin respuesta no se evalúan")
check(RiskAnalyzer.worstLevel(sw) == .high && RiskAnalyzer.worstLevel(printer) == .medium, "nivel más grave por equipo")
let groups = RiskAnalyzer.groups(for: [sw, printer, pc, cam, phone, off])
check(groups.first?.rule.id == "telnet", "el informe empieza por los riesgos altos")
check(groups.first { $0.rule.id == "http" }?.hits.count == 2, "panel sin cifrar agrupa 2 equipos")
check(RiskAnalyzer.report(groups).contains("192.168.10.24"), "el informe de texto incluye las IP")

print("Mapa de IPs")
let now = Date()
let recentItem = InventoryItem(mac: "CC:00:00:00:00:01", ip: 1, name: "x", firstSeen: now, lastSeen: now.addingTimeInterval(-3 * 86_400))
let oldItem = InventoryItem(mac: "CC:00:00:00:00:02", ip: 2, name: "y", firstSeen: now, lastSeen: now.addingTimeInterval(-60 * 86_400))
var selfDev = dev("192.168.10.182", nil); selfDev.isSelf = true
var gw = dev("192.168.10.1", "DD:00:00:00:00:01"); gw.isGateway = true
check(IPUse.classify(inRange: false, scanned: true, alive: nil, item: nil, staleDays: 30) == .outOfRange, "fuera del rango")
check(IPUse.classify(inRange: true, scanned: true, alive: selfDev, item: nil, staleDays: 30) == .thisMac, "este Mac")
check(IPUse.classify(inRange: true, scanned: true, alive: gw, item: nil, staleDays: 30) == .gateway, "router")
check(IPUse.classify(inRange: true, scanned: true, alive: printer, item: oldItem, staleDays: 30) == .inUse, "activo gana al historial")
check(IPUse.classify(inRange: true, scanned: true, alive: nil, item: recentItem, now: now, staleDays: 30) == .recent(recentItem.lastSeen), "visto hace 3 días → reservada")
check(IPUse.classify(inRange: true, scanned: true, alive: nil, item: oldItem, now: now, staleDays: 30) == .stale(oldItem.lastSeen), "visto hace 60 días → sin uso reciente")
check(IPUse.classify(inRange: true, scanned: true, alive: nil, item: oldItem, now: now, staleDays: 90) == .recent(oldItem.lastSeen), "con umbral de 90 días vuelve a ser reservada")
check(IPUse.classify(inRange: true, scanned: true, alive: nil, item: nil, staleDays: 30) == .free, "escaneada sin respuesta ni historial → libre")
check(IPUse.classify(inRange: true, scanned: false, alive: nil, item: nil, staleDays: 30) == .unknown, "sin escanear → sin datos, nunca «libre»")

print("SNMP")
// Petición conocida: GET sysDescr.0 con comunidad "public", id 1 (bytes de referencia de net-snmp).
let req = SNMPPacket.request(SNMPPacket.get, community: "public", id: 1, oids: [oid("1.3.6.1.2.1.1.1.0")])
check(req == [0x30, 0x26, 0x02, 0x01, 0x01, 0x04, 0x06] + Array("public".utf8) + [0xA0, 0x19, 0x02, 0x01, 0x01, 0x02, 0x01, 0x00,
      0x02, 0x01, 0x00, 0x30, 0x0E, 0x30, 0x0C, 0x06, 0x08, 0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00, 0x05, 0x00],
      "codifica un GET idéntico al de net-snmp")
check(BER.integer(128) == [0x02, 0x02, 0x00, 0x80] && BER.integer(-2) == [0x02, 0x01, 0xFE] && BER.integer(12000) == [0x02, 0x02, 0x2E, 0xE0],
      "enteros con signo (128, -2, 12000)")
check(BER.decodeOID(BER.objectID(oid("1.3.6.1.2.1.43.11.1.1.9.1.1")).dropFirst(2)) == oid("1.3.6.1.2.1.43.11.1.1.9.1.1"), "OID ida y vuelta")
check(BER.decodeOID(BER.objectID([1, 3, 6, 1, 4, 1, 1347, 300000]).dropFirst(2)) == [1, 3, 6, 1, 4, 1, 1347, 300000], "OID con subidentificadores grandes")
check(BER.length(300) == [0x82, 0x01, 0x2C], "longitud en forma larga")
func respPacket(_ binds: [[UInt8]]) -> [UInt8] {
    let list = BER.tlv(0x30, binds.flatMap { $0 })
    return BER.tlv(0x30, BER.integer(1) + BER.octets("public") + BER.tlv(0xA2, BER.integer(7) + BER.integer(0) + BER.integer(0) + list))
}
let resp = respPacket([
    BER.tlv(0x30, BER.objectID(oid("1.3.6.1.2.1.1.5.0")) + BER.octets("SW-CORE.empresa.local")),
    BER.tlv(0x30, BER.objectID(oid("1.3.6.1.2.1.43.11.1.1.9.1.1")) + BER.integer(-3)),
    BER.tlv(0x30, BER.objectID(oid("1.3.6.1.2.1.43.10.2.1.4.1.1")) + BER.tlv(0x41, [0x01, 0x4C, 0x57])),
    BER.tlv(0x30, BER.objectID(oid("1.3.6.1.2.1.25.3.2.1.3.1")) + [0x80, 0x00]),
])
if let r = SNMPPacket.parse(resp) {
    check(r.id == 7 && r.error == 0 && r.binds.count == 4, "respuesta: id, sin error, 4 valores")
    check(r.binds[0].value.string == "SW-CORE.empresa.local", "valor de texto")
    check(r.binds[1].value.int == -3 && r.binds[2].value.int == 85079, "entero negativo y Counter32 (85079)")
    check(r.binds[3].value == .missing, "noSuchObject → ausente")
} else { check(false, "interpreta la respuesta SNMP") }
check(SNMPPacket.parse([0x30, 0x03, 0x02, 0x01]) == nil, "paquete truncado → nil")

print("Impresoras")
check(PrinterStatus.decodeErrors([0x00]).isEmpty, "sin errores")
check(PrinterStatus.decodeErrors([0x24]) == ["Poco tóner", "Atasco de papel"], "bits 2 y 5 → poco tóner y atasco")
check(PrinterStatus.decodeErrors([0x00, 0x04]) == ["Bandeja de entrada vacía"], "bit 13 en el segundo byte")
let toner = PrinterSupply(description: "TK-1175", type: 3, level: 10440, max: 12000)
let waste = PrinterSupply(description: "Waste Toner Box", type: 4, level: -3, max: -2)
check(toner.percent == 87 && toner.levelText == "87 %", "tóner 10440/12000 → 87 %")
check(waste.percent == nil && waste.levelText == "OK" && waste.isWaste, "depósito residual con nivel -3 → «OK»")
var pst = PrinterStatus(); pst.supplies = [toner, waste]
check(pst.lowestPercent == 87 && !pst.needsAttention, "87 % no requiere atención")
pst.supplies[0].level = 1200
check(pst.lowestPercent == 10 && pst.needsAttention, "10 % sí requiere atención")

print("Identificación")
var sw2 = dev("192.168.10.8", "EE:00:00:00:00:01")
sw2.snmp = SNMPInfo(name: "SW-CORE.empresa.local", descr: "Cisco IOS Software, C2960S Software (C2960S-UNIVERSALK9-M), Version 15.0(2)SE10, RELEASE SOFTWARE (fc2)\nTechnical Support", model: nil, community: "public", isPrinter: false)
check(sw2.name == "SW-CORE", "sysName sin dominio como nombre")
check(sw2.model == "Cisco IOS Software, C2960S Software (C2960S-UNIVERSALK9-M)", "modelo desde sysDescr: \(sw2.model ?? "nil")")
check(sw2.kind == .network, "sysDescr de Cisco → equipo de red")
var km = dev("192.168.10.9", "EE:00:00:00:00:02", name: "IMP-RECEPCION")
km.snmp = SNMPInfo(name: nil, descr: "KYOCERA Document Solutions Printing System", model: "ECOSYS M2640idw", community: "public", isPrinter: true)
check(km.name == "IMP-RECEPCION" && km.model == "ECOSYS M2640idw" && km.kind == .printer, "NetBIOS manda en el nombre; modelo por SNMP")
var cast = dev("192.168.10.70", nil)
cast.bonjour = BonjourInfo(services: ["_googlecast._tcp"], name: "TV Sala", model: "Chromecast Ultra")
check(cast.name == "TV Sala" && cast.kind == .tv && cast.model == "Chromecast Ultra", "Chromecast por Bonjour → TV con nombre")

// Paquete mDNS de respuesta: PTR _ipp._tcp → instancia, TXT con ty=
func name(_ s: String) -> [UInt8] { s.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0] }
func rr(_ owner: String, _ type: UInt16, _ rdata: [UInt8]) -> [UInt8] {
    name(owner) + [UInt8(type >> 8), UInt8(type & 0xFF), 0, 1, 0, 0, 0x11, 0x94, UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
}
let instance = "Kyocera ECOSYS M2640idw (Sala 3)._ipp._tcp.local"
let txtData = ["txtvers=1", "ty=Kyocera ECOSYS M2640idw", "note=Sala"].flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
let mdns: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0] + rr("_ipp._tcp.local", 12, name(instance)) + rr(instance, 16, txtData)
var bi = BonjourInfo()
Bonjour.merge(into: &bi, mdns)
check(bi.services == ["_ipp._tcp"], "servicio IPP detectado")
check(bi.name == "Kyocera ECOSYS M2640idw (Sala 3)", "nombre de instancia: \(bi.name ?? "nil")")
check(bi.model == "Kyocera ECOSYS M2640idw", "modelo desde TXT ty=")

let airplayTXT = ["md=0,1,2", "model=Mac15,3"].flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) }
let airInst = "MacBook Pro._airplay._tcp.local"
var ai = BonjourInfo()
Bonjour.merge(into: &ai, [0, 0, 0x84, 0, 0, 0, 0, 2, 0, 0, 0, 0] + rr("_airplay._tcp.local", 12, name(airInst)) + rr(airInst, 16, airplayTXT))
check(ai.model == "Mac15,3" && ai.name == "MacBook Pro", "AirPlay: «md» no es el modelo; se usa model= → \(ai.model ?? "nil")")
var sg = dev("192.168.10.33", nil)
sg.snmp = SNMPInfo(name: "SW-PISO-2", descr: "SG350-28P 28-Port Gigabit PoE Managed Switch", model: nil, community: "public", isPrinter: false)
sg.ports = [22, 23, 80, 443]
check(sg.kind == .network, "switch Cisco SG por sysDescr aunque tenga SSH")
check(SSDP.parse("<friendlyName>PC-01</friendlyName><modelName>Windows Media Player</modelName><modelNumber>12</modelNumber>")?.model == nil,
      "UPnP de Windows Media Player no cuenta como modelo")
let xml = "<root><device><friendlyName>Samsung TV Sala</friendlyName><manufacturer>Samsung Electronics</manufacturer><modelName>UN55TU7000</modelName></device></root>"
let up = SSDP.parse(xml)
check(up?.name == "Samsung TV Sala" && up?.manufacturer == "Samsung Electronics" && up?.model == "UN55TU7000", "descripción UPnP")
check(SSDP.header("location", in: "HTTP/1.1 200 OK\r\nLOCATION: http://10.0.0.5:2869/desc.xml\r\nST: x\r\n") == "http://10.0.0.5:2869/desc.xml",
      "cabecera LOCATION sin distinguir mayúsculas")

print(failures == 0 ? "\nTodo OK" : "\n\(failures) fallo(s)")
exit(failures == 0 ? 0 : 1)
