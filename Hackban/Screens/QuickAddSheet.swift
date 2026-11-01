import SwiftUI
import WidgetKit

/// Todoist-style quick add: one line of text with inline #board/list, @person, !label, ^top, *repeat and dates.
struct QuickAddSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var initialTarget: UUID?

    @State private var text = ""
    @State private var notes = ""
    @State private var showNotes = false
    @State private var targetId: UUID?
    @State private var targets = QuickAddTargets.load()
    @State private var boards: [BoardRef] = []
    @State private var busy = false
    @State private var added: [AddedCard] = []
    @FocusState private var focused: Bool

    private var parsed: ParsedQuickAdd { QuickAddParser.parse(text) }
    private var target: QuickAddTarget? { targets.first { $0.id == targetId } ?? QuickAddTargets.defaultTarget }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Card title, e.g. Order stickers tomorrow #Events @me", text: $text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit { add(keepOpen: true) }
                if showNotes {
                    TextField("Description", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.subheadline)
                }
                chips
                suggestions
                Spacer(minLength: 0)
                if !added.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(added.suffix(3), id: \.cardId) { a in
                            SwiftUI.Label("\(a.title) → \(a.boardName) › \(a.listName)", systemImage: "checkmark.circle.fill")
                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                HStack {
                    Menu {
                        Picker("Target", selection: $targetId) {
                            ForEach(targets) { t in Text("\(t.name) · \(t.subtitle)").tag(Optional(t.id)) }
                        }
                    } label: {
                        SwiftUI.Label(target.map { $0.name } ?? "No target", systemImage: "tray.and.arrow.down")
                            .font(.subheadline)
                    }
                    .disabled(targets.isEmpty)
                    Button { showNotes.toggle() } label: { Image(systemName: "text.alignleft") }
                        .accessibilityLabel("Add description")
                    Spacer()
                    Button { add(keepOpen: false) } label: {
                        if busy { ProgressView() } else { Text("Add").bold().padding(.horizontal, 8) }
                    }
                    .prominentGlassButton()
                    .disabled(parsed.title.isEmpty || busy || (parsed.board == nil && target == nil))
                }
            }
            .padding()
            .navigationTitle("Quick add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                targetId = initialTarget ?? QuickAddTargets.defaultTarget?.id
                focused = true
            }
            .task { boards = await BoardDirectory.all() }
        }
    }

    /// What the parser understood, so you can see where the card will land.
    private var chips: some View {
        let p = parsed
        let board = p.board.flatMap { q in QuickAddParser.best(q, in: boards, name: \.name) }
        return FlowLayout(spacing: 6) {
            if let board {
                chip("rectangle.split.3x1", board.name + (p.list.map { " › \($0)" } ?? ""), .blue)
            } else if let q = p.board {
                chip("questionmark.circle", "No board \u{201C}\(q)\u{201D}", .red)
            } else if let target {
                chip("tray.and.arrow.down", target.subtitle, .secondary)
            }
            if let due = p.due { chip("calendar", Fmt.due(due), .orange) }
            if let r = p.recurrence { chip("repeat", r.label, .orange) }
            ForEach(p.members, id: \.self) { chip("person", $0 == "me" ? "Me" : $0, .green) }
            ForEach(p.labels, id: \.self) { chip("tag", $0, .purple) }
            if p.top == true { chip("arrow.up.to.line", "Top", .secondary) }
        }
    }

    private func chip(_ icon: String, _ text: String, _ color: Color) -> some View {
        SwiftUI.Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    /// While typing "#boa", offer matching boards.
    @ViewBuilder
    private var suggestions: some View {
        if let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("#"), !last.contains("/") {
            let q = String(last.dropFirst()).replacingOccurrences(of: "_", with: " ")
            let matches = boards.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }.prefix(6)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(Array(matches)) { b in
                        Button(b.name) {
                            var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                            words[words.count - 1] = "#" + b.name.replacingOccurrences(of: " ", with: "_")
                            text = words.joined(separator: " ") + " "
                        }
                        .glassButton()
                        .font(.footnote)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func add(keepOpen: Bool) {
        let p = parsed
        guard !p.title.isEmpty, !busy else { return }
        busy = true
        let n = notes
        Task {
            defer { busy = false }
            do {
                let card = try await QuickAddService.add(p, target: target, notes: n)
                added.append(card)
                text = ""
                notes = ""
                WidgetCenter.shared.reloadAllTimelines()
                if keepOpen { focused = true } else {
                    dismiss()
                    app.flash("Added to \(card.boardName) › \(card.listName)")
                }
            } catch {
                app.report(error)
            }
        }
    }
}
