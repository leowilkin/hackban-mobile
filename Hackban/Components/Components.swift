import SwiftUI

// MARK: Liquid Glass with an iOS 18 fallback

extension View {
    /// Liquid Glass on iOS 26, a material on iOS 18.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(), in: .capsule)
        } else {
            self.background(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(.regularMaterial), in: Capsule())
        }
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26.0, *) { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.borderedProminent) }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(iOS 26.0, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
    }
}

// MARK: Chips and badges

struct LabelChip: View {
    var label: BoardLabel
    var compact = false

    var body: some View {
        let c = Palette.label(label.color)
        Text(compact ? " " : (label.name.isEmpty ? " " : label.name))
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 0 : 7)
            .frame(minWidth: compact ? 32 : 36, minHeight: compact ? 8 : 18)
            .background(c.background, in: RoundedRectangle(cornerRadius: compact ? 4 : 4))
            .foregroundStyle(c.foreground)
            .accessibilityLabel(label.name.isEmpty ? Palette.name(label.color) : label.name)
    }
}

struct DueBadge: View {
    var due: Date
    var complete: Bool
    var recurrence: String?

    var body: some View {
        let state = DueState.of(due: due, complete: complete)
        HStack(spacing: 3) {
            Image(systemName: complete ? "checkmark.square.fill" : "clock")
            Text(Fmt.due(due))
            if recurrence != nil { Image(systemName: "repeat") }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(state.background, in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(state.foreground)
    }
}

struct Badge: View {
    var systemImage: String
    var text: String?
    var color: Color = .secondary
    var background: Color? = nil

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            if let text { Text(text) }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, background == nil ? 0 : 5).padding(.vertical, background == nil ? 0 : 2)
        .background(background ?? .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

struct AccountBadge: View {
    var account: Account

    var body: some View {
        Text(account.displayLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(AccountTint.color(account.tint).opacity(0.18), in: Capsule())
            .foregroundStyle(AccountTint.color(account.tint))
    }
}

struct BoardTile: View {
    var name: String
    var background: String
    var image: String?
    var starred: Bool?
    var onStar: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            BoardBackground(background, image: image)
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
            Text(name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(10)
        }
        .frame(height: 84)
        .overlay(alignment: .bottomTrailing) {
            if let onStar {
                Button(action: onStar) {
                    Image(systemName: starred == true ? "star.fill" : "star")
                        .foregroundStyle(starred == true ? .yellow : .white)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(starred == true ? "Unstar" : "Star")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Bottom toast for errors and confirmations.
struct ToastOverlay: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCapsule()
                    .padding(.bottom, 90)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
    }
}

extension View {
    func toasts() -> some View { modifier(ToastOverlay()) }
}

/// Markdown body text (descriptions, comments).
struct MarkdownText: View {
    var text: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)) {
            Text(attributed).textSelection(.enabled)
        } else {
            Text(text).textSelection(.enabled)
        }
    }
}

struct EmptyState: View {
    var title: String
    var systemImage: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            SwiftUI.Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}

/// Runs an async action and reports failures through the toast.
@MainActor
func attempt(_ model: AppModel, _ work: @escaping () async throws -> Void) {
    Task {
        do { try await work() } catch { model.report(error) }
    }
}
