import AppIntents

/// Siri phrases and the app's tiles in the Shortcuts app.
struct HackbanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickAddIntent(),
            phrases: [
                "Quick add in \(.applicationName)",
                "Add a card in \(.applicationName)",
                "Add to \(.applicationName)",
            ],
            shortTitle: "Quick Add",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenQuickAddIntent(),
            phrases: ["Open \(.applicationName) quick add"],
            shortTitle: "Open Quick Add",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: GetMyCardsIntent(),
            phrases: ["What's on my \(.applicationName) cards", "Show my \(.applicationName) cards"],
            shortTitle: "My Cards",
            systemImageName: "person.crop.rectangle.stack"
        )
        AppShortcut(
            intent: OpenBoardIntent(),
            phrases: ["Open a \(.applicationName) board", "Open \(\.$board) in \(.applicationName)"],
            shortTitle: "Open Board",
            systemImageName: "rectangle.split.3x1"
        )
        AppShortcut(
            intent: FindCardsIntent(),
            phrases: ["Search \(.applicationName)"],
            shortTitle: "Find Cards",
            systemImageName: "magnifyingglass"
        )
    }

    static var shortcutTileColor: ShortcutTileColor = .red
}
