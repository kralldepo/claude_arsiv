import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    enum Tab: String, CaseIterable, Identifiable {
        case chats, caches, accounts
        var id: Self { self }
        var title: String {
            switch self {
            case .chats: return "Sohbetler"
            case .caches: return "Önbellek ve Günlükler"
            case .accounts: return "Hesaplar Arası"
            }
        }
    }

    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    // MARK: Cleaner tabs

    @Published var tab: Tab = .chats
    @Published var query = ""
    @Published var showProtected = false
    @Published var sortOrder = [KeyPathComparator(\CleanItem.date, order: .reverse)]
    /// Ticked rows. Starts empty: the user picks what to delete.
    @Published var selection = Set<String>()
    @Published var banner: Banner?
    /// Dialog flags live here instead of a view's @State: the Command Line Tools ship without SwiftUI's macro plugin.
    @Published var confirmTrash = false
    @Published var confirmMove = false
    @Published private(set) var items: [CleanItem] = []

    // MARK: Accounts tab

    @Published private(set) var slots: [AccountSlot] = []
    @Published private(set) var desktopSessions: [DesktopSession] = []
    @Published var moveSelection = Set<String>()
    /// Account shown in the session list; "*" means every account.
    @Published var sourceAccount = "*"
    @Published var targetSlotID: String?
    @Published var sessionSort = [KeyPathComparator(\DesktopSession.lastActivity, order: .reverse)]
    /// Names the user gives accounts; Claude keeps only ids on disk.
    @Published var accountNames: [String: String] = Store.loadNames() {
        didSet { UserDefaults.standard.set(accountNames, forKey: Store.namesKey) }
    }

    @Published private(set) var isScanning = false
    @Published private(set) var isWorking = false
    @Published private(set) var workingText = ""
    @Published private(set) var hasScanned = false
    @Published private(set) var claudeRunning = false

    private var observers: [NSObjectProtocol] = []
    private static let namesKey = "accountNames"

    private static func loadNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    init() {
        // Quitting or opening Claude changes what is locked, so rescan when that happens.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Env.claudeBundleID else { return }
                Task { @MainActor in await self?.rescan() }
            })
        }
    }

    // MARK: Cleaner: what the window shows

    var visible: [CleanItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            switch tab {
            case .chats:
                guard item.kind == .chat, showProtected || !item.isLocked else { return false }
            case .caches:
                guard item.kind == .cache else { return false }
            case .accounts:
                return false
            }
            return text.isEmpty
                || item.title.localizedCaseInsensitiveContains(text)
                || item.detail.localizedCaseInsensitiveContains(text)
        }
        .sorted(using: sortOrder)
    }

    var selectedVisible: [CleanItem] {
        visible.filter { selection.contains($0.id) && !$0.isLocked }
    }

    var cleanableInTab: (count: Int, size: Int64) {
        let kind: ItemKind = tab == .chats ? .chat : .cache
        let list = items.filter { $0.kind == kind && !$0.isLocked }
        return (list.count, list.reduce(Int64(0)) { $0 + $1.size })
    }

    var protectedChatCount: Int {
        items.filter { $0.kind == .chat && $0.isLocked }.count
    }

    // MARK: Cleaner: selection

    func isSelected(_ item: CleanItem) -> Bool { selection.contains(item.id) }

    func setSelected(_ item: CleanItem, _ on: Bool) {
        guard !item.isLocked else { return }
        if on { selection.insert(item.id) } else { selection.remove(item.id) }
    }

    func toggle(_ item: CleanItem) {
        setSelected(item, !isSelected(item))
    }

    func selectAllVisible() {
        selection.formUnion(visible.filter { !$0.isLocked }.map(\.id))
    }

    func deselectAllVisible() {
        selection.subtract(visible.map(\.id))
    }

    func selectOlder(thanDays days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let list = visible
        selection.subtract(list.map(\.id))
        selection.formUnion(list.filter { !$0.isLocked && $0.date < cutoff }.map(\.id))
    }

    // MARK: Accounts: what the window shows

    /// Current account first, then the most recently used.
    var accountIDs: [String] {
        Set(slots.map(\.accountID)).sorted { a, b in
            let currentA = isCurrentAccount(a), currentB = isCurrentAccount(b)
            if currentA != currentB { return currentA }
            return lastUsed(account: a) > lastUsed(account: b)
        }
    }

    var targetSlots: [AccountSlot] {
        slots.sorted { a, b in
            if a.isCurrentAccount != b.isCurrentAccount { return a.isCurrentAccount }
            return a.lastUsed > b.lastUsed
        }
    }

    var targetSlot: AccountSlot? { slots.first { $0.id == targetSlotID } }

    /// Each account's most recently used organization folder: where Claude most likely shows its sessions.
    var primarySlots: [AccountSlot] {
        accountIDs.compactMap { accountID in
            slots.filter { $0.accountID == accountID }
                .max { ($0.lastUsed, $0.sessionCount) < ($1.lastUsed, $1.sessionCount) }
        }
    }

    var otherSlots: [AccountSlot] {
        let primary = Set(primarySlots.map(\.id))
        return targetSlots.filter { !primary.contains($0.id) }
    }

    var visibleSessions: [DesktopSession] {
        desktopSessions
            .filter { sourceAccount == "*" || $0.accountID == sourceAccount }
            .sorted(using: sessionSort)
    }

    var selectedSessions: [DesktopSession] {
        visibleSessions.filter { moveSelection.contains($0.id) }
    }

    /// Selected sessions that would actually change account.
    var movableSelection: [DesktopSession] {
        selectedSessions.filter { $0.slotID != targetSlotID && !$0.hasWorktree }
    }

    func isCurrentAccount(_ accountID: String) -> Bool {
        slots.contains { $0.accountID == accountID && $0.isCurrentAccount }
    }

    func sessionCount(account accountID: String) -> Int {
        desktopSessions.filter { $0.accountID == accountID }.count
    }

    func lastUsed(account accountID: String) -> Date {
        slots.filter { $0.accountID == accountID }.map(\.lastUsed).max() ?? .distantPast
    }

    func defaultAccountLabel(_ accountID: String) -> String {
        "Hesap " + String(accountID.prefix(8))
    }

    func accountLabel(_ accountID: String) -> String {
        let name = (accountNames[accountID] ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? defaultAccountLabel(accountID) : name
    }

    func slotLabel(_ slot: AccountSlot) -> String {
        var parts = [accountLabel(slot.accountID)]
        if primarySlots.contains(where: { $0.id == slot.id }) {
            if slot.isCurrentAccount { parts.append("Claude'da açık") }
        } else {
            parts.append("kuruluş " + String(slot.orgID.prefix(8)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Accounts: selection

    func setMoveSelected(_ session: DesktopSession, _ on: Bool) {
        if on { moveSelection.insert(session.id) } else { moveSelection.remove(session.id) }
    }

    func toggleMove(_ session: DesktopSession) {
        setMoveSelected(session, !moveSelection.contains(session.id))
    }

    func selectAllSessions() {
        moveSelection.formUnion(visibleSessions.filter { !$0.hasWorktree }.map(\.id))
    }

    func deselectAllSessions() {
        moveSelection.subtract(visibleSessions.map(\.id))
    }

    // MARK: Actions

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        let running = isClaudeRunning()
        let result = await Task.detached(priority: .userInitiated) {
            (items: Scanner().scan(claudeRunning: running), accounts: AccountScanner.scan())
        }.value
        items = result.items
        slots = result.accounts.slots
        desktopSessions = result.accounts.sessions
        claudeRunning = running
        // Keep ticks only on rows that still exist and are still allowed.
        selection.formIntersection(result.items.filter { !$0.isLocked }.map(\.id))
        moveSelection.formIntersection(result.accounts.sessions.map(\.id))
        if let target = targetSlotID, !slots.contains(where: { $0.id == target }) { targetSlotID = nil }
        if sourceAccount != "*", !slots.contains(where: { $0.accountID == sourceAccount }) { sourceAccount = "*" }
        isScanning = false
        hasScanned = true
    }

    func trashSelected() async {
        let targets = selectedVisible
        guard !targets.isEmpty, !isWorking, !isScanning else { return }
        isWorking = true
        workingText = "Çöp Kutusu'na taşınıyor…"
        let outcome = await Task.detached(priority: .userInitiated) {
            Trasher.trash(targets)
        }.value
        isWorking = false
        selection.subtract(outcome.trashedIDs)
        banner = Self.describe(outcome)
        await rescan()
    }

    func moveSelected() async {
        guard let target = targetSlot else { return }
        let chosen = movableSelection
        guard !chosen.isEmpty, !isWorking, !isScanning else { return }
        guard !isClaudeRunning() else {
            claudeRunning = true
            banner = Banner(text: "Claude açık olduğu için hiçbir şey taşınmadı. Önce Claude'dan çıkın (⌘Q).", isError: true)
            return
        }
        isWorking = true
        workingText = "Oturumlar taşınıyor…"
        let outcome = await Task.detached(priority: .userInitiated) {
            AccountMover.move(chosen, to: target)
        }.value
        isWorking = false
        moveSelection.subtract(chosen.map(\.id))
        var parts: [String] = []
        if !outcome.moved.isEmpty {
            parts.append("\(outcome.moved.count) oturum “\(slotLabel(target))” hesabına taşındı. Claude'u açıp o hesaba geçince görünür; eski kayıtlar Çöp Kutusu'nda.")
        }
        if let first = outcome.failures.first {
            parts.append("\(outcome.failures.count) oturum taşınamadı: \(first)")
        }
        banner = Banner(text: parts.isEmpty ? "Taşınacak bir şey bulunamadı." : parts.joined(separator: " "),
                        isError: !outcome.failures.isEmpty)
        await rescan()
    }

    private static func describe(_ outcome: Trasher.Outcome) -> Banner {
        var parts: [String] = []
        if !outcome.trashedIDs.isEmpty {
            parts.append("\(outcome.trashedIDs.count) öğe Çöp Kutusu'na taşındı (\(Fmt.size(outcome.freed))).")
        }
        if !outcome.skipped.isEmpty {
            parts.append("\(outcome.skipped.count) sohbet şu an kullanımda olduğu için atlandı.")
        }
        if let first = outcome.failures.first {
            parts.append("\(outcome.failures.count) dosya taşınamadı: \(first)")
        }
        return Banner(text: parts.isEmpty ? "Taşınacak bir şey bulunamadı." : parts.joined(separator: " "),
                      isError: !outcome.failures.isEmpty)
    }
}
