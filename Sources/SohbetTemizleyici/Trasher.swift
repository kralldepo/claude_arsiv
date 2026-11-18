import Foundation

/// Moves items to the Trash and back. Refuses any path outside the folders this app is meant to clean.
enum Trasher {
    /// Where one file went, so "Geri Al" can put it back.
    struct Restore: Sendable, Hashable {
        let itemID: String
        let original: URL
        let trashed: URL
    }

    struct Outcome: Sendable {
        var trashedIDs: Set<String> = []
        var freed: Int64 = 0
        var skipped: [String] = []
        var failures: [String] = []
        var restorable: [Restore] = []
        var trashedURLs: [URL] { restorable.map(\.trashed) }
    }

    static func trash(_ items: [CleanItem]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        var touchedProjects = Set<URL>()
        let projectsRoot = canonical(Env.projects)

        let allPaths = items.flatMap(\.urls).map(\.path)
        for item in items where !item.isLocked {
            // The conversation may have been reopened since the scan.
            if item.kind == .chat, let transcript = item.urls.first, isRecentlyModified(transcript) {
                outcome.skipped.append(item.title)
                continue
            }
            // A program may have started from these files since the scan.
            if item.kind == .large, LargeFiles.isRunning(item.urls) {
                outcome.skipped.append(item.title)
                continue
            }
            // Files inside another selected row's folder go with that row.
            if item.urls.allSatisfy({ url in allPaths.contains { url.path.hasPrefix($0 + "/") } }) {
                continue
            }
            var allMoved = true
            for url in item.urls where fm.fileExists(atPath: url.path) {
                guard isAllowed(url) else {
                    allMoved = false
                    outcome.failures.append(String(localized: "İzin verilmeyen konum atlandı: \(url.path)"))
                    continue
                }
                do {
                    var resulting: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    if let moved = resulting as URL? {
                        outcome.restorable.append(Restore(itemID: item.id, original: url, trashed: moved))
                    }
                    let parent = url.deletingLastPathComponent()
                    if canonical(parent.deletingLastPathComponent()) == projectsRoot { touchedProjects.insert(parent) }
                } catch {
                    allMoved = false
                    outcome.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if allMoved {
                outcome.trashedIDs.insert(item.id)
                outcome.freed += item.size
            }
        }

        // A project folder we just emptied holds nothing anymore; drop it so the list stays tidy.
        for project in touchedProjects {
            let rest = fm.children(project).filter { $0.lastPathComponent != ".DS_Store" }
            if rest.isEmpty { try? fm.removeItem(at: project) }
        }
        return outcome
    }

    /// Puts trashed files back where they were. Never overwrites: if Claude recreated a folder meanwhile, the Trash copy stays.
    static func restore(_ list: [Restore]) -> (restored: Int, failures: [String]) {
        let fm = FileManager.default
        var restoredIDs = Set<String>()
        var failures: [String] = []
        for entry in list {
            let name = entry.original.lastPathComponent
            guard isAllowed(entry.original) else {
                failures.append(String(localized: "İzin verilmeyen konum atlandı: \(entry.original.path)"))
                continue
            }
            guard fm.fileExists(atPath: entry.trashed.path) else {
                failures.append(String(localized: "\(name) artık Çöp Kutusu'nda değil."))
                continue
            }
            guard !fm.fileExists(atPath: entry.original.path) else {
                failures.append(String(localized: "\(name) eski yerinde yeniden oluşmuş; Çöp Kutusu'ndaki kopya bırakıldı."))
                continue
            }
            do {
                try fm.createDirectory(at: entry.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: entry.trashed, to: entry.original)
                restoredIDs.insert(entry.itemID)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        return (restoredIDs.count, failures)
    }

    static func isRecentlyModified(_ url: URL) -> Bool {
        guard let date = FileManager.default.modDate(url) else { return false }
        return Date().timeIntervalSince(date) < Scanner.inUseWindow
    }

    /// Whitelist of what may ever be moved. Memory notes, settings and Claude's own session index are never touched.
    static func isAllowed(_ url: URL) -> Bool {
        let path = canonical(url)
        let projectsRoot = canonical(Env.projects) + "/"
        if path.hasPrefix(projectsRoot), path.dropFirst(projectsRoot.count).split(separator: "/").contains("memory") {
            return false
        }
        let insideFolders = ["projects", "file-history", "session-env", "tasks", "todos"]
            .map { canonical(Env.claudeDir.appendingPathComponent($0, isDirectory: true)) + "/" }
        if insideFolders.contains(where: { path.hasPrefix($0) }) { return true }
        if LargeFiles.isAllowed(path: path, canonical: canonical) { return true }

        let exact = [
            Env.claudeDir.appendingPathComponent("history.jsonl"),
            Env.caches.appendingPathComponent("claude-cli-nodejs"),
            Env.caches.appendingPathComponent("com.anthropic.claudefordesktop"),
            Env.logs.appendingPathComponent("Claude"),
        ] + Env.desktopCacheDirs.map { Env.appSupport.appendingPathComponent($0) }
        return exact.contains { canonical($0) == path }
    }

    /// Symlink-free path. Only the deepest existing folder is resolved, so a file that was moved to the Trash
    /// gets the same answer as before ("/private/tmp" vs "/tmp" otherwise differs once the file is gone).
    static func canonical(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath().path) { ($0 as NSString).appendingPathComponent($1) }
    }
}
