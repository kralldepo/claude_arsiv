import Foundation

/// A row is one conversation, one bundle of cache/log files, or one large download Claude keeps.
enum ItemKind: Sendable {
    case chat
    case cache
    case large
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
        case .leftover: return String(localized: "Arka planda kalmış")
        case .cleanable: return String(localized: "Temizlenebilir")
        case .inUse: return String(localized: "Şu an kullanımda")
        case .archived: return String(localized: "Claude'da arşivde")
        case .active: return String(localized: "Claude'da açık")
        case .needsQuit: return String(localized: "Önce Claude'u kapatın")
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
        case .leftover: return String(localized: "Claude uygulamasında artık görünmüyor; yalnızca diskte yer kaplıyor.")
        case .cleanable: return String(localized: "Güvenle silinebilir; gerekirse yeniden oluşturulur.")
        case .inUse: return String(localized: "Son 30 dakikada yazılmış; açık bir oturum olabilir, korunuyor.")
        case .archived: return String(localized: "Claude'un arşivinde duruyor. Silmek için önce Claude uygulamasından silin.")
        case .active: return String(localized: "Claude'un kenar çubuğunda duruyor. Silmek için önce Claude uygulamasından silin.")
        case .needsQuit: return String(localized: "Claude açıkken kullanımda. Claude'dan çıkınca (⌘Q) kilit kalkar.")
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
    /// Chats: the Claude Code project folder the conversation belongs to.
    var project: String? = nil
    /// Large files: what happens after deleting, repeated in the confirmation dialog.
    var warning: String? = nil
    /// Only while Claude is closed: it uses these files while it runs.
    var needsClaudeClosed = false

    var isLocked: Bool { status.isLocked }
    /// The conversation file itself (chats only).
    var transcript: URL? { kind == .chat ? urls.first : nil }
}

enum Fmt {
    /// Dates follow the language the app runs in (Turkish or English), not the Mac's region.
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "tr")

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "0 bayt" instead of "Sıfır KB"
        return formatter.string(fromByteCount: bytes)
    }

    static func relative(_ date: Date) -> String {
        let now = Date()
        if abs(now.timeIntervalSince(date)) < 60 { return String(localized: "az önce") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(locale))
    }

    /// "2026-11-17" for file names.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
