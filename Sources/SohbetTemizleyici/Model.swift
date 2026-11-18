import Foundation

/// A row is either one conversation or one bundle of cache/log files.
enum ItemKind: Sendable {
    case chat
    case cache
}

/// Why an item can or cannot be deleted. The order is the sort order of the "Durum" column.
enum ItemStatus: Int, Comparable, Sendable {
    case leftover   // conversation the Claude app no longer lists
    case cleanable  // cache/log that can go right now
    case inUse      // written to in the last 30 minutes
    case archived   // still in Claude's archive
    case active     // still in Claude's sidebar
    case needsQuit  // cache/log Claude uses while it is open

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var isLocked: Bool {
        switch self {
        case .leftover, .cleanable: return false
        case .inUse, .archived, .active, .needsQuit: return true
        }
    }

    var label: String {
        switch self {
        case .leftover: return "Arka planda kalmış"
        case .cleanable: return "Temizlenebilir"
        case .inUse: return "Şu an kullanımda"
        case .archived: return "Claude'da arşivde"
        case .active: return "Claude'da açık"
        case .needsQuit: return "Önce Claude'u kapatın"
        }
    }

    var symbol: String {
        switch self {
        case .leftover: return "tray.full.fill"
        case .cleanable: return "sparkles"
        case .inUse: return "bolt.fill"
        case .archived: return "archivebox.fill"
        case .active, .needsQuit: return "lock.fill"
        }
    }

    var help: String {
        switch self {
        case .leftover: return "Claude uygulamasında artık görünmüyor; yalnızca diskte yer kaplıyor."
        case .cleanable: return "Güvenle silinebilir; gerekirse yeniden oluşturulur."
        case .inUse: return "Son 30 dakikada yazılmış; açık bir oturum olabilir, korunuyor."
        case .archived: return "Claude'un arşivinde duruyor. Silmek için önce Claude uygulamasından silin."
        case .active: return "Claude'un kenar çubuğunda duruyor. Silmek için önce Claude uygulamasından silin."
        case .needsQuit: return "Claude açıkken kullanımda. Claude'dan çıkınca (⌘Q) kilit kalkar."
        }
    }
}

struct CleanItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ItemKind
    let title: String
    let detail: String
    let date: Date
    let size: Int64
    let status: ItemStatus
    /// Everything that goes to the Trash together for this row.
    let urls: [URL]
    /// Tooltip text: the conversation's first prompt, or the folders a cache row covers.
    let preview: String?

    var isLocked: Bool { status.isLocked }
}

enum Fmt {
    static let locale = Locale(identifier: "tr_TR")

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        let now = Date()
        if abs(now.timeIntervalSince(date)) < 60 { return "az önce" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale))
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }

    /// One line, whitespace collapsed, cut at 140 characters.
    var oneLine: String { clipped(140) }

    func clipped(_ limit: Int) -> String {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
