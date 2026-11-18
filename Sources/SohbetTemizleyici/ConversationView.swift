import SwiftUI

/// Loads a conversation off the main thread and prepares Claude's replies for display.
@MainActor
final class ConversationLoader: ObservableObject {
    struct Row: Identifiable, Sendable {
        let id: Int
        let role: ChatMessage.Role
        let text: AttributedString
        let date: Date?
    }

    @Published private(set) var rows: [Row]?

    func load(_ item: CleanItem) async {
        guard rows == nil else { return }
        guard let url = item.transcript else {
            rows = []
            return
        }
        rows = await Task.detached(priority: .userInitiated) {
            TranscriptReader.messages(at: url).map { message in
                let text = message.role == .assistant ? Self.styled(message.text) : AttributedString(message.text)
                return Row(id: message.id, role: message.role, text: text, date: message.date)
            }
        }.value
    }

    /// Claude's replies are Markdown. Bold, inline code and links are rendered; headings and lists stay as typed.
    /// Fenced code blocks are cut out first: inline Markdown alone would fold them onto one line, language tag included.
    nonisolated static func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        var prose: [Substring] = []
        var code: [Substring]?

        func append(_ part: AttributedString) {
            if !result.characters.isEmpty { result += AttributedString("\n") }
            result += part
        }
        func flushProse() {
            guard !prose.isEmpty else { return }
            let chunk = prose.joined(separator: "\n")
            prose = []
            append((try? AttributedString(markdown: chunk, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                   ?? AttributedString(chunk))
        }
        func flushCode() {
            guard let lines = code else { return }
            code = nil
            var block = AttributedString(lines.joined(separator: "\n"))
            block.inlinePresentationIntent = .code
            append(block)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.drop(while: { $0 == " " }).hasPrefix("```") {
                if code == nil {
                    flushProse()
                    code = []
                } else {
                    flushCode()
                }
            } else if code != nil {
                code?.append(line)
            } else {
                prose.append(line)
            }
        }
        flushProse()
        flushCode()  // a reply cut off inside a code block
        return result
    }
}

/// Reading sheet: the whole conversation as a person sees it, without tool outputs.
struct ConversationView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var loader = ConversationLoader()
    let item: CleanItem

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(verbatim: [item.detail, Fmt.absolute(item.date), Fmt.size(item.size)].joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                if let rows = loader.rows {
                    Text("\(rows.filter { $0.role != .tool }.count) mesaj · araç çıktıları gösterilmez")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Markdown Olarak Arşivle…") { store.archive([item]) }
                Button("Kapat") { store.previewItem = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 480, idealHeight: 640)
        .task { await loader.load(item) }
    }

    @ViewBuilder private var content: some View {
        if let rows = loader.rows {
            if rows.isEmpty {
                ContentUnavailableView("Okunabilir mesaj yok", systemImage: "text.bubble",
                                       description: Text("Bu sohbette yalnızca araç çıktıları veya sistem kayıtları var."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { MessageRow(row: $0) }
                    }
                    .padding(20)
                }
            }
        } else {
            ProgressView("Sohbet okunuyor…")
        }
    }
}

private struct MessageRow: View {
    let row: ConversationLoader.Row

    var body: some View {
        switch row.role {
        case .user:
            VStack(alignment: .trailing, spacing: 3) {
                Text(row.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                if let date = row.date {
                    Text(verbatim: Fmt.absolute(date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 80)
        case .assistant:
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "Claude")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(row.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
        case .tool:
            Label {
                Text(row.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }
}
