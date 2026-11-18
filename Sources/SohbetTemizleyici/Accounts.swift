import Foundation

/// One Claude account + organization folder under claude-code-sessions.
/// The Claude desktop app shows a session in whichever account/org folder its record file sits in.
struct AccountSlot: Identifiable, Hashable, Sendable {
    let accountID: String
    let orgID: String
    let dir: URL
    let sessionCount: Int
    let lastUsed: Date
    let isCurrentAccount: Bool

    var id: String { accountID + "/" + orgID }
}

/// A conversation as the Claude desktop app lists it: one local_<id>.json record.
/// The conversation itself lives in ~/.claude/projects and is shared by every account.
struct DesktopSession: Identifiable, Hashable, Sendable {
    let file: URL
    let localID: String
    let title: String
    let place: String
    let lastActivity: Date
    let isArchived: Bool
    let hasWorktree: Bool
    let accountID: String
    let orgID: String

    var id: String { file.path }
    var slotID: String { accountID + "/" + orgID }
}

/// Reads the account folders. Read-only.
enum AccountScanner {
    static func scan() -> (slots: [AccountSlot], sessions: [DesktopSession]) {
        let fm = FileManager.default
        let current = currentAccountID()
        var slots: [AccountSlot] = []
        var sessions: [DesktopSession] = []
        for account in fm.children(Env.desktopSessions) where fm.isDir(account) && isUUID(account.lastPathComponent) {
            for org in fm.children(account) where fm.isDir(org) && isUUID(org.lastPathComponent) {
                let archived = ArchivedHint.read(org)?.ids ?? []
                var found: [DesktopSession] = []
                for file in fm.children(org) where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let record = readJSON(file) else { continue }
                    let localID = file.deletingPathExtension().lastPathComponent
                    let cwd = record["cwd"] as? String ?? ""
                    // Worktree folders can be cleaned up by Claude when it thinks no session owns them; keep those sessions put.
                    let hasWorktree = !((record["worktreePath"] as? String) ?? "").isEmpty || cwd.contains("/.claude/worktrees/")
                    found.append(DesktopSession(
                        file: file,
                        localID: localID,
                        title: (record["title"] as? String)?.oneLine.nonEmpty ?? "Başlıksız oturum",
                        place: cwd.isEmpty ? "" : prettyPath(cwd),
                        lastActivity: activityDate(record) ?? fm.modDate(file) ?? .distantPast,
                        isArchived: (record["isArchived"] as? Bool ?? false) || archived.contains(localID),
                        hasWorktree: hasWorktree,
                        accountID: account.lastPathComponent,
                        orgID: org.lastPathComponent
                    ))
                }
                var dates = found.map(\.lastActivity)
                if let touched = fm.modDate(org) { dates.append(touched) }
                slots.append(AccountSlot(
                    accountID: account.lastPathComponent,
                    orgID: org.lastPathComponent,
                    dir: org,
                    sessionCount: found.count,
                    lastUsed: dates.max() ?? .distantPast,
                    isCurrentAccount: account.lastPathComponent == current
                ))
                sessions += found
            }
        }
        return (slots, sessions)
    }

    /// The account Claude was signed in to last.
    static func currentAccountID() -> String? {
        readJSON(Env.appSupport.appendingPathComponent("config.json"))?["lastKnownAccountUuid"] as? String
    }

    private static func activityDate(_ record: [String: Any]) -> Date? {
        let stamps = ["lastActivityAt", "lastFocusedAt", "createdAt"].compactMap { (record[$0] as? NSNumber)?.doubleValue }
        guard let newest = stamps.max(), newest > 0 else { return nil }
        return Date(timeIntervalSince1970: newest / 1000)
    }
}

/// archived-sessions.idx: Claude's hint file listing archived sessions, {"v":1,"archived":["local_…"]}.
struct ArchivedHint {
    var version: Int
    var ids: Set<String>

    static func url(_ org: URL) -> URL { org.appendingPathComponent("archived-sessions.idx") }

    static func read(_ org: URL) -> ArchivedHint? {
        guard let obj = readJSON(url(org)), let list = obj["archived"] as? [String] else { return nil }
        return ArchivedHint(version: obj["v"] as? Int ?? 1, ids: Set(list))
    }

    func write(_ org: URL) throws {
        let list = try JSONSerialization.data(withJSONObject: ids.sorted(), options: [.withoutEscapingSlashes])
        let text = "{\"v\":\(version),\"archived\":" + String(decoding: list, as: UTF8.self) + "}"
        try Data(text.utf8).write(to: ArchivedHint.url(org), options: .atomic)
    }
}

/// Moves session records from one account folder to another. Claude must be closed: it rewrites records while open.
enum AccountMover {
    struct Outcome: Sendable {
        var moved: [String] = []
        var failures: [String] = []
        var trashedURLs: [URL] = []
    }

    /// Error state that belonged to the old account; the session starts clean in the new one.
    static let resetKeys = ["priorErrorMark", "error", "errorAt", "errorRows", "connectionTriesSincePerson"]

    static func move(_ sessions: [DesktopSession], to slot: AccountSlot) -> Outcome {
        let fm = FileManager.default
        var outcome = Outcome()
        for session in sessions where session.slotID != slot.id {
            let sourceOrg = session.file.deletingLastPathComponent()
            let target = slot.dir.appendingPathComponent(session.file.lastPathComponent)
            guard !session.hasWorktree else {
                outcome.failures.append("\(session.title): çalışma ağacında (worktree) açılmış oturumlar taşınmaz")
                continue
            }
            guard isSessionRecord(session.file), isSessionRecord(target) else {
                outcome.failures.append("\(session.title): izin verilmeyen konum")
                continue
            }
            guard !fm.fileExists(atPath: target.path) else {
                outcome.failures.append("\(session.title): hedef hesapta aynı kayıt zaten var")
                continue
            }
            do {
                let original = try Data(contentsOf: session.file)
                guard var record = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                for key in resetKeys { record.removeValue(forKey: key) }
                let data = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
                try data.write(to: target, options: .atomic)
                if let permissions = try? fm.attributesOfItem(atPath: session.file.path)[.posixPermissions] {
                    try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
                }
                do {
                    var trashed: NSURL?
                    try fm.trashItem(at: session.file, resultingItemURL: &trashed)
                    if let moved = trashed as URL? { outcome.trashedURLs.append(moved) }
                } catch {
                    // Never leave one conversation listed in two accounts.
                    try? fm.removeItem(at: target)
                    throw error
                }
                moveArchivedHint(session.localID, from: sourceOrg, to: slot.dir)
                outcome.moved.append(session.title)
            } catch {
                outcome.failures.append("\(session.title): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    private static func moveArchivedHint(_ localID: String, from source: URL, to target: URL) {
        guard var hint = ArchivedHint.read(source), hint.ids.contains(localID) else { return }
        hint.ids.remove(localID)
        try? hint.write(source)
        var destination = ArchivedHint.read(target) ?? ArchivedHint(version: hint.version, ids: [])
        destination.ids.insert(localID)
        try? destination.write(target)
    }

    /// Only local_<id>.json files exactly two folders below claude-code-sessions.
    private static func isSessionRecord(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("local_"), name.hasSuffix(".json") else { return false }
        let org = url.deletingLastPathComponent()
        let account = org.deletingLastPathComponent()
        return isUUID(org.lastPathComponent) && isUUID(account.lastPathComponent)
            && account.deletingLastPathComponent().standardizedFileURL.path == Env.desktopSessions.standardizedFileURL.path
    }
}
