import Foundation

/// Moves items to the Trash. Refuses any path outside the folders this app is meant to clean.
enum Trasher {
    struct Outcome: Sendable {
        var trashedIDs: Set<String> = []
        var freed: Int64 = 0
        var skipped: [String] = []
        var failures: [String] = []
        var trashedURLs: [URL] = []
    }

    static func trash(_ items: [CleanItem]) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        var touchedProjects = Set<URL>()
        let projectsRoot = canonical(Env.projects)

        for item in items where !item.isLocked {
            // The conversation may have been reopened since the scan.
            if item.kind == .chat, let transcript = item.urls.first, isRecentlyModified(transcript) {
                outcome.skipped.append(item.title)
                continue
            }
            var allMoved = true
            for url in item.urls where fm.fileExists(atPath: url.path) {
                guard isAllowed(url) else {
                    allMoved = false
                    outcome.failures.append("İzin verilmeyen konum atlandı: \(url.path)")
                    continue
                }
                do {
                    var resulting: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    if let moved = resulting as URL? { outcome.trashedURLs.append(moved) }
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

        let exact = [
            Env.claudeDir.appendingPathComponent("history.jsonl"),
            Env.caches.appendingPathComponent("claude-cli-nodejs"),
            Env.caches.appendingPathComponent("com.anthropic.claudefordesktop"),
            Env.logs.appendingPathComponent("Claude"),
        ] + Env.desktopCacheDirs.map { Env.appSupport.appendingPathComponent($0) }
        return exact.contains { canonical($0) == path }
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
