import SwiftUI
import UniformTypeIdentifiers

// MARK: Filters

struct FiltersSheet: View {
    @Bindable var model: BoardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Keyword") {
                    TextField("Card title contains…", text: $model.filters.q)
                }
                Section("Members") {
                    Button {
                        model.filters.members = [model.account.userId]
                    } label: { SwiftUI.Label("Only my cards", systemImage: "person.crop.circle") }
                    toggle("No members", isOn: model.filters.members.contains("none")) { toggleSet(&model.filters.members, "none") }
                    ForEach(model.board?.members ?? []) { m in
                        toggleRow(isOn: model.filters.members.contains(m.userId)) { toggleSet(&model.filters.members, m.userId) } label: {
                            HStack { AvatarView(m.user, account: model.account, size: 24); Text(m.user.displayName) }
                        }
                    }
                }
                Section("Due date") {
                    ForEach(CardFilters.Due.allCases) { d in
                        toggle(d.label, isOn: model.filters.due.contains(d)) {
                            if model.filters.due.contains(d) { model.filters.due.remove(d) } else { model.filters.due.insert(d) }
                        }
                    }
                }
                Section("Labels") {
                    toggle("No labels", isOn: model.filters.labels.contains("none")) { toggleSet(&model.filters.labels, "none") }
                    ForEach(model.board?.labels ?? []) { l in
                        toggleRow(isOn: model.filters.labels.contains(l.id)) { toggleSet(&model.filters.labels, l.id) } label: {
                            LabelChip(label: l).frame(maxWidth: 200, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Clear") { model.filters = CardFilters() }.disabled(!model.filters.isActive) }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleSet(_ set: inout Set<String>, _ v: String) {
        if set.contains(v) { set.remove(v) } else { set.insert(v) }
    }

    private func toggle(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        toggleRow(isOn: isOn, action: action) { Text(title) }
    }

    private func toggleRow<L: View>(isOn: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack {
                label()
                Spacer()
                if isOn { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Board menu

struct BoardMenuSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: BoardModel
    @State private var name = ""
    @State private var description = ""
    @State private var confirmClose = false
    @State private var confirmDelete = false
    @State private var confirmLeave = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            if let board = model.board {
                Form {
                    Section("About") {
                        TextField("Board name", text: $name)
                            .onSubmit { if !name.isEmpty && name != board.name { save { try await $0.updateBoard(board.id, name: name) } } }
                            .disabled(!model.canWrite)
                        TextField("Description (Markdown)", text: $description, axis: .vertical)
                            .lineLimit(3...10)
                            .disabled(!model.canWrite)
                        if model.canWrite && (name != board.name || description != (board.description ?? "")) {
                            Button("Save") {
                                save { api in
                                    try await api.updateBoard(board.id, name: name.isEmpty ? nil : name, description: description)
                                }
                            }
                        }
                        if let ws = board.workspace { LabeledContent("Workspace", value: ws.name) }
                    }
                    if model.canWrite {
                        Section("Background") { BackgroundPicker(selected: board.background) { bg in save { try await $0.updateBoard(board.id, background: bg, bgImage: .null) } } }
                    }
                    Section {
                        NavigationLink { LabelsEditor(model: model) } label: { SwiftUI.Label("Labels", systemImage: "tag") }
                        NavigationLink { ArchivedView(model: model) } label: { SwiftUI.Label("Archived items", systemImage: "archivebox") }
                        NavigationLink { BoardActivityView(model: model) } label: { SwiftUI.Label("Activity", systemImage: "list.bullet.rectangle") }
                    }
                    if board.isAdmin {
                        Section("Visibility") {
                            Picker("Who can see this board", selection: Binding(get: { board.visibility }, set: { v in
                                save { try await $0.updateBoard(board.id, visibility: v) }
                            })) {
                                Text("Private (board members)").tag("private")
                                Text("Workspace").tag("workspace")
                                Text("Public (anyone signed in)").tag("public")
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                    Section {
                        NavigationLink { CopyBoardView(model: model) } label: { SwiftUI.Label("Copy board", systemImage: "doc.on.doc") }
                        if board.isAdmin {
                            NavigationLink { MoveBoardView(model: model) } label: { SwiftUI.Label("Move to another workspace", systemImage: "arrow.right.square") }
                        }
                        Button { export(board) } label: { SwiftUI.Label("Export as JSON", systemImage: "square.and.arrow.down") }
                        if let exportURL { ShareLink(item: exportURL) { SwiftUI.Label("Share export", systemImage: "square.and.arrow.up") } }
                    }
                    Section {
                        if board.members.contains(where: { $0.userId == model.account.userId }) {
                            Button("Leave board", role: .destructive) { confirmLeave = true }
                        }
                        if board.isAdmin {
                            Button(board.closed ? "Reopen board" : "Close board", role: board.closed ? nil : .destructive) {
                                if board.closed { save { try await $0.updateBoard(board.id, closed: false) } } else { confirmClose = true }
                            }
                            if board.closed { Button("Delete board", role: .destructive) { confirmDelete = true } }
                        }
                    }
                }
                .navigationTitle("Menu")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { name = board.name; description = board.description ?? "" }
                .confirmationDialog("Close \(board.name)? You can reopen it from Closed boards.", isPresented: $confirmClose, titleVisibility: .visible) {
                    Button("Close board", role: .destructive) { save { try await $0.updateBoard(board.id, closed: true) } }
                }
                .confirmationDialog("Delete \(board.name) for everyone? This can't be undone.", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete board", role: .destructive) {
                        attempt(app) {
                            try await model.api.deleteBoard(board.id)
                            dismiss()
                            app.homePath = NavigationPath()
                        }
                    }
                }
                .confirmationDialog("Leave \(board.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
                    Button("Leave", role: .destructive) {
                        attempt(app) {
                            try await model.api.removeBoardMember(board.id, userId: model.account.userId)
                            dismiss()
                            app.homePath = NavigationPath()
                        }
                    }
                }
            }
        }
    }

    private func save(_ work: @escaping (HackbanAPI) async throws -> Void) {
        model.attempt { [api = model.api] in try await work(api) }
    }

    private func export(_ board: Board) {
        attempt(app) {
            let data = try await model.api.exportBoard(board.id)
            let safe = board.name.replacingOccurrences(of: "/", with: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).json")
            try data.write(to: url)
            exportURL = url
        }
    }
}

struct BackgroundPicker: View {
    var selected: String
    var onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
            ForEach(Palette.boardGradients + Palette.boardColors, id: \.self) { bg in
                Button { onPick(bg) } label: {
                    BoardBackground.fill(bg)
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white, lineWidth: bg == selected ? 3 : 0))
                        .overlay { if bg == selected { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bg == selected ? "Selected background" : "Background")
            }
        }
        .padding(.vertical, 4)
    }
}

struct LabelsEditor: View {
    @Bindable var model: BoardModel
    @State private var editing: BoardLabel?
    @State private var creating = false

    var body: some View {
        List {
            ForEach(model.board?.labels ?? []) { l in
                Button { editing = l } label: {
                    HStack {
                        LabelChip(label: l).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.canWrite)
            }
        }
        .navigationTitle("Labels")
        .toolbar {
            if model.canWrite { Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New label") }
        }
        .sheet(item: $editing) { l in LabelEditSheet(model: model, label: l) }
        .sheet(isPresented: $creating) { LabelEditSheet(model: model, label: nil) }
    }
}

struct LabelEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: BoardModel
    let label: BoardLabel?
    @State private var name = ""
    @State private var color: String? = "green"

    var body: some View {
        NavigationStack {
            Form {
                Section { LabelChip(label: BoardLabel(id: "", name: name, color: color)).frame(maxWidth: .infinity) }
                Section("Name") { TextField("Name", text: $name) }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(Palette.labelColors, id: \.self) { c in
                            Button { color = c } label: {
                                RoundedRectangle(cornerRadius: 4).fill(Palette.label(c).background).frame(height: 30)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary, lineWidth: color == c ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Palette.name(c))
                        }
                    }
                    Button("No color") { color = nil }
                }
                if let label {
                    Section {
                        Button("Delete label", role: .destructive) {
                            model.attempt { [api = model.api] in try await api.deleteLabel(label.id) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(label == nil ? "New label" : "Edit label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let n = name, c = color
                        if let label {
                            model.attempt { [api = model.api] in try await api.updateLabel(label.id, name: n, color: c) }
                        } else if let boardId = model.board?.id {
                            model.attempt { [api = model.api] in _ = try await api.createLabel(boardId: boardId, name: n, color: c) }
                        }
                        dismiss()
                    }
                }
            }
            .onAppear { if let label { name = label.name; color = label.color } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ArchivedView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BoardModel
    @State private var items: ArchivedItems?
    @State private var showLists = false

    var body: some View {
        List {
            Picker("Show", selection: $showLists) {
                Text("Cards").tag(false)
                Text("Lists").tag(true)
            }
            .pickerStyle(.segmented)
            if let items {
                if showLists {
                    if items.lists.isEmpty { Text("No archived lists").foregroundStyle(.secondary) }
                    ForEach(items.lists) { l in
                        HStack {
                            Text(l.name)
                            Spacer()
                            if model.canWrite {
                                Button("Restore") { run { try await $0.updateList(l.id, closed: false) } }.glassButton()
                            }
                        }
                        .swipeActions {
                            if model.canWrite { Button("Delete", role: .destructive) { run { try await $0.deleteList(l.id) } } }
                        }
                    }
                } else {
                    if items.cards.isEmpty { Text("No archived cards").foregroundStyle(.secondary) }
                    ForEach(items.cards) { c in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(c.title)
                                if let l = c.list?.name { Text(l).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if model.canWrite {
                                Button("Restore") { run { try await $0.updateCard(c.id, ["closed": false]) } }.glassButton()
                            }
                        }
                        .swipeActions {
                            if model.canWrite { Button("Delete", role: .destructive) { run { try await $0.deleteCard(c.id) } } }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Archived")
        .task { await load() }
    }

    private func load() async {
        do { items = try await model.api.archived(model.boardId) } catch { app.report(error) }
    }

    private func run(_ work: @escaping (HackbanAPI) async throws -> Void) {
        attempt(app) {
            try await work(model.api)
            await load()
            await model.load()
        }
    }
}

struct ActivityRow: View {
    let activity: Activity
    let account: Account
    var onCard = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(activity.actor, account: account, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                (Text(activity.actor?.displayName ?? "Someone").bold() + Text(" ") + Text(ActivityText.describe(activity, onCard: onCard)))
                    .font(.subheadline)
                Text(Fmt.relative(activity.createdAt)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct BoardActivityView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BoardModel
    @State private var items: [Activity] = []
    @State private var next: String?
    @State private var loaded = false
    @State private var openCard: CardRoute?

    var body: some View {
        List {
            ForEach(items) { a in
                ActivityRow(activity: a, account: model.account)
                    .contentShape(Rectangle())
                    .onTapGesture { if let c = a.card { openCard = CardRoute(account: model.account.id, cardId: c.id) } }
            }
            if let next {
                ProgressView().frame(maxWidth: .infinity).task { await load(cursor: next) }
            }
        }
        .navigationTitle("Activity")
        .task { if !loaded { await load(cursor: nil) } }
        .sheet(item: $openCard) { CardDetailSheet(route: $0) }
    }

    private func load(cursor: String?) async {
        do {
            let page = try await model.api.boardActivity(model.boardId, cursor: cursor)
            items += page.items
            next = page.next
            loaded = true
        } catch { app.report(error); next = nil }
    }
}

struct CopyBoardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: BoardModel
    @State private var name = ""
    @State private var workspaces: [Workspace] = []
    @State private var workspaceId = ""
    @State private var keepCards = true

    var body: some View {
        Form {
            TextField("Title", text: $name)
            Picker("Workspace", selection: $workspaceId) {
                ForEach(workspaces) { Text($0.name).tag($0.id) }
            }
            Toggle("Keep cards", isOn: $keepCards)
            Button("Create copy") {
                attempt(app) {
                    let created = try await model.api.copyBoard(model.boardId, name: name, workspaceId: workspaceId, keepCards: keepCards)
                    app.openBoard(BoardRoute(account: model.account.id, boardId: created.id))
                }
            }
            .disabled(name.isEmpty || workspaceId.isEmpty)
        }
        .navigationTitle("Copy board")
        .task {
            name = "\(model.board?.name ?? "Board") (copy)"
            workspaces = (try? await model.api.workspaces()) ?? []
            workspaceId = model.board?.workspaceId ?? workspaces.first?.id ?? ""
        }
    }
}

struct MoveBoardView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: BoardModel
    @State private var workspaces: [Workspace] = []

    var body: some View {
        List(workspaces) { w in
            Button {
                model.attempt { [api = model.api, id = model.boardId] in try await api.moveBoard(id, workspaceId: w.id) }
                app.flash("Moved to \(w.name)")
            } label: {
                HStack {
                    Text(w.name)
                    Spacer()
                    if w.id == model.board?.workspaceId { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle("Move board")
        .task { workspaces = (try? await model.api.workspaces()) ?? [] }
    }
}

struct MoveListSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: BoardModel
    let list: BoardList
    @State private var boards: [BoardRef] = []
    @State private var boardId = ""
    @State private var targetLists: [BoardList] = []
    @State private var position = 0

    var body: some View {
        NavigationStack {
            Form {
                Picker("Board", selection: $boardId) {
                    ForEach(boards) { Text($0.name).tag($0.id) }
                }
                Picker("Position", selection: $position) {
                    ForEach(0...targetLists.filter { $0.id != list.id }.count, id: \.self) { Text("\($0 + 1)").tag($0) }
                }
            }
            .navigationTitle("Move list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        let others = targetLists.filter { $0.id != list.id }
                        let after = position == 0 ? nil : others[min(position, others.count) - 1].id
                        let toBoard = boardId == model.boardId ? nil : boardId
                        attempt(app) {
                            try await model.api.moveList(list.id, boardId: toBoard, afterId: after)
                            dismiss()
                        }
                    }
                    .disabled(boardId.isEmpty)
                }
            }
            .task {
                boards = (try? await BoardDirectory.fetch(model.account)) ?? BoardDirectory.cached(model.account.id)
                boardId = model.boardId
            }
            .task(id: boardId) {
                guard !boardId.isEmpty else { return }
                targetLists = boardId == model.boardId ? (model.board?.lists ?? []) : ((try? await model.api.board(boardId))?.lists ?? [])
                position = targetLists.firstIndex(where: { $0.id == list.id }) ?? targetLists.count
            }
        }
        .presentationDetents([.medium])
    }
}
