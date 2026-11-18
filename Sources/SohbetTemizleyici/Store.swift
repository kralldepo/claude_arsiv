import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    enum Tab: String, CaseIterable, Identifiable {
        case chats, caches, large, accounts
        var id: Self { self }
        var title: String {
            switch self {
            case .chats: return String(localized: "Sohbetler")
            case .caches: return String(localized: "Önbellek")
            case .large: return String(localized: "Büyük Dosyalar")
            case .accounts: return String(localized: "Hesaplar")
            }
        }
        var kind: ItemKind? {
            switch self {
            case .chats: return .chat
            case .caches: return .cache
            case .large: return .large
            case .accounts: return nil
            }
        }
    }

    enum BannerAction: Hashable {
        case undo, openTrash, reveal(URL)
    }

    struct Banner: Equatable {
        let text: String
        let isError: Bool
        var actions: [BannerAction] = []
    }

    struct ProjectGroup: Identifiable {
        let id: String
        let label: String
        let count: Int
        let size: Int64
    }

    private enum Keys {
        static let names = "accountNames"
        static let menuBar = "showInMenuBar"
        static let notify = "notifyEnabled"
        static let threshold = "notifyThresholdMB"
        static let lastNotified = "lastNotified"
        static let archiveFolder = "archiveFolder"
    }

    // MARK: Cleaner tabs

    @Published var tab: Tab = .chats
    @Published var query = "" { didSet { scheduleContentSearch() } }
    /// Also look inside the messages, not only titles and folders.
    @Published var searchContent = false { didSet { scheduleContentSearch() } }
    @Published private(set) var contentMatches = Set<String>()
    @Published private(set) var isSearchingContent = false
    @Published var showProtected = false
    /// Project folder shown in the chat list; "*" means every project.
    @Published var projectFilter = "*"
    @Published var sortOrder = [KeyPathComparator(\CleanItem.date, order: .reverse)]
    /// Ticked rows. Starts empty: the user picks what to delete.
    @Published var selection = Set<String>()
    @Published var banner: Banner?
    /// Dialog flags live here instead of a view's @State: the Command Line Tools ship without SwiftUI's macro plugin.
    @Published var confirmTrash = false
    @Published var confirmMove = false
    /// Conversation shown in the reading sheet.
    @Published var previewItem: CleanItem?
    @Published private(set) var items: [CleanItem] = []
    /// What the last trash run moved, so it can be put back.
    @Published private(set) var lastTrash: [Trasher.Restore] = []

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
        didSet { UserDefaults.standard.set(accountNames, forKey: Keys.names) }
    }

    // MARK: Settings

    @Published var showInMenuBar = UserDefaults.standard.bool(forKey: Keys.menuBar) {
        didSet {
            guard showInMenuBar != oldValue else { return }
            UserDefaults.standard.set(showInMenuBar, forKey: Keys.menuBar)
            updateMonitoring()
        }
    }
    @Published var notifyEnabled = UserDefaults.standard.bool(forKey: Keys.notify) {
        didSet {
            guard notifyEnabled != oldValue else { return }
            UserDefaults.standard.set(notifyEnabled, forKey: Keys.notify)
            if notifyEnabled { requestNotificationPermission() }
        }
    }
    @Published var notifyThresholdMB = Store.loadThreshold() {
        didSet { UserDefaults.standard.set(notifyThresholdMB, forKey: Keys.threshold) }
    }
    @Published private(set) var notificationsDenied = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    // MARK: Status

    @Published private(set) var isScanning = false
    @Published private(set) var isWorking = false
    @Published private(set) var workingText = ""
    @Published private(set) var hasScanned = false
    @Published private(set) var claudeRunning = false

    /// Opens the main window; set by a view, which is the only place SwiftUI hands this action out.
    var openMainWindow: (() -> Void)?
    /// Opens the Settings window, set the same way; SwiftUI ignores the old showSettingsWindow: action.
    var openSettingsWindow: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var searchTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private let contentIndex = ContentIndex()

    private static func loadNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Keys.names) as? [String: String] ?? [:]
    }

    private static func loadThreshold() -> Int {
        let value = UserDefaults.standard.integer(forKey: Keys.threshold)
        return value > 0 ? value : 500
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
        updateMonitoring()
    }

    // MARK: Cleaner: what the window shows

    var visible: [CleanItem] {
        guard let kind = tab.kind else { return [] }
        let list = kind == .chat
            ? chatBase.filter { projectFilter == "*" || $0.project == projectFilter }
            : items.filter { $0.kind == kind && matchesQuery($0) }
        return list.sorted(using: sortOrder)
    }

    /// Chats the list shows before the project filter applies.
    private var chatBase: [CleanItem] {
        items.filter { $0.kind == .chat && (showProtected || !$0.isLocked) && matchesQuery($0) }
    }

    private func matchesQuery(_ item: CleanItem) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return true }
        if item.title.localizedCaseInsensitiveContains(text) || item.detail.localizedCaseInsensitiveContains(text) { return true }
        return item.kind == .chat && searchContent && contentMatches.contains(item.id)
    }

    /// Project folders with their chat count and size, largest first.
    var projectGroups: [ProjectGroup] {
        Dictionary(grouping: chatBase) { $0.project ?? "" }
            .map { key, list in
                let label = list.map(\.detail).min { $0.count < $1.count } ?? key
                return ProjectGroup(id: key, label: label, count: list.count, size: list.reduce(Int64(0)) { $0 + $1.size })
            }
            .sorted { $0.size > $1.size }
    }

    var chatBaseSummary: (count: Int, size: Int64) {
        let list = chatBase
        return (list.count, list.reduce(Int64(0)) { $0 + $1.size })
    }

    var selectedVisible: [CleanItem] {
        visible.filter { selection.contains($0.id) && !$0.isLocked }
    }

    var cleanableInTab: (count: Int, size: Int64) {
        guard let kind = tab.kind else { return (0, 0) }
        let list = items.filter { $0.kind == kind && !$0.isLocked }
        return (list.count, list.reduce(Int64(0)) { $0 + $1.size })
    }

    /// Conversations Claude no longer lists: what the menu bar and the reminder count.
    var leftoverTotal: (count: Int, size: Int64) {
        let list = items.filter { $0.kind == .chat && $0.status == .leftover }
        return (list.count, list.reduce(Int64(0)) { $0 + $1.size })
    }

    func total(of kind: ItemKind) -> Int64 {
        items.filter { $0.kind == kind && !$0.isLocked }.reduce(Int64(0)) { $0 + $1.size }
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

    // MARK: Content search

    private func scheduleContentSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard searchContent, !text.isEmpty else {
            contentMatches = []
            isSearchingContent = false
            return
        }
        let chats = items.filter { $0.kind == .chat }
        isSearchingContent = true
        searchTask = Task { [weak self, contentIndex] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let found = await contentIndex.matches(text, in: chats)
            guard !Task.isCancelled, let self else { return }
            self.contentMatches = found
            self.isSearchingContent = false
        }
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
        String(localized: "Hesap \(String(accountID.prefix(8)))")
    }

    func accountLabel(_ accountID: String) -> String {
        let name = (accountNames[accountID] ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? defaultAccountLabel(accountID) : name
    }

    func slotLabel(_ slot: AccountSlot) -> String {
        var parts = [accountLabel(slot.accountID)]
        if primarySlots.contains(where: { $0.id == slot.id }) {
            if slot.isCurrentAccount { parts.append(String(localized: "Claude'da açık")) }
        } else {
            parts.append(String(localized: "kuruluş \(String(slot.orgID.prefix(8)))"))
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
        if projectFilter != "*", !result.items.contains(where: { $0.project == projectFilter }) { projectFilter = "*" }
        isScanning = false
        hasScanned = true
        if searchContent { scheduleContentSearch() }
        remindIfNeeded()
    }

    func trashSelected() async {
        let targets = selectedVisible
        guard !targets.isEmpty, !isWorking, !isScanning else { return }
        if targets.contains(where: \.needsClaudeClosed), isClaudeRunning() {
            banner = Banner(text: String(localized: "Claude açık olduğu için hiçbir şey silinmedi. Önce Claude'dan çıkın (⌘Q)."), isError: true)
            await rescan()
            return
        }
        isWorking = true
        workingText = String(localized: "Çöp Kutusu'na taşınıyor…")
        let outcome = await Task.detached(priority: .userInitiated) {
            Trasher.trash(targets)
        }.value
        isWorking = false
        selection.subtract(outcome.trashedIDs)
        lastTrash = outcome.restorable
        banner = Self.describe(outcome)
        await rescan()
    }

    func undoLastTrash() async {
        let list = lastTrash
        guard !list.isEmpty, !isWorking else { return }
        isWorking = true
        workingText = String(localized: "Geri getiriliyor…")
        let result = await Task.detached(priority: .userInitiated) {
            Trasher.restore(list)
        }.value
        isWorking = false
        lastTrash = []
        var parts = [String(localized: "\(result.restored) öğe eski yerine geri getirildi.")]
        if let first = result.failures.first {
            parts.append(String(localized: "\(result.failures.count) dosya geri getirilemedi: \(first)"))
        }
        banner = Banner(text: parts.joined(separator: " "), isError: !result.failures.isEmpty)
        await rescan()
    }

    /// Asks for a folder, then writes each conversation there as Markdown. Nothing is deleted.
    func archive(_ targets: [CleanItem]) {
        let chats = targets.filter { $0.transcript != nil }
        guard !chats.isEmpty, !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Arşivle")
        panel.message = String(localized: "Seçilen \(chats.count) sohbet bu klasöre Markdown dosyası olarak kaydedilecek.")
        let saved = UserDefaults.standard.string(forKey: Keys.archiveFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.directoryURL = saved ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        UserDefaults.standard.set(folder.path, forKey: Keys.archiveFolder)
        Task { await runArchive(chats, to: folder) }
    }

    private func runArchive(_ chats: [CleanItem], to folder: URL) async {
        isWorking = true
        workingText = String(localized: "Arşivleniyor…")
        let outcome = await Task.detached(priority: .userInitiated) {
            Archiver.archive(chats, to: folder)
        }.value
        isWorking = false
        var parts = [String(localized: "\(outcome.written.count) sohbet Markdown olarak kaydedildi: \(prettyPath(folder.path)). Silmek isterseniz şimdi Çöp Kutusu'na taşıyabilirsiniz.")]
        if let first = outcome.failures.first {
            parts.append(String(localized: "\(outcome.failures.count) sohbet yazılamadı: \(first)"))
        }
        banner = Banner(text: parts.joined(separator: " "), isError: !outcome.failures.isEmpty,
                        actions: outcome.written.first.map { [.reveal($0)] } ?? [])
    }

    func moveSelected() async {
        guard let target = targetSlot else { return }
        let chosen = movableSelection
        guard !chosen.isEmpty, !isWorking, !isScanning else { return }
        guard !isClaudeRunning() else {
            claudeRunning = true
            banner = Banner(text: String(localized: "Claude açık olduğu için hiçbir şey taşınmadı. Önce Claude'dan çıkın (⌘Q)."), isError: true)
            return
        }
        isWorking = true
        workingText = String(localized: "Oturumlar taşınıyor…")
        let outcome = await Task.detached(priority: .userInitiated) {
            AccountMover.move(chosen, to: target)
        }.value
        isWorking = false
        moveSelection.subtract(chosen.map(\.id))
        var parts: [String] = []
        if !outcome.moved.isEmpty {
            parts.append(String(localized: "\(outcome.moved.count) oturum “\(slotLabel(target))” hesabına taşındı. Claude'u açıp o hesaba geçince görünür; eski kayıtlar Çöp Kutusu'nda."))
        }
        if let first = outcome.failures.first {
            parts.append(String(localized: "\(outcome.failures.count) oturum taşınamadı: \(first)"))
        }
        banner = Banner(text: parts.isEmpty ? String(localized: "Taşınacak bir şey bulunamadı.") : parts.joined(separator: " "),
                        isError: !outcome.failures.isEmpty)
        await rescan()
    }

    private static func describe(_ outcome: Trasher.Outcome) -> Banner {
        var parts: [String] = []
        if !outcome.trashedIDs.isEmpty {
            parts.append(String(localized: "\(outcome.trashedIDs.count) öğe Çöp Kutusu'na taşındı (\(Fmt.size(outcome.freed)))."))
        }
        if !outcome.skipped.isEmpty {
            parts.append(String(localized: "\(outcome.skipped.count) öğe şu an kullanımda olduğu için atlandı."))
        }
        if let first = outcome.failures.first {
            parts.append(String(localized: "\(outcome.failures.count) dosya taşınamadı: \(first)"))
        }
        let actions: [BannerAction] = outcome.restorable.isEmpty ? [.openTrash] : [.undo, .openTrash]
        return Banner(text: parts.isEmpty ? String(localized: "Taşınacak bir şey bulunamadı.") : parts.joined(separator: " "),
                      isError: !outcome.failures.isEmpty, actions: actions)
    }

    // MARK: Menu bar, reminder, login item

    /// While the app lives in the menu bar it rescans every 30 minutes. It never deletes on its own.
    private func updateMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        guard showInMenuBar else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.rescan()
            }
        }
    }

    /// One notification a day at most, and only while the leftovers stay above the limit.
    private func remindIfNeeded() {
        guard showInMenuBar, notifyEnabled else { return }
        let total = leftoverTotal
        guard total.size >= Int64(notifyThresholdMB) * 1_000_000 else {
            UserDefaults.standard.removeObject(forKey: Keys.lastNotified)
            return
        }
        let last = UserDefaults.standard.object(forKey: Keys.lastNotified) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        UserDefaults.standard.set(Date(), forKey: Keys.lastNotified)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Arka planda sohbet birikti")
        content.body = String(localized: "\(total.count) sohbet \(Fmt.size(total.size)) yer kaplıyor. Göz atmak için tıklayın.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "leftover", content: content, trigger: nil))
    }

    private func requestNotificationPermission() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            notificationsDenied = !granted
            if granted { remindIfNeeded() }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = Banner(text: String(localized: "Oturum açılışında başlatma ayarlanamadı: \(error.localizedDescription)"), isError: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        launchNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate()
    }
}
