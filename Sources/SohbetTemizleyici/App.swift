import AppKit
import SwiftUI
import UserNotifications

@main
struct SohbetTemizleyiciApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Not observed here on purpose: if every Store change rebuilt the scenes, MenuBarExtra would write its
    /// binding back during each rebuild and the two would update each other forever (a crash at launch).
    private let store = Store.shared
    /// Same key Store saves to, so only a real change of this one setting rebuilds the scenes.
    @AppStorage("showInMenuBar") private var menuBarShown = false

    init() {
        if let code = CLI.run(CommandLine.arguments) { exit(code) }
    }

    var body: some Scene {
        Window("Sohbet Temizleyici", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Sohbet Temizleyici Hakkında") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Yeniden Tara") { Task { await Store.shared.rescan() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .undoRedo) {
                UndoMenuItem()
            }
            CommandGroup(replacing: .help) {
                Button("GitHub Sayfası") { NSWorkspace.shared.open(AboutPanel.projectURL) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }

        // Writes go through Store only when the value really changes (the user turned it off in Settings
        // or dragged the icon out of the menu bar); SwiftUI writing back the same value does nothing.
        MenuBarExtra(isInserted: Binding(
            get: { menuBarShown },
            set: { shown in
                if shown != Store.shared.showInMenuBar { Store.shared.showInMenuBar = shown }
            }
        )) {
            MenuBarContent()
                .environmentObject(store)
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
    }
}

/// Edit menu item; it watches the Store itself so the App's scenes do not have to.
private struct UndoMenuItem: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        Button("Son Silmeyi Geri Al") { Task { await store.undoLastTrash() } }
            .disabled(store.lastTrash.isEmpty)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// With the menu bar item on, closing the window keeps the app running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Store.shared.showInMenuBar
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // A menu bar app without a window needs no Dock icon; opening the window brings it back.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            MainActor.assumeIsolated {
                if Store.shared.showInMenuBar { NSApp.setActivationPolicy(.accessory) }
            }
        }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            Snapshot.capture(to: URL(fileURLWithPath: args[index + 1]), args: args)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in Store.shared.showMainWindow() }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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
            string: String(localized: "Claude'da silinen sohbetlerin Mac'te kalan kayıtlarını temizler, arşivler ve Code oturumlarını hesaplar arasında taşır.") + "\n\n",
            attributes: text)
        credits.append(NSAttributedString(string: "github.com/kralldepo/claude_arsiv", attributes: link))
        credits.append(NSAttributedString(string: "\n\n" + String(localized: "Anthropic ile bağlantılı değildir."), attributes: text))

        NSApp.activate()
        // An empty build version hides the "(2)" after "Sürüm 1.1".
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
    }
}

/// Test helper: renders a window into a PNG after the first scan, then quits.
/// Flags: --light / --dark, --caches / --large / --accounts, --select,
/// --about (the About panel), --settings (the Settings window) or --preview (the first chat's reading sheet).
@MainActor
enum Snapshot {
    static func capture(to output: URL, args: [String]) {
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        Task { @MainActor in
            let store = Store.shared
            if args.contains("--caches") { store.tab = .caches }
            if args.contains("--large") { store.tab = .large }
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
            let main = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
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
            if args.contains("--preview"), let chat = store.visible.first(where: { $0.kind == .chat }) {
                store.previewItem = chat
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                target = main?.attachedSheet ?? main
            } else if args.contains("--about") {
                AboutPanel.show()
                try? await Task.sleep(nanoseconds: 800_000_000)
                target = NSApp.windows.first { $0 is NSPanel && $0.isVisible } ?? main
            } else if args.contains("--settings") {
                store.openSettingsWindow?()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                target = NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true } ?? main
                target?.makeKeyAndOrderFront(nil)
                target?.makeFirstResponder(nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
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
