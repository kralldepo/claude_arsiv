import AppKit
import Foundation

/// Where Claude keeps its files. `SOHBET_HOME` points the app at a fake home folder (tests only).
enum Env {
    static let home: URL = {
        let custom = ProcessInfo.processInfo.environment["SOHBET_HOME"] ?? ""
        if !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    static let isTestHome = !(ProcessInfo.processInfo.environment["SOHBET_HOME"] ?? "").isEmpty

    static let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
    static let projects = claudeDir.appendingPathComponent("projects", isDirectory: true)
    static let appSupport = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    static let desktopSessions = appSupport.appendingPathComponent("claude-code-sessions", isDirectory: true)
    static let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
    static let logs = home.appendingPathComponent("Library/Logs", isDirectory: true)

    static let claudeBundleID = "com.anthropic.claudefordesktop"
    /// Per-session folders Claude Code keeps outside the transcript, named by session id.
    static let sessionSideDirs = ["file-history", "session-env", "tasks"]
    /// Electron cache folders inside Claude's Application Support folder.
    static let desktopCacheDirs = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache"]
}

/// True while the Claude desktop app runs. With a fake home, `SOHBET_CLAUDE_RUNNING=0/1` overrides it (screenshots, tests).
func isClaudeRunning() -> Bool {
    if Env.isTestHome, let forced = ProcessInfo.processInfo.environment["SOHBET_CLAUDE_RUNNING"] {
        return forced == "1"
    }
    return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Env.claudeBundleID }
}

/// Builds the list of things the app can clean. Read-only: it never changes a file.
struct Scanner {
    /// Anything written to more recently than this is treated as an open session.
    static let inUseWindow: TimeInterval = 30 * 60

    private let fm = FileManager.default
    private let now = Date()

    func scan(claudeRunning: Bool) -> [CleanItem] {
        let desktop = DesktopIndex.load()
        var transcriptIDs = Set<String>()
        var items = scanChats(desktop: desktop, transcriptIDs: &transcriptIDs)
        items += scanCaches(claudeRunning: claudeRunning)
        items += LargeFiles.scan(claudeRunning: claudeRunning)
        if let orphans = scanOrphans(transcriptIDs: transcriptIDs, desktop: desktop) {
            items.append(orphans)
        }
        return items
    }

    // MARK: Conversations

    private func scanChats(desktop: DesktopIndex, transcriptIDs: inout Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let todos = todoFiles()
        for project in fm.children(Env.projects) where fm.isDir(project) {
            for file in fm.children(project) where file.pathExtension == "jsonl" {
                let sid = file.deletingPathExtension().lastPathComponent.lowercased()
                guard isUUID(sid) else { continue }
                transcriptIDs.insert(sid)
                items.append(chatItem(sid: sid, file: file, project: project, desktop: desktop, todos: todos[sid] ?? []))
            }
        }
        return items
    }

    private func chatItem(sid: String, file: URL, project: URL, desktop: DesktopIndex, todos: [URL]) -> CleanItem {
        var urls = [file]
        let companion = project.appendingPathComponent(sid, isDirectory: true)
        let hasCompanion = fm.isDir(companion)
        if hasCompanion { urls.append(companion) }
        for side in Env.sessionSideDirs {
            let dir = Env.claudeDir.appendingPathComponent(side, isDirectory: true).appendingPathComponent(sid, isDirectory: true)
            if fm.fileExists(atPath: dir.path) { urls.append(dir) }
        }
        urls += todos

        let modified = fm.modDate(file) ?? .distantPast
        let lastTouch = max(modified, hasCompanion ? (fm.modDate(companion) ?? .distantPast) : .distantPast)

        let known = desktop.byCLI[sid]
        let status: ItemStatus
        if let known {
            status = known.archived ? .archived : .active
        } else if desktop.mentioned.contains(sid) {
            status = .active
        } else if now.timeIntervalSince(lastTouch) < Self.inUseWindow {
            status = .inUse
        } else {
            status = .leftover
        }

        let peek = TranscriptPeek.read(file)
        let titleFile = hasCompanion
            ? readJSON(companion.appendingPathComponent("custom-title.json"))?["customTitle"] as? String
            : nil
        let title = [known?.title, titleFile, peek.customTitle, peek.aiTitle, peek.agentName, peek.summary, peek.firstPrompt]
            .compactMap { $0?.oneLine.nonEmpty }
            .first ?? String(localized: "Başlıksız sohbet")

        var place = peek.cwd.map(prettyPath) ?? decodeProjectFolder(project.lastPathComponent)
        if project.lastPathComponent.hasPrefix("ssh-") { place = "SSH · " + place }

        return CleanItem(
            id: file.path, kind: .chat, title: title, detail: place, date: modified,
            size: urls.reduce(Int64(0)) { $0 + fm.allocatedSize($1) }, status: status, urls: urls,
            preview: peek.firstPrompt.map { String(localized: "İlk mesaj: \($0.clipped(500))") },
            project: project.lastPathComponent
        )
    }

    // MARK: Caches and logs

