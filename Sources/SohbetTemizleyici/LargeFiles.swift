import Darwin
import Foundation

/// Large downloads Claude keeps and can fetch again. What each one is, and what deleting it costs,
/// was read from Claude's own code (Claude 5.11492.5, Claude Code 2.1.325).
/// Not offered on purpose: the Claude Code copy the desktop app runs (`claude-code`), the version
/// the terminal `claude` command points to, plugin versions in use and the plugin marketplaces.
enum LargeFiles {
    static var vmBundles: URL { Env.appSupport.appendingPathComponent("vm_bundles", isDirectory: true) }
    static var vmBundle: URL { vmBundles.appendingPathComponent("claudevm.bundle", isDirectory: true) }
    static var vmCLI: URL { Env.appSupport.appendingPathComponent("claude-code-vm", isDirectory: true) }
    static var cliVersions: URL { Env.home.appendingPathComponent(".local/share/claude/versions", isDirectory: true) }
    static var cliLink: URL { Env.home.appendingPathComponent(".local/bin/claude") }
    static var cliLocks: URL { Env.home.appendingPathComponent(".local/share/claude/locks", isDirectory: true) }
    static var pluginCache: URL { Env.claudeDir.appendingPathComponent("plugins/cache", isDirectory: true) }
    static var pluginTrash: URL { Env.claudeDir.appendingPathComponent("plugins/.trash", isDirectory: true) }

    static func scan(claudeRunning: Bool) -> [CleanItem] {
        let fm = FileManager.default
        var items: [CleanItem] = []

        // Cowork's Linux VM and the Claude Code copy that runs inside it. Claude downloads both again when
        // Cowork starts; with the bundle gone it skips the background download.
        let vmParts = [vmBundles, vmCLI].filter { fm.fileExists(atPath: $0.path) }
        let vmSize = vmParts.reduce(Int64(0)) { $0 + fm.allocatedSize($1) }
        if vmSize > 0 {
            items.append(CleanItem(
                id: "large:cowork", kind: .large, title: String(localized: "Cowork sanal makinesi"),
                detail: String(localized: "vm_bundles ve claude-code-vm: Cowork'ün Linux sanal makinesi"),
                date: latest(vmParts), size: vmSize, status: claudeRunning ? .needsQuit : .cleanable, urls: vmParts,
                preview: vmParts.map { prettyPath($0.path) }.joined(separator: "\n"),
                warning: String(localized: "Cowork sanal makinesi: Cowork bir sonraki kullanımda yaklaşık 1,3 GB indirir ve 15 GB boş alan ister. Cowork'ün oturum diski de silinir."),
                needsClaudeClosed: true))
        }

        // Compressed copies kept for offline rebuilds and small updates. The VM keeps working without them.
        let compressed = fm.children(vmBundle).filter { $0.pathExtension == "zst" }
        let compressedSize = compressed.reduce(Int64(0)) { $0 + fm.allocatedSize($1) }
        if compressedSize > 0 {
            items.append(CleanItem(
                id: "large:cowork-zst", kind: .large, title: String(localized: "Cowork sıkıştırılmış kopyaları"),
                detail: String(localized: "claudevm.bundle içindeki \(compressed.count) .zst dosyası; sanal makine çalışmaya devam eder"),
                date: latest(compressed), size: compressedSize, status: claudeRunning ? .needsQuit : .cleanable, urls: compressed,
                preview: compressed.map(\.lastPathComponent).joined(separator: "\n"),
                warning: String(localized: "Cowork sıkıştırılmış kopyaları: bir sonraki Cowork güncellemesi veya yeniden kurulumu tam indirme gerektirir."),
                needsClaudeClosed: true))
        }

        // Fallback versions of the terminal `claude` command. Claude Code keeps two and deletes older ones itself.
        let old = oldCLIVersions()
        if !old.isEmpty, let current = currentCLIVersion() {
            let names = old.map(\.lastPathComponent).sorted().joined(separator: ", ")
            items.append(CleanItem(
                id: "large:cli-versions", kind: .large, title: String(localized: "Eski Claude Code sürümleri"),
                detail: String(localized: "Terminaldeki claude komutunun yedekleri: \(names) (kullanılan: \(current))"),
                date: latest(old), size: old.reduce(Int64(0)) { $0 + fm.allocatedSize($1) }, status: .cleanable, urls: old,
                preview: old.map { prettyPath($0.path) }.joined(separator: "\n"),
                warning: String(localized: "Eski Claude Code sürümleri: Claude Code bunları güncellemelerde zaten kendisi siler; silerseniz geri dönülecek yedek sürüm kalmaz.")))
        }

        // Plugin versions Claude Code marked unused (it deletes them after 14 days), plus its plugin trash.
        var plugins: [URL] = []
        for market in fm.children(pluginCache) where fm.isDir(market) {
            for plugin in fm.children(market) where fm.isDir(plugin) {
                for version in fm.children(plugin) where fm.isDir(version) {
                    let marker = version.appendingPathComponent(".orphaned_at")
                    if let marked = fm.modDate(marker), Date().timeIntervalSince(marked) > 86_400 { plugins.append(version) }
                }
            }
        }
        if fm.allocatedSize(pluginTrash) > 0 { plugins.append(pluginTrash) }
        let pluginSize = plugins.reduce(Int64(0)) { $0 + fm.allocatedSize($1) }
        if pluginSize > 0 {
            items.append(CleanItem(
                id: "large:plugins", kind: .large, title: String(localized: "Kullanılmayan eklenti dosyaları"),
                detail: String(localized: "~/.claude/plugins: kullanılmayan sürümler ve silinmeyi bekleyenler"),
                date: latest(plugins), size: pluginSize, status: .cleanable, urls: plugins,
                preview: plugins.map { prettyPath($0.path) }.joined(separator: "\n"),
                warning: String(localized: "Kullanılmayan eklenti dosyaları: Claude Code bunları birkaç gün içinde zaten kendisi siler.")))
        }
        return items
    }

