import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            Group {
                if store.tab == .accounts {
                    AccountsView()
                } else {
                    CleanerView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if store.isWorking {
                    ProgressView(store.workingText)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let banner = store.banner {
                BannerView(banner: banner)
            }
            Divider()
            if store.tab == .accounts {
                MoveBar()
            } else {
                ActionBar()
            }
        }
        .task { await store.rescan() }
        .onAppear {
            store.openMainWindow = { openWindow(id: "main") }
            store.openSettingsWindow = { openSettings() }
        }
        .sheet(item: $store.previewItem) { item in
            ConversationView(item: item)
                .environmentObject(store)
        }
        .confirmationDialog(trashTitle, isPresented: $store.confirmTrash, titleVisibility: .visible) {
            Button("Çöp Kutusuna Taşı", role: .destructive) {
                Task { await store.trashSelected() }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(trashMessage)
        }
        .confirmationDialog(moveTitle, isPresented: $store.confirmMove, titleVisibility: .visible) {
            Button("Taşı") {
                Task { await store.moveSelected() }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Sohbet içerikleri bu Mac'te olduğu gibi kalır; yalnızca hangi hesapta görüneceği değişir. Eski kayıtlar Çöp Kutusu'na gider. İsterseniz aynı ekrandan geri taşıyabilirsiniz.")
        }
    }

    private var trashTitle: String {
        let count = store.selectedVisible.count
        return store.tab == .chats
            ? String(localized: "Seçilen \(count) sohbet Çöp Kutusu'na taşınsın mı?")
            : String(localized: "Seçilen \(count) öğe Çöp Kutusu'na taşınsın mı?")
    }

    private var trashMessage: String {
        let selected = store.selectedVisible
        let size = Fmt.size(selected.reduce(Int64(0)) { $0 + $1.size })
        var text = String(localized: "Toplam \(size). Çöp Kutusu'nu boşaltana kadar Geri Al düğmesiyle veya Finder'dan geri alabilirsiniz.")
        let warnings = Set(selected.compactMap(\.warning)).sorted()
        if !warnings.isEmpty { text += "\n\n" + warnings.joined(separator: "\n\n") }
        return text
    }

    private var moveTitle: String {
        let count = store.movableSelection.count
        let target = store.targetSlot.map { store.slotLabel($0) } ?? ""
        return String(localized: "Seçilen \(count) oturum “\(target)” hesabına taşınsın mı?")
    }
}

// MARK: Header

private struct HeaderView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            Picker("Bölüm", selection: $store.tab) {
                ForEach(Store.Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                Task { await store.rescan() }
            } label: {
                Label("Yeniden Tara", systemImage: "arrow.clockwise")
            }
            .disabled(store.isScanning || store.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: String {
        switch store.tab {
        case .chats: return String(localized: "Arka planda kalan sohbetler")
        case .caches: return String(localized: "Önbellek ve günlükler")
        case .large: return String(localized: "Büyük dosyalar")
        case .accounts: return String(localized: "Hesaplar arası taşıma")
        }
    }

    private var subtitle: String {
        switch store.tab {
        case .chats:
            return String(localized: "Claude uygulamasında artık görünmeyen ama diskte yer kaplayan sohbet kayıtları. İsterseniz önce okuyun veya arşivleyin, sonra Çöp Kutusu'na taşıyın.")
        case .caches:
            return String(localized: "Claude'un biriktirdiği önbellek, günlük ve sahipsiz oturum dosyaları. Silinenler gerektiğinde yeniden oluşturulur.")
        case .large:
            return String(localized: "Claude'un indirip sakladığı büyük paketler ve eski sürümler. Her satırda silince ne olacağı yazar.")
        case .accounts:
            return String(localized: "Claude'daki oturumları bir hesaptan diğerine taşıyın. Sohbet içerikleri bu Mac'te kalır; yalnızca hangi hesapta göründüğü değişir.")
        }
    }
}

// MARK: Cleaner tabs

private struct CleanerView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if store.tab == .chats {
            HStack(spacing: 0) {
                ProjectSidebar()
                    .frame(width: 230)
                Divider()
                listPane
            }
        } else {
            listPane
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            FilterBar()
            if store.tab != .chats && store.claudeRunning {
                Notice(text: "Claude şu an açık; bu dosyalar kullanımda olduğu için kilitli. Claude'dan çıkın (⌘Q), liste kendiliğinden güncellenir.")
            }
            Group {
                if !store.hasScanned {
                    ProgressView("Taranıyor…")
                } else if store.visible.isEmpty {
                    EmptyStateView()
                } else {
                    ItemTable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ProjectSidebar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let total = store.chatBaseSummary
        VStack(spacing: 0) {
            List(selection: Binding<String?>(
                get: { store.projectFilter },
                set: { store.projectFilter = $0 ?? "*" }
            )) {
                Section("Projeler") {
                    ProjectRow(symbol: "tray.2.fill", title: String(localized: "Tüm projeler"), count: total.count, size: total.size)
                        .tag("*")
                    ForEach(store.projectGroups) { group in
                        ProjectRow(symbol: "folder.fill", title: Self.shortName(group.label), count: group.count, size: group.size)
                            .tag(group.id)
                            .help(group.label)
                    }
                }
            }
            .listStyle(.sidebar)
            if store.protectedChatCount > 0 {
                Toggle("Claude'da kayıtlı \(store.protectedChatCount) sohbeti de göster", isOn: $store.showProtected)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private static func shortName(_ label: String) -> String {
        let last = (label as NSString).lastPathComponent
        return last.isEmpty ? label : last
    }
}

private struct ProjectRow: View {
    let symbol: String
    let title: String
    let count: Int
    let size: Int64

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text("\(count) sohbet · \(Fmt.size(size))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}

private struct FilterBar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let total = store.cleanableInTab
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(store.searchContent && store.tab == .chats ? "Başlık, klasör veya mesaj ara" : "Başlık veya klasör ara",
                          text: $store.query)
                    .textFieldStyle(.plain)
                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 280)

            if store.tab == .chats {
                Toggle("İçerikte ara", isOn: $store.searchContent)
                    .toggleStyle(.checkbox)
                    .help("Başlığın yanında mesajların içinde de arar. İlk aramada sohbetler okunur; biraz sürebilir.")
                if store.isSearchingContent {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Spacer()
            if store.isScanning && store.hasScanned {
                ProgressView()
                    .controlSize(.small)
            }
            Text(summary(total))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func summary(_ total: (count: Int, size: Int64)) -> String {
        if total.count == 0 { return String(localized: "Temizlenecek bir şey yok") }
        return store.tab == .chats
            ? String(localized: "\(total.count) sohbet · \(Fmt.size(total.size))")
            : String(localized: "\(total.count) öğe · \(Fmt.size(total.size))")
    }
}

private struct ItemTable: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Table(store.visible, sortOrder: $store.sortOrder) {
            TableColumn("") { item in
                Toggle("Seç", isOn: Binding(
                    get: { store.isSelected(item) },
                    set: { store.setSelected(item, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(item.isLocked)
                .help(item.isLocked ? item.status.help : String(localized: "Silinecekler arasına ekle"))
            }
            .width(22)

            TableColumn("Başlık", value: \.title) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { store.toggle(item) }
                    if item.kind == .chat {
                        Button {
                            store.previewItem = item
                        } label: {
                            Image(systemName: "text.bubble")
                        }
                        .buttonStyle(.borderless)
                        .help("Sohbeti oku")
                    }
                }
                .padding(.vertical, 3)
                .opacity(item.isLocked ? 0.55 : 1)
                .help(item.preview ?? item.title)
                .contextMenu {
                    if item.kind == .chat {
                        Button("Sohbeti Oku") { store.previewItem = item }
                        Button("Markdown Olarak Arşivle…") { store.archive([item]) }
                        Divider()
                    }
                    Button("Finder'da Göster") {
                        NSWorkspace.shared.activateFileViewerSelecting(Array(item.urls.prefix(1)))
                    }
                }
            }
            .width(min: 180, ideal: 260)

            TableColumn("Son değişiklik", value: \.date) { item in
                Text(Fmt.relative(item.date))
                    .foregroundStyle(.secondary)
                    .help(Fmt.absolute(item.date))
            }
            .width(min: 96, ideal: 120, max: 170)

            TableColumn("Boyut", value: \.size) { item in
                Text(Fmt.size(item.size))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 80, max: 110)

            TableColumn("Durum", value: \.status) { item in
                StatusBadge(label: item.status.label, symbol: item.status.symbol, tint: item.status.tint, help: item.status.help)
            }
            .width(min: 140, ideal: 172, max: 210)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if !store.query.isEmpty {
            ContentUnavailableView.search(text: store.query)
        } else {
            switch store.tab {
            case .chats:
                ContentUnavailableView {
                    Label("Arka planda kalan sohbet yok", systemImage: "checkmark.seal")
                } description: {
                    Text(store.protectedChatCount > 0
                         ? String(localized: "Diskteki \(store.protectedChatCount) sohbet hâlâ Claude'da kayıtlı. Onları silmek için önce Claude uygulamasından silin.")
                         : String(localized: "Diskte sohbet kaydı bulunamadı."))
                }
            case .large:
                ContentUnavailableView("Büyük dosya yok", systemImage: "externaldrive",
                                       description: Text("Claude'un indirdiği büyük paket veya eski sürüm bulunamadı."))
            default:
                ContentUnavailableView("Temizlenecek önbellek yok", systemImage: "sparkles",
                                       description: Text("Claude'a ait önbellek veya günlük dosyası bulunamadı."))
            }
        }
    }
}

private struct ActionBar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let selected = store.selectedVisible
        let size = selected.reduce(Int64(0)) { $0 + $1.size }
        HStack(spacing: 10) {
            Button("Tümünü Seç") { store.selectAllVisible() }
            Button("Seçimi Kaldır") { store.deselectAllVisible() }
                .disabled(selected.isEmpty)
            if store.tab != .large {
                Menu("Eskileri Seç") {
                    Button("1 haftadan eski olanlar") { store.selectOlder(thanDays: 7) }
                    Button("1 aydan eski olanlar") { store.selectOlder(thanDays: 30) }
                    Button("3 aydan eski olanlar") { store.selectOlder(thanDays: 90) }
                }
                .fixedSize()
            }
            Spacer()
            Text(selected.isEmpty
                 ? String(localized: "Silmek istediklerinizi işaretleyin")
                 : String(localized: "\(selected.count) seçili · \(Fmt.size(size))"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if store.tab == .chats {
                Button {
                    store.archive(selected)
                } label: {
                    Label("Arşivle…", systemImage: "square.and.arrow.down")
                }
                .disabled(selected.isEmpty || store.isWorking)
                .help("Seçilen sohbetleri okunabilir Markdown dosyaları olarak kaydeder; hiçbir şey silinmez.")
            }
            Button(role: .destructive) {
                store.confirmTrash = true
            } label: {
                Label("Çöp Kutusuna Taşı", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selected.isEmpty || store.isWorking || store.isScanning)
        }
        .disabled(!store.hasScanned)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: Accounts tab

private struct AccountsView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        HStack(spacing: 0) {
            AccountSidebar()
                .frame(width: 270)
            Divider()
            VStack(spacing: 0) {
                if store.claudeRunning {
                    Notice(text: "Claude şu an açık. Taşımak için önce Claude'dan çıkın (⌘Q): açıkken kayıtları kendisi yeniden yazar. Liste kendiliğinden güncellenir.")
                }
                Group {
                    if !store.hasScanned {
                        ProgressView("Taranıyor…")
                    } else if store.visibleSessions.isEmpty {
                        ContentUnavailableView("Bu hesapta oturum yok", systemImage: "tray",
                                               description: Text("Claude'da bu hesaba kayıtlı oturum bulunamadı."))
                    } else {
                        SessionTable()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AccountSidebar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding<String?>(
                get: { store.sourceAccount },
                set: { store.sourceAccount = $0 ?? "*" }
            )) {
                Section("Kaynak hesap") {
                    Label("Tüm hesaplar · \(store.desktopSessions.count) oturum", systemImage: "person.2.fill")
                        .tag("*")
                    ForEach(store.accountIDs, id: \.self) { accountID in
                        AccountRow(accountID: accountID)
                            .tag(accountID)
                    }
                }
            }
            .listStyle(.sidebar)
            Text("Claude diskte hesapları yalnızca kimlik numarasıyla tutar; adlarını kalem simgesinin yanına yazarak siz verin. Hangisinin hangi hesap olduğunu görmek için Claude'da hesap değiştirip Yeniden Tara'ya basın: o anki hesap \"Claude'da açık\" diye işaretlenir.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

private struct AccountRow: View {
    @EnvironmentObject private var store: Store
    let accountID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.tint)
                TextField(store.defaultAccountLabel(accountID), text: Binding(
                    get: { store.accountNames[accountID] ?? "" },
                    set: { store.accountNames[accountID] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.body.weight(.medium))
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if store.isCurrentAccount(accountID) {
                    Text("Claude'da açık")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.16), in: Capsule())
                }
            }
            Text("\(store.sessionCount(account: accountID)) oturum · son kullanım \(Fmt.relative(store.lastUsed(account: accountID)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .help("Hesap kimliği: \(accountID). Ad vermek için yazın.")
    }
}

private struct SessionTable: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        Table(store.visibleSessions, sortOrder: $store.sessionSort) {
            TableColumn("") { session in
                Toggle("Seç", isOn: Binding(
                    get: { store.moveSelection.contains(session.id) },
                    set: { store.setMoveSelected(session, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(session.hasWorktree)
                .help(session.hasWorktree ? Self.worktreeHelp : String(localized: "Taşınacaklar arasına ekle"))
            }
            .width(22)

            TableColumn("Oturum", value: \.title) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(session.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !session.hasWorktree { store.toggleMove(session) }
                }
                .opacity(session.hasWorktree ? 0.55 : 1)
            }
            .width(min: 200, ideal: 330)

            TableColumn("Hesap", value: \.accountID) { session in
                Text(store.accountLabel(session.accountID))
                    .lineLimit(1)
                    .help("Hesap \(session.accountID) · kuruluş \(session.orgID)")
            }
            .width(min: 100, ideal: 130, max: 200)

            TableColumn("Son kullanım", value: \.lastActivity) { session in
                Text(Fmt.relative(session.lastActivity))
                    .foregroundStyle(.secondary)
                    .help(Fmt.absolute(session.lastActivity))
            }
            .width(min: 90, ideal: 110, max: 150)

            TableColumn("Durum") { session in
                if session.hasWorktree {
                    StatusBadge(label: String(localized: "Taşınamaz"), symbol: "lock.fill", tint: .gray, help: Self.worktreeHelp)
                } else if session.isArchived {
                    StatusBadge(label: String(localized: "Arşivde"), symbol: "archivebox.fill", tint: .gray,
                                help: String(localized: "Claude'da arşivde. Taşınınca hedef hesapta da arşivde olur."))
                } else {
                    StatusBadge(label: String(localized: "Listede"), symbol: "list.bullet", tint: .blue,
                                help: String(localized: "Claude'un kenar çubuğunda görünüyor."))
                }
            }
            .width(min: 90, ideal: 104, max: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    static let worktreeHelp = String(localized: "Çalışma ağacında (worktree) açılmış oturumlar taşınmaz: Claude sahipsiz sandığı çalışma ağacı klasörünü temizleyebilir.")
}

private struct MoveBar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let chosen = store.movableSelection
        let selectedCount = store.selectedSessions.count
        HStack(spacing: 10) {
            Button("Tümünü Seç") { store.selectAllSessions() }
            Button("Seçimi Kaldır") { store.deselectAllSessions() }
                .disabled(selectedCount == 0)
            Spacer()
            Text(selectedCount == 0
                 ? String(localized: "Taşınacak oturumları işaretleyin")
                 : String(localized: "\(selectedCount) seçili"))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("Hedef:")
                .foregroundStyle(.secondary)
            Picker("Hedef hesap", selection: $store.targetSlotID) {
                Text("Hesap seçin…").tag(String?.none)
                ForEach(store.primarySlots) { slot in
                    Text(store.slotLabel(slot)).tag(Optional(slot.id))
                }
                if !store.otherSlots.isEmpty {
                    Section("Aynı hesapların diğer kuruluşları") {
                        ForEach(store.otherSlots) { slot in
                            Text(store.slotLabel(slot)).tag(Optional(slot.id))
                        }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                store.confirmMove = true
            } label: {
                if chosen.isEmpty {
                    Label("Taşı", systemImage: "arrow.left.arrow.right")
                } else {
                    Label("\(chosen.count) Oturumu Taşı", systemImage: "arrow.left.arrow.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty || store.targetSlot == nil || store.claudeRunning || store.isWorking || store.isScanning)
        }
        .disabled(!store.hasScanned)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: Shared pieces

private struct StatusBadge: View {
    let label: String
    let symbol: String
    let tint: Color
    let help: String

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .help(help)
    }
}

private extension ItemStatus {
    var tint: Color {
        switch self {
        case .leftover: return .orange
        case .cleanable: return .teal
        case .inUse: return .green
        case .archived, .needsQuit: return .gray
        case .active: return .blue
        }
    }
}

private struct Notice: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

private struct BannerView: View {
    @EnvironmentObject private var store: Store
    let banner: Store.Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Color.orange : Color.green)
            Text(banner.text)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer()
            ForEach(banner.actions, id: \.self) { action in
                switch action {
                case .undo:
                    Button("Geri Al") { Task { await store.undoLastTrash() } }
                        .disabled(store.lastTrash.isEmpty || store.isWorking)
                case .openTrash:
                    Button("Çöp Kutusunu Aç") {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                    }
                case .reveal(let url):
                    Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            Button {
                store.banner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Kapat")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
