import AppKit
import SwiftUI

/// Menu bar menu: how much is piling up, plus shortcuts. Shown only when turned on in Settings.
struct MenuBarContent: View {
    @EnvironmentObject private var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let leftover = store.leftoverTotal
        Text("Arka planda kalan: \(leftover.count) sohbet · \(Fmt.size(leftover.size))")
        Text("Önbellek: \(Fmt.size(store.total(of: .cache)))")
        if store.total(of: .large) > 0 {
            Text("Büyük dosyalar: \(Fmt.size(store.total(of: .large)))")
        }
        Divider()
        Button("Sohbet Temizleyici'yi Aç") {
            store.openMainWindow = { openWindow(id: "main") }
            store.showMainWindow()
        }
        Button("Yeniden Tara") { Task { await store.rescan() } }
            .disabled(store.isScanning)
        Divider()
        SettingsLink {
            Text("Ayarlar…")
        }
        Button("Çık") { NSApp.terminate(nil) }
    }
}

/// Settings window (⌘,).
struct SettingsView: View {
    @EnvironmentObject private var store: Store

    private static let limits = [250, 500, 1000, 2000, 5000]

    var body: some View {
        Form {
            Section {
                Toggle("Menü çubuğunda göster", isOn: $store.showInMenuBar)
                Text("Pencereyi kapatınca uygulama menü çubuğunda çalışmaya devam eder ve 30 dakikada bir tarar. Hiçbir şeyi kendiliğinden silmez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Arka planda kalan sohbetler birikince bildir", isOn: $store.notifyEnabled)
                    .disabled(!store.showInMenuBar)
                Picker("Bildirim sınırı", selection: $store.notifyThresholdMB) {
                    ForEach(Self.limits, id: \.self) { limit in
                        Text(Fmt.size(Int64(limit) * 1_000_000)).tag(limit)
                    }
                }
                .disabled(!store.showInMenuBar || !store.notifyEnabled)
                if store.notificationsDenied {
                    Text("Bildirim izni verilmedi. Sistem Ayarları › Bildirimler bölümünden açabilirsiniz.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Günde en fazla bir kez haber verir; yalnızca menü çubuğunda çalışırken.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Oturum açınca başlat", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                if store.launchNeedsApproval {
                    Text("Sistem Ayarları › Genel › Giriş Öğeleri bölümünden onay verin.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Uygulama Mac'inizin diline göre Türkçe veya İngilizce açılır. Değiştirmek için: Sistem Ayarları › Genel › Dil ve Bölge › Uygulamalar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
