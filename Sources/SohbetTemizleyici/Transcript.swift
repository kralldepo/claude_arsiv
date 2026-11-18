import Foundation

/// One readable message of a Claude Code conversation.
struct ChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant, tool }
    let id: Int
    let role: Role
    let text: String
    let date: Date?
}

/// Turns a transcript (.jsonl) into what a person reads: prompts, Claude's replies and one-line tool calls.
/// Tool outputs, hidden reminders, thinking blocks and side agents are left out.
enum TranscriptReader {
    /// Characters kept per message; a pasted log can be megabytes long.
    static let messageLimit = 20_000

    private static let toolResultMarker = Data("\"tool_use_id\"".utf8)
    private static let hidden = try! NSRegularExpression(
        pattern: "<(system-reminder|local-command-stdout|local-command-stderr|command-message)>[\\s\\S]*?</\\1>")
    private static let commandTags = try! NSRegularExpression(pattern: "</?(command-name|command-args)>")
    private static let toolFields = ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt", "skill"]

    static func messages(at url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var list: [ChatMessage] = []
        func add(_ role: ChatMessage.Role, _ text: String, _ date: Date?) {
            list.append(ChatMessage(id: list.count, role: role, text: text, date: date))
        }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Tool results make up most of a transcript and are never shown; skip them before parsing.
            if line.range(of: toolResultMarker) != nil { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  (obj["isSidechain"] as? Bool) != true, (obj["isMeta"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            let date = (obj["timestamp"] as? String).flatMap(parseDate)
            if type == "user" {
                if let text = userText(message["content"]) { add(.user, text, date) }
                continue
            }
            if let text = message["content"] as? String {
                if let clean = clean(text).nonEmpty { add(.assistant, clip(clean), date) }
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = (block["text"] as? String).map(clean)?.nonEmpty { add(.assistant, clip(text), date) }
                case "tool_use":
                    add(.tool, toolSummary(block), date)
                default:
                    break
                }
            }
        }
        return list
    }

    /// Everything a person could search for in one conversation, capped so huge chats stay cheap.
    static func searchText(at url: URL) -> String {
        var text = ""
        for message in messages(at: url) {
            text += message.text
            text += "\n"
            if text.utf8.count > 3_000_000 { break }
        }
        return text
    }

    private static func userText(_ content: Any?) -> String? {
        var parts: [String] = []
        if let text = content as? String {
            parts = [text]
        } else if let blocks = content as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text": if let text = block["text"] as? String { parts.append(text) }
                case "image": parts.append(String(localized: "[görsel]"))
                default: continue
                }
            }
        }
        let text = clean(parts.joined(separator: "\n\n"))
        guard !text.isEmpty, !text.hasPrefix("Caveat:") else { return nil }
        return clip(text)
    }

    static func clean(_ raw: String) -> String {
        var text = raw
        for regex in [hidden, commandTags] {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ text: String) -> String {
        guard text.count > messageLimit else { return text }
        return String(text.prefix(messageLimit)) + "\n\n" + String(localized: "… (kısaltıldı)")
    }

    private static func toolSummary(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "Tool"
        let input = block["input"] as? [String: Any] ?? [:]
        for key in toolFields {
            if let value = (input[key] as? String)?.clipped(200).nonEmpty { return name + ": " + value }
        }
        return name
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    private static func parseDate(_ text: String) -> Date? {
        isoFractional.date(from: text) ?? iso.date(from: text)
    }
}

/// Writes conversations as Markdown files people can read without Claude.
enum Archiver {
    struct Outcome: Sendable {
        var written: [URL] = []
        var failures: [String] = []
    }

    static func archive(_ items: [CleanItem], to folder: URL) -> Outcome {
        var outcome = Outcome()
        for item in items {
            guard let transcript = item.transcript else { continue }
            let text = markdown(for: item, messages: TranscriptReader.messages(at: transcript))
            let file = uniqueURL(in: folder, base: fileName(for: item))
            do {
                try text.write(to: file, atomically: true, encoding: .utf8)
                outcome.written.append(file)
            } catch {
                outcome.failures.append("\(item.title): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    static func markdown(for item: CleanItem, messages: [ChatMessage]) -> String {
        var lines = ["# " + item.title, ""]
        lines.append("- **" + String(localized: "Klasör") + ":** " + item.detail)
        lines.append("- **" + String(localized: "Son değişiklik") + ":** " + Fmt.absolute(item.date))
        if let id = item.transcript?.deletingPathExtension().lastPathComponent {
            lines.append("- **" + String(localized: "Oturum") + ":** `" + id + "`")
        }
        lines += ["", "---", ""]
        var claudeSpeaking = false
        for message in messages {
            let stamp = message.date.map { " · " + Fmt.absolute($0) } ?? ""
            switch message.role {
            case .user:
                lines += ["## " + String(localized: "Siz") + stamp, "", message.text, ""]
                claudeSpeaking = false
            case .assistant, .tool:
                if !claudeSpeaking { lines += ["## Claude" + stamp, ""] }
                claudeSpeaking = true
                let body = message.role == .tool ? "> " + message.text.replacingOccurrences(of: "\n", with: " ") : message.text
                lines += [body, ""]
            }
        }
        if messages.isEmpty { lines += ["*" + String(localized: "Bu sohbette okunabilir mesaj bulunamadı.") + "*", ""] }
        lines += ["---", "", "<sub>" + String(localized: "Sohbet Temizleyici ile arşivlendi") + " · " + Fmt.absolute(Date()) + "</sub>", ""]
        return lines.joined(separator: "\n")
    }

    private static func fileName(for item: CleanItem) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = item.title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ").joined(separator: " ")
        let title = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        return Fmt.day(item.date) + " " + (title.isEmpty ? String(localized: "sohbet") : title)
    }

    private static func uniqueURL(in folder: URL, base: String) -> URL {
        var url = folder.appendingPathComponent(base + ".md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter)).md")
            counter += 1
        }
        return url
    }
}

/// Finds conversations whose messages contain a text. Each transcript is read once and kept in memory.
actor ContentIndex {
    private var cache: [String: (date: Date, text: String)] = [:]

    func matches(_ query: String, in items: [CleanItem]) -> Set<String> {
        let needle = Self.fold(query)
        var found = Set<String>()
        for item in items {
            if Task.isCancelled { break }
            guard let url = item.transcript else { continue }
            let text: String
            if let hit = cache[item.id], hit.date == item.date {
                text = hit.text
            } else {
                text = Self.fold(TranscriptReader.searchText(at: url))
                cache[item.id] = (item.date, text)
            }
            if text.contains(needle) { found.insert(item.id) }
        }
        return found
    }

    /// Case- and accent-blind, and "ı" equals "i", so Turkish and English text both match.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }
}