    private func scanCaches(claudeRunning: Bool) -> [CleanItem] {
        struct Spec {
            let key: String
            let title: String
            let detail: String
            let urls: [URL]
            let needsQuit: Bool
        }
        let specs = [
            Spec(key: "app", title: String(localized: "Claude uygulama önbelleği"),
                 detail: String(localized: "Web ve grafik önbellekleri; Claude açılınca yeniden oluşur"),
                 urls: Env.desktopCacheDirs.map { Env.appSupport.appendingPathComponent($0, isDirectory: true) }
                     + [Env.caches.appendingPathComponent("com.anthropic.claudefordesktop", isDirectory: true)],
                 needsQuit: true),
            Spec(key: "logs", title: String(localized: "Claude günlük kayıtları"),
                 detail: "~/Library/Logs/Claude",
                 urls: [Env.logs.appendingPathComponent("Claude", isDirectory: true)],
                 needsQuit: true),
            Spec(key: "cli", title: String(localized: "Claude Code önbelleği"),
                 detail: String(localized: "~/Library/Caches/claude-cli-nodejs (MCP günlükleri vb.)"),
                 urls: [Env.caches.appendingPathComponent("claude-cli-nodejs", isDirectory: true)],
                 needsQuit: true),
            Spec(key: "history", title: String(localized: "Claude Code istem geçmişi"),
                 detail: String(localized: "~/.claude/history.jsonl: terminalde yazdığınız istemlerin listesi"),
                 urls: [Env.claudeDir.appendingPathComponent("history.jsonl")],
                 needsQuit: false),
        ]
        return specs.compactMap { spec -> CleanItem? in
            let existing = spec.urls.filter { fm.fileExists(atPath: $0.path) }
            let size = existing.reduce(Int64(0)) { $0 + fm.allocatedSize($1) }
            guard size > 0 else { return nil }
            return CleanItem(
                id: "cache:" + spec.key, kind: .cache, title: spec.title, detail: spec.detail,
                date: existing.compactMap { fm.modDate($0) }.max() ?? .distantPast,
                size: size, status: spec.needsQuit && claudeRunning ? .needsQuit : .cleanable, urls: existing,
                preview: existing.map { prettyPath($0.path) }.joined(separator: "\n"),
                needsClaudeClosed: spec.needsQuit
            )
        }
    }

    /// Session side folders whose conversation no longer exists anywhere.
    private func scanOrphans(transcriptIDs: Set<String>, desktop: DesktopIndex) -> CleanItem? {
        var urls: [URL] = []
        func consider(_ url: URL, sid rawID: String) {
            let sid = rawID.lowercased()
            guard isUUID(sid), !transcriptIDs.contains(sid), desktop.byCLI[sid] == nil,
                  !desktop.mentioned.contains(sid),
                  let touched = fm.modDate(url), now.timeIntervalSince(touched) >= Self.inUseWindow
            else { return }
            urls.append(url)
        }
        for side in Env.sessionSideDirs {
            for dir in fm.children(Env.claudeDir.appendingPathComponent(side, isDirectory: true)) {
                consider(dir, sid: dir.lastPathComponent)
            }
        }
        for (sid, files) in todoFiles() {
            for file in files { consider(file, sid: sid) }
        }
        for project in fm.children(Env.projects) where fm.isDir(project) {
            for entry in fm.children(project) where fm.isDir(entry) {
                consider(entry, sid: entry.lastPathComponent)
            }
        }
        guard !urls.isEmpty else { return nil }
        let listed = urls.prefix(12).map { prettyPath($0.path) }.joined(separator: "\n")
        return CleanItem(
            id: "cache:orphans", kind: .cache, title: String(localized: "Sahipsiz oturum dosyaları"),
            detail: String(localized: "Sohbeti artık olmayan oturumlardan kalan \(urls.count) klasör (dosya yedekleri, alt ajan kayıtları)"),
            date: urls.compactMap { fm.modDate($0) }.max() ?? .distantPast,
            size: urls.reduce(Int64(0)) { $0 + fm.allocatedSize($1) }, status: .cleanable, urls: urls,
            preview: urls.count > 12 ? listed + "\n…" : listed
        )
    }

    private func todoFiles() -> [String: [URL]] {
        var map: [String: [URL]] = [:]
        for file in fm.children(Env.claudeDir.appendingPathComponent("todos", isDirectory: true)) where file.pathExtension == "json" {
            let sid = String(file.lastPathComponent.prefix(36)).lowercased()
            if isUUID(sid) { map[sid, default: []].append(file) }
        }
        return map
    }
}

/// What the Claude desktop app still lists (sidebar and archive).
struct DesktopIndex {
    struct Session {
        let title: String?
        let archived: Bool
    }

    /// Keyed by Claude Code session id, which is also the transcript's file name.
    private(set) var byCLI: [String: Session] = [:]
    /// Every id that appears anywhere in a live session file. These are always protected.
    private(set) var mentioned: Set<String> = []

