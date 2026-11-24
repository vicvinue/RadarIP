import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct RadarIPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ScanModel()
    @StateObject private var speed = SpeedTestRunner()

    init() { Diagnostics.runIfRequested() }

    var body: some Scene {
        Window("RadarIP", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 720)

        Window("Inventario", id: "inventory") {
            InventoryView().environmentObject(model)
        }
        .defaultSize(width: 1100, height: 600)

        Window("Impresoras", id: "printers") {
            PrintersView().environmentObject(model)
        }
        .defaultSize(width: 900, height: 640)

        Settings {
            SettingsView().environmentObject(model)
        }

        Window("Mapa de IPs", id: "ipmap") {
            IPMapView().environmentObject(model)
        }
        .defaultSize(width: 900, height: 720)

        Window("Informe de riesgos", id: "risks") {
            RisksView().environmentObject(model)
        }
        .defaultSize(width: 820, height: 640)

        Window("Test de velocidad", id: "speedtest") {
            SpeedTestView().environmentObject(speed)
        }
        .defaultSize(width: 760, height: 680)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Acerca de RadarIP") { AppInfo.showAbout() }
            }
            CommandGroup(replacing: .help) {
                Link("RadarIP en GitHub", destination: AppInfo.repoURL)
                Link("Perfil de \(AppInfo.githubUser) en GitHub", destination: AppInfo.githubURL)
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Escaneo") {
                Button("Escanear") { model.start() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Detener") { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
                Divider()
                OpenWindowButton(title: "Inventario", id: "inventory", key: "i")
                OpenWindowButton(title: "Impresoras", id: "printers", key: "k")
                OpenWindowButton(title: "Mapa de IPs", id: "ipmap", key: "l")
                OpenWindowButton(title: "Informe de riesgos", id: "risks", key: "j")
                OpenWindowButton(title: "Test de velocidad", id: "speedtest", key: "t")
                Divider()
                Button("Volver a detectar interfaces de red") { model.refreshInterfaces() }
                Toggle("Mostrar dispositivos conocidos desconectados", isOn: $model.showKnownOffline)
                Button("Vaciar el inventario") { model.clearKnown() }
            }
        }
    }
}

/// Botón de menú que abre una ventana (los menús son vistas y pueden leer `openWindow`).
struct OpenWindowButton: View {
    let title: String
    let id: String
    let key: KeyEquivalent
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) { openWindow(id: id) }.keyboardShortcut(key)
    }
}
