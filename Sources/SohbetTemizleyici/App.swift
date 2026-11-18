import AppKit
import SwiftUI

@main
struct SohbetTemizleyiciApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    init() {
        if let code = CLI.run(CommandLine.arguments) { exit(code) }
    }

    var body: some Scene {
        Window("Sohbet Temizleyici", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 520)
        }
        .defaultSize(width: 1140, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Sohbet Temizleyici Hakkında") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Yeniden Tara") { Task { await Store.shared.rescan() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Button("GitHub Sayfası") { NSWorkspace.shared.open(AboutPanel.projectURL) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            Snapshot.capture(to: URL(fileURLWithPath: args[index + 1]), args: args)
        }
    }
}

/// The standard About panel: icon, name and version from Info.plist, plus a short description and the project link.
@MainActor
enum AboutPanel {
    static let projectURL = URL(string: "https://github.com/kralldepo/claude_arsiv")!

    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        var link = text
        link[.link] = projectURL

        let credits = NSMutableAttributedString(
            string: "Claude'da silinen sohbetlerin Mac'te kalan kayıtlarını temizler ve Code oturumlarını hesaplar arasında taşır.\n\n",
            attributes: text)
        credits.append(NSAttributedString(string: "github.com/kralldepo/claude_arsiv", attributes: link))
        credits.append(NSAttributedString(string: "\n\nAnthropic ile bağlantılı değildir.", attributes: text))

        NSApp.activate()
        // An empty build version hides the "(1)" after "Sürüm 1.0".
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
    }
}

/// Test helper: renders the window into a PNG after the first scan, then quits.
/// Flags: --light / --dark, --caches / --accounts, --select, --about (captures the About panel instead).
@MainActor
enum Snapshot {
    static func capture(to output: URL, args: [String]) {
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        Task { @MainActor in
            let store = Store.shared
            if args.contains("--caches") { store.tab = .caches }
            if args.contains("--accounts") { store.tab = .accounts }
            var waited = 0
            while !store.hasScanned && waited < 200 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            if args.contains("--select") {
                if store.tab == .accounts {
                    let picked = Array(store.visibleSessions.prefix(2))
                    for session in picked { store.setMoveSelected(session, true) }
                    store.targetSlotID = store.primarySlots.first { slot in !picked.contains { $0.slotID == slot.id } }?.id
                } else {
                    for item in store.visible.prefix(3) { store.setSelected(item, true) }
                }
            }
            NSApp.activate()
            let main = NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
            main?.setContentSize(NSSize(width: 1100, height: 680))
            main?.makeKeyAndOrderFront(nil)
            main?.makeFirstResponder(nil)  // no text cursor in the search field
            var tries = 0
            while !NSApp.isActive && tries < 30 {  // an active window draws colored window buttons
                try? await Task.sleep(nanoseconds: 100_000_000)
                tries += 1
            }
            try? await Task.sleep(nanoseconds: 800_000_000)

            var target = main
            if args.contains("--about") {
                AboutPanel.show()
                try? await Task.sleep(nanoseconds: 800_000_000)
                target = NSApp.windows.first { $0 is NSPanel && $0.isVisible } ?? main
            }
            if let window = target, let view = window.contentView?.superview ?? window.contentView {
                // Always 2x, whichever screen the window landed on.
                let size = view.bounds.size
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                    rep.size = size
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output)
                }
            }
            NSApp.terminate(nil)
        }
    }
}