    /// Version the terminal `claude` command runs, read from its link. Nil when there is no link.
    static func currentCLIVersion() -> String? {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) != nil else { return nil }
        return cliLink.resolvingSymlinksInPath().lastPathComponent
    }

    /// Versions that are neither linked, locked nor running. Empty when the current version is unknown.
    static func oldCLIVersions() -> [URL] {
        let fm = FileManager.default
        guard let current = currentCLIVersion(), fm.fileExists(atPath: cliVersions.appendingPathComponent(current).path) else { return [] }
        let locks = fm.children(cliLocks).map(\.lastPathComponent)
        let running = Processes.executablePaths()
        return fm.children(cliVersions).filter { version in
            let name = version.lastPathComponent
            return name != current && !name.hasPrefix(".")
                && !locks.contains { $0.hasPrefix(name) }
                && !running.contains { $0 == version.path || $0.hasPrefix(version.path + "/") }
        }
    }

    /// True when a program is running from one of these paths right now.
    static func isRunning(_ urls: [URL]) -> Bool {
        let running = Processes.executablePaths()
        return urls.contains { url in running.contains { $0 == url.path || $0.hasPrefix(url.path + "/") } }
    }

    /// The only large-file paths the Trash may receive. The linked CLI version is refused even if asked.
    static func isAllowed(path: String, canonical: (URL) -> String) -> Bool {
        if [vmBundles, vmCLI, pluginTrash].contains(where: { canonical($0) == path }) { return true }
        let bundle = canonical(vmBundle) + "/"
        if path.hasPrefix(bundle), !path.dropFirst(bundle.count).contains("/"), path.hasSuffix(".zst") { return true }
        let versions = canonical(cliVersions) + "/"
        if path.hasPrefix(versions), !path.dropFirst(versions.count).contains("/") {
            guard let current = currentCLIVersion() else { return false }
            return (path as NSString).lastPathComponent != current
        }
        let cache = canonical(pluginCache) + "/"
        return path.hasPrefix(cache) && path.dropFirst(cache.count).split(separator: "/").count == 3
    }

    private static func latest(_ urls: [URL]) -> Date {
        urls.compactMap { FileManager.default.modDate($0) }.max() ?? .distantPast
    }
}

/// Executable paths of the processes this user can see.
enum Processes {
    static func executablePaths() -> Set<String> {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var paths = Set<String>()
        for pid in pids.prefix(max(0, filled)) where pid > 0 {
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                paths.insert(String(cString: buffer))
            }
        }
        return paths
    }
}
