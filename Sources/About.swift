import SwiftUI
import AppKit

enum AppInfo {
    static let githubUser = "vicvinue"
    static let githubURL = URL(string: "https://github.com/\(githubUser)")!
    static let repoURL = URL(string: "https://github.com/\(githubUser)/RadarIP")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// Logo de GitHub como imagen plantilla (se adapta al modo claro u oscuro).
    static let githubMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "github-mark", withExtension: "pdf"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }()

    /// Ventana «Acerca de» estándar con la versión y el enlace al perfil de GitHub.
    @MainActor static func showAbout() {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: p,
                                                  .foregroundColor: NSColor.secondaryLabelColor]
        let credits = NSMutableAttributedString(string: "Escáner de red local para macOS\n\n", attributes: base)
        if let mark = githubMark {
            let a = NSTextAttachment()
            let tinted = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                mark.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            a.image = tinted
            a.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
            credits.append(NSAttributedString(attachment: a))
            credits.addAttributes(base, range: NSRange(location: credits.length - 1, length: 1))
            credits.append(NSAttributedString(string: " ", attributes: base))
        }
        var link = base
        link[.link] = githubURL
        link[.font] = NSFont.systemFont(ofSize: 11, weight: .medium)
        credits.append(NSAttributedString(string: "github.com/\(githubUser)", attributes: link))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "RadarIP",
            .applicationVersion: "Versión \(version)",
            .version: build,
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Pie de la ventana principal: versión a la izquierda, perfil de GitHub a la derecha.
struct AppFooter: View {
    var body: some View {
        HStack {
            Text("RadarIP \(AppInfo.version)")
                .monospacedDigit()
            Spacer()
            Link(destination: AppInfo.githubURL) {
                HStack(spacing: 5) {
                    if let mark = AppInfo.githubMark {
                        Image(nsImage: mark).resizable().frame(width: 13, height: 13)
                    }
                    Text(AppInfo.githubUser)
                }
            }
            .help("Abrir \(AppInfo.githubURL.absoluteString)")
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
