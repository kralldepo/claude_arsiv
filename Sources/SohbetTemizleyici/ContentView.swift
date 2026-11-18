import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: Store

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
        .confirmationDialog(trashTitle, isPresented: $store.confirmTrash, titleVisibility: .visible) {
            Button("Çöp Kutusuna Taşı", role: .destructive) {
                Task { await store.trashSelected() }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Toplam \(Fmt.size(store.selectedVisible.reduce(Int64(0)) { $0 + $1.size })). Çöp Kutusu'nu boşaltana kadar Finder'dan geri alabilirsiniz.")
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
            ? "Seçilen \(count) sohbet Çöp Kutusu'na taşınsın mı?"
            : "Seçilen \(count) öğe Çöp Kutusu'na taşınsın mı?"
    }

    private var moveTitle: String {
        let count = store.movableSelection.count
        let target = store.targetSlot.map { store.slotLabel($0) } ?? ""
        return "Seçilen \(count) oturum “\(target)” hesabına taşınsın mı?"
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
        case .chats: return "Arka planda kalan sohbetler"
        case .caches: return "Önbellek ve günlükler"
        case .accounts: return "Hesaplar arası taşıma"
        }
    }

    private var subtitle: String {
        switch store.tab {
        case .chats:
            return "Claude uygulamasında artık görünmeyen ama diskte yer kaplayan sohbet kayıtları. Silmek istediklerinizi işaretleyin; Çöp Kutusu'na taşınırlar."
        case .caches:
            return "Claude'un biriktirdiği önbellek, günlük ve sahipsiz oturum dosyaları. Silinenler gerektiğinde yeniden oluşturulur."
        case .accounts:
            return "Claude'daki oturumları bir hesaptan diğerine taşıyın. Sohbet içerikleri bu Mac'te kalır; yalnızca hangi hesapta göründüğü değişir."
        }
    }
}

// MARK: Cleaner tabs

private struct CleanerView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            if store.tab == .caches && store.claudeRunning {
                Notice(text: "Claude şu an açık; önbellek ve günlükler kullanımda olduğu için kilitli. Claude'dan çıkın (⌘Q), liste kendiliğinden güncellenir.")
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

private struct FilterBar: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let total = store.cleanableInTab
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Başlık veya klasör ara", text: $store.query)
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
            .frame(maxWidth: 300)

            if store.tab == .chats && store.protectedChatCount > 0 {
                Toggle("Claude'da kayıtlı \(store.protectedChatCount) sohbeti de göster", isOn: $store.showProtected)
                    .toggleStyle(.checkbox)
            }
            Spacer()
            if store.isScanning && store.hasScanned {
                ProgressView()
                    .controlSize(.small)
            }
            Text(total.count == 0
                 ? "Temizlenecek bir şey yok"
                 : "\(total.count) \(store.tab == .chats ? "sohbet" : "öğe") · \(Fmt.size(total.size))")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
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
                .help(item.isLocked ? item.status.help : "Silinecekler arasına ekle")
            }
            .width(22)

            TableColumn("Başlık", value: \.title) { item in
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
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { store.toggle(item) }
                .opacity(item.isLocked ? 0.55 : 1)
                .help(item.preview ?? item.title)
                .contextMenu {
                    Button("Finder'da Göster") {
                        NSWorkspace.shared.activateFileViewerSelecting(Array(item.urls.prefix(1)))
                    }
                }
            }
            .width(min: 260, ideal: 480)

            TableColumn("Son değişiklik", value: \.date) { item in
                Text(Fmt.relative(item.date))
                    .foregroundStyle(.secondary)
                    .help(Fmt.absolute(item.date))
            }
            .width(min: 110, ideal: 130, max: 170)

            TableColumn("Boyut", value: \.size) { item in
                Text(Fmt.size(item.size))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84, max: 110)

            TableColumn("Durum", value: \.status) { item in
                StatusBadge(label: item.status.label, symbol: item.status.symbol, tint: item.status.tint, help: item.status.help)
            }
            .width(min: 150, ideal: 172, max: 210)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        if !store.query.isEmpty {
            ContentUnavailableView.search(text: store.query)
        } else if store.tab == .chats {
            ContentUnavailableView {
                Label("Arka planda kalan sohbet yok", systemImage: "checkmark.seal")
            } description: {
                Text(store.protectedChatCount > 0
                     ? "Diskteki \(store.protectedChatCount) sohbet hâlâ Claude'da kayıtlı. Onları silmek için önce Claude uygulamasından silin."
                     : "Diskte sohbet kaydı bulunamadı.")
            }
        } else {
            ContentUnavailableView("Temizlenecek önbellek yok", systemImage: "sparkles",
                                   description: Text("Claude'a ait önbellek veya günlük dosyası bulunamadı."))
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
            Menu("Eskileri Seç") {
                Button("1 haftadan eski olanlar") { store.selectOlder(thanDays: 7) }
                Button("1 aydan eski olanlar") { store.selectOlder(thanDays: 30) }
                Button("3 aydan eski olanlar") { store.selectOlder(thanDays: 90) }
            }
            .fixedSize()
            Spacer()
            Text(selected.isEmpty ? "Silmek istediklerinizi işaretleyin" : "\(selected.count) seçili · \(Fmt.size(size))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
                .help(session.hasWorktree ? Self.worktreeHelp : "Taşınacaklar arasına ekle")
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
                    StatusBadge(label: "Taşınamaz", symbol: "lock.fill", tint: .gray, help: Self.worktreeHelp)
                } else if session.isArchived {
                    StatusBadge(label: "Arşivde", symbol: "archivebox.fill", tint: .gray, help: "Claude'da arşivde. Taşınınca hedef hesapta da arşivde olur.")
                } else {
                    StatusBadge(label: "Listede", symbol: "list.bullet", tint: .blue, help: "Claude'un kenar çubuğunda görünüyor.")
                }
            }
            .width(min: 90, ideal: 104, max: 130)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    static let worktreeHelp = "Çalışma ağacında (worktree) açılmış oturumlar taşınmaz: Claude sahipsiz sandığı çalışma ağacı klasörünü temizleyebilir."
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
            Text(selectedCount == 0 ? "Taşınacak oturumları işaretleyin" : "\(selectedCount) seçili")
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
                Label(chosen.isEmpty ? "Taşı" : "\(chosen.count) Oturumu Taşı", systemImage: "arrow.left.arrow.right")
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
    let text: String

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
            Button("Çöp Kutusunu Aç") {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
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
