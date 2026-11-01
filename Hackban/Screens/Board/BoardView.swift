import SwiftUI

struct BoardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    let route: BoardRoute
    @State private var model: BoardModel?

    var body: some View {
        Group {
            if let model {
                BoardContent(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard model == nil, let account = app.account(route.account) else { return }
            let m = BoardModel(account: account, boardId: route.boardId)
            m.app = app
            model = m
        }
        .task(id: model == nil) {
            guard let model else { return }
            await model.load()
            model.startLive()
        }
        .onDisappear { model?.stopLive() }
        .onChange(of: scenePhase) { _, phase in
            guard let model else { return }
            if phase == .active { model.startLive(); model.scheduleReload(after: .zero) } else if phase == .background { model.stopLive() }
        }
    }
}

private struct BoardContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BoardModel
    @State private var openCard: CardRoute?
    @State private var showFilters = false
    @State private var showMenu = false
    @State private var showShare = false
    @State private var addingList = false
    @State private var newListName = ""

    var body: some View {
        ZStack {
            if let board = model.board {
                BoardBackground(board.background, image: board.bgImage).ignoresSafeArea()
                lists(board)
            } else if let error = model.error {
                EmptyState(title: "Can't open this board", systemImage: "exclamationmark.triangle", message: error)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.board?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { toolbar }
        .sheet(item: $openCard, onDismiss: { model.scheduleReload(after: .zero) }) { route in
            CardDetailSheet(route: route)
        }
        .sheet(isPresented: $showFilters) { FiltersSheet(model: model) }
        .sheet(isPresented: $showMenu, onDismiss: { model.scheduleReload(after: .zero) }) { BoardMenuSheet(model: model) }
        .sheet(isPresented: $showShare, onDismiss: { model.scheduleReload(after: .zero) }) { BoardShareSheet(model: model) }
        .refreshable { await model.load() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let board = model.board {
                Button {
                    let next = !board.starred
                    model.mutate({ $0.starred = next }) { [api = model.api] in try await api.starBoard(board.id, next) }
                } label: {
                    Image(systemName: board.starred ? "star.fill" : "star")
                }
                .accessibilityLabel(board.starred ? "Unstar board" : "Star board")
                Button { showFilters = true } label: {
                    Image(systemName: model.filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter cards")
                Menu {
                    Button { showShare = true } label: { SwiftUI.Label("Share", systemImage: "person.badge.plus") }
                    Button { showMenu = true } label: { SwiftUI.Label("Board menu", systemImage: "slider.horizontal.3") }
                    if let url = model.account.webURL(board: board.id) {
                        ShareLink(item: url) { SwiftUI.Label("Share link", systemImage: "square.and.arrow.up") }
                    }
                    Button {
                        app.quickAdd = .init(target: nil)
                    } label: { SwiftUI.Label("Quick add", systemImage: "plus.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func lists(_ board: Board) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(board.lists) { list in
                    ListColumn(model: model, list: list) { openCard = CardRoute(account: model.account.id, cardId: $0) }
                        .containerRelativeFrame(.horizontal) { w, _ in min(w - 56, 320) }
                }
                if model.canWrite { addListColumn.containerRelativeFrame(.horizontal) { w, _ in min(w - 56, 320) } }
            }
            .scrollTargetLayout()
            .padding(.vertical, 8)
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollIndicators(.hidden)
        .overlay(alignment: .top) {
            if model.filters.isActive {
                Button { model.filters = CardFilters() } label: {
                    SwiftUI.Label("\(model.filters.count) filter\(model.filters.count == 1 ? "" : "s") on · Clear", systemImage: "line.3.horizontal.decrease")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .glassCapsule()
                .padding(.top, 4)
            }
        }
    }

    private var addListColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            if addingList {
                TextField("List name", text: $newListName)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(addList)
                HStack {
                    Button("Add list", action: addList).prominentGlassButton()
                    Button("Cancel") { addingList = false; newListName = "" }
                }
            } else {
                Button { addingList = true } label: {
                    SwiftUI.Label("Add a list", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .padding(12)
        .glassPanel(cornerRadius: 16)
    }

    private func addList() {
        let name = newListName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.addList(name)
        newListName = ""
    }
}

// MARK: List column

struct ListColumn: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BoardModel
    let list: BoardList
    var onOpen: (String) -> Void

    @State private var adding = false
    @State private var addTop = false
    @State private var newTitle = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var copying = false
    @State private var copyName = ""
    @State private var moving = false
    @State private var confirm: Confirm?
    @State private var dropTarget = false
    @FocusState private var addFocused: Bool

    enum Confirm: Identifiable { case archiveAll, delete; var id: Self { self } }

    var body: some View {
        let cards = model.visibleCards(list)
        VStack(alignment: .leading, spacing: 0) {
            header(count: cards.count)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if adding && addTop { addField }
                    ForEach(cards) { card in
                        CardFront(card: card, account: model.account, board: model.board)
                            .onTapGesture { if !card.id.hasPrefix("tmp-") { onOpen(card.id) } }
                            .contextMenu { CardQuickMenu(model: model, card: card, onOpen: onOpen) }
                            .draggable("hbcard:\(card.id)") {
                                CardFront(card: card, account: model.account, board: model.board).frame(width: 260)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, before: card.id)
                            }
                    }
                    if adding && !addTop { addField }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            if model.canWrite && !adding {
                Button {
                    addTop = false; adding = true; addFocused = true
                } label: {
                    SwiftUI.Label("Add a card", systemImage: "plus").font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 16, tint: list.color.map { Palette.solid($0).opacity(0.25) })
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.brand, lineWidth: dropTarget ? 2 : 0))
        .dropDestination(for: String.self) { items, _ in
            drop(items, before: nil)
        } isTargeted: { dropTarget = $0 }
        .alert("Rename list", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") { if !renameText.isEmpty { model.renameList(list.id, renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Copy list", isPresented: $copying) {
            TextField("Name", text: $copyName)
            Button("Copy") { if !copyName.isEmpty { model.attempt { [api = model.api, id = list.id, name = copyName] in try await api.copyList(id, name: name) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(confirm == .delete ? "Delete \(list.name) and all its cards? This can't be undone." : "Archive every card in \(list.name)?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if confirm == .delete {
                Button("Delete list", role: .destructive) { model.attempt { [api = model.api, id = list.id] in try await api.deleteList(id) } }
            } else {
                Button("Archive all cards", role: .destructive) { model.attempt { [api = model.api, id = list.id] in try await api.archiveAllCards(id) } }
            }
        }
        .sheet(isPresented: $moving, onDismiss: { model.scheduleReload(after: .zero) }) {
            MoveListSheet(model: model, list: list)
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 8) {
            if let color = list.color { Circle().fill(Palette.solid(color)).frame(width: 10, height: 10) }
            Text(list.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.canWrite { listMenu }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .draggable("hblist:\(list.id)") {
            Text(list.name).font(.headline).padding(12).glassPanel()
        }
    }

    private var listMenu: some View {
        Menu {
            Button { addTop = true; adding = true; addFocused = true } label: { SwiftUI.Label("Add card to top", systemImage: "text.badge.plus") }
            Button { renameText = list.name; renaming = true } label: { SwiftUI.Label("Rename", systemImage: "pencil") }
            Menu {
                Button("None") { model.setListColor(list.id, nil) }
                ForEach(Palette.baseColors, id: \.self) { c in
                    Button(c.capitalized) { model.setListColor(list.id, c) }
                }
            } label: { SwiftUI.Label("Color", systemImage: "paintpalette") }
            Menu {
                ForEach(CardSort.allCases) { s in
                    Button(s.label) { model.sort(list, by: s) }
                }
                Divider()
                Toggle("Group by assignee", isOn: Binding(
                    get: { model.groupByAssignee.contains(list.id) },
                    set: { if $0 { model.groupByAssignee.insert(list.id) } else { model.groupByAssignee.remove(list.id) } }))
            } label: { SwiftUI.Label("Sort by", systemImage: "arrow.up.arrow.down") }
            Divider()
            Button { copyName = list.name; copying = true } label: { SwiftUI.Label("Copy list", systemImage: "doc.on.doc") }
            Button { moving = true } label: { SwiftUI.Label("Move list", systemImage: "arrow.right.square") }
            Menu {
                ForEach(model.board?.lists.filter { $0.id != list.id } ?? []) { other in
                    Button(other.name) {
                        model.attempt { [api = model.api, id = list.id] in try await api.moveAllCards(id, toListId: other.id) }
                    }
                }
            } label: { SwiftUI.Label("Move all cards to", systemImage: "rectangle.portrait.and.arrow.right") }
            Divider()
            Button { confirm = .archiveAll } label: { SwiftUI.Label("Archive all cards", systemImage: "archivebox") }
            Button { model.archiveList(list.id) } label: { SwiftUI.Label("Archive list", systemImage: "archivebox.fill") }
            Button(role: .destructive) { confirm = .delete } label: { SwiftUI.Label("Delete list", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").padding(6).contentShape(Rectangle())
        }
        .accessibilityLabel("List actions")
    }

    private var addField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Card title", text: $newTitle, axis: .vertical)
                .focused($addFocused)
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .submitLabel(.done)
                .onSubmit(add)
            HStack {
                Button("Add card", action: add).prominentGlassButton()
                Button("Cancel") { adding = false; newTitle = "" }
            }
        }
    }

    private func add() {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { adding = false; return }
        model.addCard(listId: list.id, title: t, top: addTop)
        newTitle = ""
        addFocused = true
    }

    /// Drop a card before `before` (nil = end of list), or a list before this one.
    private func drop(_ items: [String], before: String?) -> Bool {
        guard model.canWrite, let item = items.first else { return false }
        if item.hasPrefix("hbcard:") {
            let id = String(item.dropFirst(7))
            let others = list.cards.filter { $0.id != id }
            let after: String?
            if let before, let i = others.firstIndex(where: { $0.id == before }) {
                after = i == 0 ? nil : others[i - 1].id
            } else {
                after = others.last?.id
            }
            model.moveCard(id, to: list.id, after: after)
            return true
        }
        if item.hasPrefix("hblist:") {
            let id = String(item.dropFirst(7))
            guard id != list.id, let lists = model.board?.lists.filter({ $0.id != id }), let i = lists.firstIndex(where: { $0.id == list.id }) else { return false }
            model.moveList(id, after: i == 0 ? nil : lists[i - 1].id)
            return true
        }
        return false
    }
}