    static func load() -> DesktopIndex {
        var index = DesktopIndex()
        let fm = FileManager.default
        for account in fm.children(Env.desktopSessions) where fm.isDir(account) {
            for org in fm.children(account) where fm.isDir(org) {
                let archivedIDs = Set(readJSON(org.appendingPathComponent("archived-sessions.idx"))?["archived"] as? [String] ?? [])
                for file in fm.children(org) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let obj = readJSON(file) else { continue }
                    let localID = obj["sessionId"] as? String ?? file.deletingPathExtension().lastPathComponent
                    let bareID = localID.hasPrefix("local_") ? String(localID.dropFirst(6)) : localID
                    let cliID = ((obj["cliSessionId"] as? String) ?? bareID).lowercased()
                    let archived = (obj["isArchived"] as? Bool ?? false) || archivedIDs.contains(localID)
                    index.byCLI[cliID] = Session(title: (obj["title"] as? String)?.oneLine.nonEmpty, archived: archived)
                    collectUUIDs(in: obj, into: &index.mentioned)
                }
            }
        }
        return index
    }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    private static func collectUUIDs(in value: Any, into ids: inout Set<String>) {
        if let text = value as? String {
            let ns = text as NSString
            guard ns.length >= 36 else { return }
            for match in uuidPattern.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 50_000))) {
                ids.insert(ns.substring(with: match.range).lowercased())
            }
        } else if let dict = value as? [String: Any] {
            for child in dict.values { collectUUIDs(in: child, into: &ids) }
        } else if let list = value as? [Any] {
            for child in list { collectUUIDs(in: child, into: &ids) }
        }
    }
}

/// Reads only the start and the end of a transcript to find its title, folder and first prompt.
struct TranscriptPeek {
    var cwd: String?
    var firstPrompt: String?
    var customTitle: String?
    var aiTitle: String?
    var agentName: String?
    var summary: String?

    private static let headBytes = 512 * 1024
    private static let tailBytes = 256 * 1024
    private static let titleMarkers = ["\"custom-title\"", "\"ai-title\"", "\"agent-name\"", "\"summary\""].map { Data($0.utf8) }
    private static let reminder = try! NSRegularExpression(pattern: "<system-reminder>[\\s\\S]*?</system-reminder>")

    static func read(_ url: URL) -> TranscriptPeek {
        var peek = TranscriptPeek()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return peek }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        peek.consume(head, wantsMeta: true)
        if let end = try? handle.seekToEnd(), end > UInt64(head.count) {
            let start = max(UInt64(head.count), end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0)
            try? handle.seek(toOffset: start)
            if let tail = try? handle.readToEnd() { peek.consume(tail, wantsMeta: false) }
        }
        return peek
    }

    private mutating func consume(_ data: Data, wantsMeta: Bool) {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let needMeta = wantsMeta && (cwd == nil || firstPrompt == nil)
            guard needMeta || Self.titleMarkers.contains(where: { line.range(of: $0) != nil }) else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            switch type {
            case "custom-title": customTitle = (obj["customTitle"] as? String) ?? customTitle
            case "ai-title": aiTitle = (obj["aiTitle"] as? String) ?? aiTitle
            case "agent-name": agentName = (obj["agentName"] as? String) ?? agentName
            case "summary": summary = summary ?? (obj["summary"] as? String)
            default: break
            }
            if cwd == nil, let dir = obj["cwd"] as? String, !dir.isEmpty { cwd = dir }
            if firstPrompt == nil, type == "user",
               (obj["isMeta"] as? Bool) != true, (obj["isSidechain"] as? Bool) != true {
                firstPrompt = Self.promptText(obj)
            }
        }
    }

    private static func promptText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        var texts: [String] = []
        if let text = message["content"] as? String {
            texts = [text]
        } else if let blocks = message["content"] as? [[String: Any]] {
            texts = blocks.compactMap { (($0["type"] as? String) == "text") ? ($0["text"] as? String) : nil }
        }
        for raw in texts {
            let range = NSRange(location: 0, length: (raw as NSString).length)
            let text = reminder.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isNoise = text.isEmpty || text.hasPrefix("<") || text.hasPrefix("Caveat:") || text.hasPrefix("[Request interrupted")
            if !isNoise { return text }
        }
        return nil
    }
}

// MARK: Helpers

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func isUUID(_ text: String) -> Bool {
    text.utf8.count == 36 && UUID(uuidString: text) != nil
}

func prettyPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// "-Users-ali-Projeler-x" → "~/Projeler/x". Dashes inside folder names get lost, so this is a best guess.
func decodeProjectFolder(_ name: String) -> String {
    guard name.hasPrefix("-") else { return name }
    return prettyPath(name.replacingOccurrences(of: "-", with: "/"))
}

extension FileManager {
    func children(_ url: URL) -> [URL] {
        (try? contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    }

    func isDir(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Uncached modification date, so a re-check right before deleting sees fresh data.
    func modDate(_ url: URL) -> Date? {
        (try? attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Bytes on disk for a file, or for everything inside a folder.
    func allocatedSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func bytes(_ file: URL) -> Int64 {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard isDir(url) else { return bytes(url) }
        var total: Int64 = 0
        if let walker = enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let file as URL in walker { total += bytes(file) }
        }
        return total
    }
}
