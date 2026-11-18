import Foundation

/// Command-line modes for checking the app without opening the window.
enum CLI {
    /// Returns an exit code when a command-line mode ran; nil starts the normal app.
    static func run(_ args: [String]) -> Int32? {
        if args.contains("--report") {
            report(verbose: args.contains("--verbose"))
            return 0
        }
        if args.contains("--test-trash") {
            return testTrash()
        }
        if let index = args.firstIndex(of: "--test-move"), index + 2 < args.count {
            return testMove(localID: args[index + 1], slotID: args[index + 2])
        }
        if let index = args.firstIndex(of: "--test-archive"), index + 1 < args.count {
            return testArchive(to: URL(fileURLWithPath: args[index + 1], isDirectory: true))
        }
        if let index = args.firstIndex(of: "--test-search"), index + 1 < args.count {
            return testSearch(args[index + 1])
        }
        if args.contains("--test-undo") {
            return testUndo()
        }
        if let index = args.firstIndex(of: "--test-allowed"), index + 1 < args.count {
            guard requireTestHome("--test-allowed") else { return 2 }
            print("allowed=\(Trasher.isAllowed(URL(fileURLWithPath: args[index + 1])))")
            return 0
        }
        return nil
    }

    private static func requireTestHome(_ flag: String) -> Bool {
        guard Env.isTestHome else {
            FileHandle.standardError.write(Data("\(flag) yalnızca SOHBET_HOME ile çalışır.\n".utf8))
            return false
        }
        return true
    }

    /// Writes every chat in the fake home as Markdown into a folder.
    private static func testArchive(to folder: URL) -> Int32 {
        guard requireTestHome("--test-archive") else { return 2 }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chats = Scanner().scan(claudeRunning: false).filter { $0.kind == .chat }
        let outcome = Archiver.archive(chats, to: folder)
        print("archived=\(outcome.written.count) failures=\(outcome.failures.count)")
        for url in outcome.written { print("WROTE\t\(url.lastPathComponent)") }
        for failure in outcome.failures { print("FAIL\t\(failure)") }
        return outcome.failures.isEmpty ? 0 : 1
    }

    /// Prints the chats whose messages contain a text, using the same index as the window.
    private static func testSearch(_ text: String) -> Int32 {
        guard requireTestHome("--test-search") else { return 2 }
        final class Box: @unchecked Sendable { var found = Set<String>() }
        let chats = Scanner().scan(claudeRunning: false).filter { $0.kind == .chat }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.found = await ContentIndex().matches(text, in: chats)
            done.signal()
        }
        done.wait()
        print("matches=\(box.found.count) of \(chats.count)")
        for chat in chats where box.found.contains(chat.id) { print("MATCH\t\(chat.title)") }
        return 0
    }

    /// Trashes every unlocked item, then puts everything back, and checks nothing is missing.
    private static func testUndo() -> Int32 {
        guard requireTestHome("--test-undo") else { return 2 }
        let fm = FileManager.default
        let items = Scanner().scan(claudeRunning: false).filter { !$0.isLocked }
        let before = items.flatMap(\.urls).filter { fm.fileExists(atPath: $0.path) }
        let outcome = Trasher.trash(items)
        let gone = before.filter { !fm.fileExists(atPath: $0.path) }.count
        let result = Trasher.restore(outcome.restorable)
        let back = before.filter { fm.fileExists(atPath: $0.path) }.count
        print("trashed=\(outcome.trashedIDs.count) paths=\(before.count) gone=\(gone) restoredItems=\(result.restored) back=\(back) failures=\(result.failures.count)")
        for failure in result.failures { print("FAIL\t\(failure)") }
        // Anything not put back is still in the Trash; list it so the test files can be cleaned up.
        for entry in outcome.restorable where fm.fileExists(atPath: entry.trashed.path) { print("LEFT\t\(entry.trashed.path)") }
        return back == before.count && gone == before.count && result.failures.isEmpty ? 0 : 1
    }

    /// Read-only summary of what the window would list.
    private static func report(verbose: Bool) {
        let running = isClaudeRunning()
        let items = Scanner().scan(claudeRunning: running)
        print("home=\(Env.home.path) claudeRunning=\(running) items=\(items.count)")
        let groups = Dictionary(grouping: items, by: \.status)
        for status in groups.keys.sorted() {
            let list = groups[status] ?? []
            print("\(status)\t\(list.count)\t\(Fmt.size(list.reduce(Int64(0)) { $0 + $1.size }))")
        }

        let accounts = AccountScanner.scan()
        print("accounts current=\(AccountScanner.currentAccountID().map { String($0.prefix(8)) } ?? "-") sessions=\(accounts.sessions.count)")
        for slot in accounts.slots.sorted(by: { $0.lastUsed > $1.lastUsed }) {
            print("slot\t\(slot.accountID.prefix(8))/\(slot.orgID.prefix(8))\tsessions=\(slot.sessionCount)\tcurrent=\(slot.isCurrentAccount)\t\(Fmt.relative(slot.lastUsed))")
        }

        guard verbose else { return }
        let ordered = items.sorted {
            ($0.kind == .chat ? 0 : 1, $0.status, $1.date) < ($1.kind == .chat ? 0 : 1, $1.status, $0.date)
        }
        for item in ordered {
            print([String(describing: item.status), Fmt.size(item.size), Fmt.relative(item.date),
                   "\(item.urls.count) yol", item.title, item.detail].joined(separator: "\t"))
            if item.kind == .large { for url in item.urls { print("\tPATH\t\(url.path)") } }
        }
        for session in accounts.sessions {
            print(["session", "\(session.accountID.prefix(8))/\(session.orgID.prefix(8))",
                   (session.isArchived ? "archived" : "listed") + (session.hasWorktree ? "+worktree" : ""),
                   session.localID, session.title].joined(separator: "\t"))
        }
    }

    /// Trashes every unlocked item. Refuses to run against the real home folder.
    private static func testTrash() -> Int32 {
        guard Env.isTestHome else {
            FileHandle.standardError.write(Data("--test-trash yalnızca SOHBET_HOME ile çalışır.\n".utf8))
            return 2
        }
        let items = Scanner().scan(claudeRunning: false).filter { !$0.isLocked }
        let outcome = Trasher.trash(items)
        print("trashed=\(outcome.trashedIDs.count) freed=\(outcome.freed) skipped=\(outcome.skipped.count) failures=\(outcome.failures.count)")
        for url in outcome.trashedURLs { print("TRASHED\t\(url.path)") }
        for failure in outcome.failures { print("FAIL\t\(failure)") }
        return outcome.failures.isEmpty ? 0 : 1
    }

    /// Moves one session record to another account folder. Refuses to run against the real home folder.
    private static func testMove(localID: String, slotID: String) -> Int32 {
        guard Env.isTestHome else {
            FileHandle.standardError.write(Data("--test-move yalnızca SOHBET_HOME ile çalışır.\n".utf8))
            return 2
        }
        let accounts = AccountScanner.scan()
        guard let session = accounts.sessions.first(where: { $0.localID == localID }),
              let slot = accounts.slots.first(where: { $0.id == slotID }) else {
            print("NOT FOUND")
            return 3
        }
        let outcome = AccountMover.move([session], to: slot)
        print("moved=\(outcome.moved.count) failures=\(outcome.failures.count)")
        for url in outcome.trashedURLs { print("TRASHED\t\(url.path)") }
        for failure in outcome.failures { print("FAIL\t\(failure)") }
        return outcome.failures.isEmpty ? 0 : 1
    }
}
