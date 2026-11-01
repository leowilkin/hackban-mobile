import SwiftUI

/// A card on the board (port of board/card-front.tsx).
struct CardFront: View {
    let card: BoardCard
    let account: Account
    let board: Board?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                if !card.labels.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(card.labels, id: \.labelId) { LabelChip(label: $0.label) }
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    if card.dueComplete && card.due == nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(card.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .strikethrough(card.dueComplete && card.due == nil, color: .secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                badges
            }
            .padding(10)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        .opacity(card.id.hasPrefix("tmp-") ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the card")
    }

    @ViewBuilder
    private var cover: some View {
        if let url = card.coverUrl {
            AuthImage(url, account: account) { Color(.tertiarySystemFill) }
                .frame(height: card.coverSize == "full" ? 160 : 110)
                .frame(maxWidth: .infinity)
                .clipped()
        } else if let color = card.coverColor {
            Palette.solid(color).frame(height: card.coverSize == "full" ? 60 : 32)
        }
    }

    @ViewBuilder
    private var badges: some View {
        let hasBadges = card.due != nil || card.watching == true || card.hasDescription || card.commentCount > 0
            || card.attachmentCount > 0 || (card.checkTotal ?? 0) > 0 || card.isBlocked || card.isBlocking || !card.members.isEmpty
        if hasBadges {
            HStack(spacing: 8) {
                FlowLayout(spacing: 8) {
                    if card.isBlocked {
                        Badge(systemImage: "nosign", text: "Blocked", color: .white, background: Color(hex: "#c9372c"))
                    }
                    if card.isBlocking {
                        Badge(systemImage: "exclamationmark.triangle", text: "Blocking", color: Color(hex: "#172b4d"), background: Color(hex: "#f5cd47"))
                    }
                    if let due = card.due { DueBadge(due: due, complete: card.dueComplete, recurrence: card.recurrence) }
                    if card.watching == true { Badge(systemImage: "eye") }
                    if card.hasDescription { Badge(systemImage: "text.alignleft") }
                    if card.commentCount > 0 { Badge(systemImage: "bubble.left", text: "\(card.commentCount)") }
                    if card.attachmentCount > 0 { Badge(systemImage: "paperclip", text: "\(card.attachmentCount)") }
                    if let total = card.checkTotal, total > 0 {
                        let done = card.checkDone ?? 0
                        Badge(systemImage: "checklist", text: "\(done)/\(total)",
                              color: done == total ? .white : .secondary, background: done == total ? Color(hex: "#1f845a") : nil)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: -6) {
                    ForEach(card.members.prefix(4), id: \.userId) { m in
                        AvatarView(m.user, account: account, size: 22)
                            .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                    }
                }
            }
        }
    }
}

/// Long-press menu on a card: the web's quick editor and hover shortcuts.
struct CardQuickMenu: View {
    @Bindable var model: BoardModel
    let card: BoardCard
    var onOpen: (String) -> Void

    var body: some View {
        Button { onOpen(card.id) } label: { SwiftUI.Label("Open card", systemImage: "arrow.up.left.and.arrow.down.right") }
        if model.canWrite {
            Button { model.toggleComplete(card) } label: {
                SwiftUI.Label(card.dueComplete ? "Mark incomplete" : "Mark complete", systemImage: card.dueComplete ? "circle" : "checkmark.circle")
            }
            if let me = model.me {
                let joined = card.members.contains { $0.userId == me.id }
                Button { model.toggleMember(card, user: me) } label: {
                    SwiftUI.Label(joined ? "Leave" : "Join", systemImage: joined ? "person.badge.minus" : "person.badge.plus")
                }
            }
            if let labels = model.board?.labels, !labels.isEmpty {
                Menu {
                    ForEach(labels) { l in
                        let on = card.labels.contains { $0.labelId == l.id }
                        Button { model.toggleLabel(card, label: l) } label: {
                            SwiftUI.Label(l.name.isEmpty ? Palette.name(l.color) : l.name, systemImage: on ? "checkmark.square.fill" : "square")
                        }
                    }
                } label: { SwiftUI.Label("Labels", systemImage: "tag") }
            }
            Menu {
                Button("Today") { setDue(Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now)) }
                Button("Tomorrow") { setDue(Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now)!)) }
                Button("Next week") { setDue(Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: .now)!)) }
                if card.due != nil { Button("Remove due date", role: .destructive) { setDue(nil) } }
            } label: { SwiftUI.Label("Due date", systemImage: "calendar") }
            Menu {
                Button("Top of list") { model.moveCardToEdge(card, top: true) }
                Button("Bottom of list") { model.moveCardToEdge(card, top: false) }
                Divider()
                ForEach(model.board?.lists.filter { $0.id != card.listId } ?? []) { l in
                    Button(l.name) { model.moveCard(card.id, to: l.id, after: l.cards.last?.id) }
                }
            } label: { SwiftUI.Label("Move", systemImage: "arrow.right.square") }
            Button { model.archive(card) } label: { SwiftUI.Label("Archive", systemImage: "archivebox") }
        }
        if let url = model.account.webURL(card: card.id) {
            ShareLink(item: url) { SwiftUI.Label("Share link", systemImage: "square.and.arrow.up") }
        }
    }

    private func setDue(_ date: Date?) {
        model.updateCard(card.id, ["due": .orNull(date)]) { $0.due = date }
    }
}

/// Wrapping row layout for chips and badges.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
