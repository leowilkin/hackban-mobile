import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// The card modal (board/card-modal.tsx) as a sheet.
struct CardDetailSheet: View {
    @Environment(AppModel.self) private var app
    let route: CardRoute
    @State private var model: CardDetailModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { CardDetailContent(model: model) } else { ProgressView() }
            }
        }
        .onAppear {
            guard model == nil, let account = app.account(route.account) else { return }
            let m = CardDetailModel(account: account, cardId: route.cardId)
            m.app = app
            model = m
        }
        .task(id: model == nil) { await model?.load() }
        .presentationDragIndicator(.visible)
    }
}

private struct CardDetailContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel

    @State private var title = ""
    @State private var editingDescription = false
    @State private var showDates = false
    @State private var showMembers = false
    @State private var showLabels = false
    @State private var showMove = false
    @State private var showCopy = false
    @State private var showBlocker = false
    @State private var newChecklist = false
    @State private var checklistName = "Checklist"
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let card = model.card {
            List {
                header(card)
                quickActions(card)
                if !card.members.isEmpty || !card.labels.isEmpty || card.due != nil || card.start != nil { detailsSection(card) }
                descriptionSection(card)
                if !card.blockedBy.isEmpty || !card.blocking.isEmpty { DependenciesSection(model: model, card: card) }
                ForEach(card.checklists) { cl in ChecklistSection(model: model, checklist: cl) }
                AttachmentsSection(model: model, card: card)
                CommentsSection(model: model, card: card)
                activitySection(card)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(card.list.board?.name ?? "Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(card) }
            .refreshable { await model.load() }
            .onAppear { title = card.title }
            .onChange(of: card.title) { _, t in if !titleFocused { title = t } }
            .sheet(isPresented: $showDates) { DatesSheet(model: model, card: card) }
            .sheet(isPresented: $showMembers) { MembersPicker(model: model, card: card) }
            .sheet(isPresented: $showLabels) { LabelPicker(model: model, card: card) }
            .sheet(isPresented: $showMove) { MoveCardSheet(model: model, card: card, copy: false) }
            .sheet(isPresented: $showCopy) { MoveCardSheet(model: model, card: card, copy: true) }
            .sheet(isPresented: $showBlocker) { BlockerPicker(model: model, card: card) }
            .sheet(isPresented: $editingDescription) { DescriptionEditor(model: model, text: card.description) }
            .alert("Add checklist", isPresented: $newChecklist) {
                TextField("Title", text: $checklistName)
                Button("Add") { let n = checklistName; model.mutate { [id = card.id] api in try await api.addChecklist(card: id, name: n) } }
                ForEach(card.checklists) { cl in
                    Button("Copy \u{201C}\(cl.name)\u{201D}") { let n = checklistName; model.mutate { [id = card.id] api in try await api.addChecklist(card: id, name: n, copyFrom: cl.id) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this card for everyone? This can't be undone.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete card", role: .destructive) {
                    attempt(app) { try await model.api.deleteCard(card.id); dismiss() }
                }
            }
        } else if let error = model.error {
            EmptyState(title: "Can't open this card", systemImage: "exclamationmark.triangle", message: error)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        } else {
            ProgressView()
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ card: CardDetail) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if model.canWrite {
                    Button { showMove = true } label: { SwiftUI.Label("Move", systemImage: "arrow.right.square") }
                    Button { showCopy = true } label: { SwiftUI.Label("Copy", systemImage: "doc.on.doc") }
                    Menu {
                        Button("Remove cover") { model.update(["coverColor": .null, "coverAttachmentId": .null]) { $0.coverColor = nil; $0.coverAttachmentId = nil } }
                        Picker("Size", selection: Binding(get: { card.coverSize ?? "normal" }, set: { s in model.update(["coverSize": .string(s)]) { $0.coverSize = s } })) {
                            Text("Normal").tag("normal")
                            Text("Full").tag("full")
                        }
                        ForEach(Palette.baseColors, id: \.self) { c in
                            Button(c.capitalized) { model.update(["coverColor": .string(c)]) { $0.coverColor = c; $0.coverAttachmentId = nil } }
                        }
                    } label: { SwiftUI.Label("Cover", systemImage: "rectangle.tophalf.filled") }
                    Button { checklistName = "Checklist"; newChecklist = true } label: { SwiftUI.Label("Add checklist", systemImage: "checklist") }
                    Button { showBlocker = true } label: { SwiftUI.Label("Dependencies", systemImage: "nosign") }
                    Divider()
                    if card.closed {
                        Button { model.update(["closed": .bool(false)]) { $0.closed = false } } label: { SwiftUI.Label("Send to board", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { confirmDelete = true } label: { SwiftUI.Label("Delete", systemImage: "trash") }
                    } else {
                        Button { model.update(["closed": .bool(true)]) { $0.closed = true } } label: { SwiftUI.Label("Archive", systemImage: "archivebox") }
                    }
                }
                if let url = model.account.webURL(card: card.id) {
                    ShareLink(item: url) { SwiftUI.Label("Share link", systemImage: "square.and.arrow.up") }
                    Link(destination: url) { SwiftUI.Label("Open in browser", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func header(_ card: CardDetail) -> some View {
        Section {
            if let attId = card.coverAttachmentId, let att = card.attachments.first(where: { $0.id == attId }) {
                AuthImage(att.url, account: model.account) { Color(.tertiarySystemFill) }
                    .frame(height: 160).frame(maxWidth: .infinity).clipped()
                    .listRowInsets(EdgeInsets())
            } else if let color = card.coverColor {
                Palette.solid(color).frame(height: 56).listRowInsets(EdgeInsets())
            }
            VStack(alignment: .leading, spacing: 6) {
                if card.closed {
                    SwiftUI.Label("This card is archived.", systemImage: "archivebox").font(.footnote).foregroundStyle(.orange)
                }
                TextField("Title", text: $title, axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .focused($titleFocused)
                    .disabled(!model.canWrite)
                    .submitLabel(.done)
                    .onChange(of: titleFocused) { _, focused in if !focused { saveTitle(card) } }
                    .onSubmit { titleFocused = false }
                Text("in list **\(card.list.name)**").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func saveTitle(_ card: CardDetail) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != card.title else { title = card.title; return }
        model.update(["title": .string(t)]) { $0.title = t }
    }

    private func quickActions(_ card: CardDetail) -> some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if model.canWrite {
                        let joined = card.members.contains { $0.userId == model.account.userId }
                        action(joined ? "Leave" : "Join", joined ? "person.badge.minus" : "person.badge.plus") {
                            let me = model.me
                            model.mutate({ c in
                                if joined { c.members.removeAll { $0.userId == me.id } } else { c.members.append(CardMemberLink(userId: me.id, user: me)) }
                            }) { [id = card.id] api in try await api.toggleMember(card: id, user: me.id, on: !joined) }
                        }
                        action("Members", "person.2") { showMembers = true }
                        action("Labels", "tag") { showLabels = true }
                        action("Dates", "calendar") { showDates = true }
                        action("Checklist", "checklist") { checklistName = "Checklist"; newChecklist = true }
                    }
                    action(card.watching ? "Watching" : "Watch", card.watching ? "eye.fill" : "eye") {
                        let next = !card.watching
                        model.mutate({ $0.watching = next }) { [id = card.id] api in try await api.watchCard(id, next) }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            SwiftUI.Label(title, systemImage: icon).font(.subheadline.weight(.medium))
        }
        .glassButton()
    }

    private func detailsSection(_ card: CardDetail) -> some View {
        Section {
            if !card.members.isEmpty {
                Button { showMembers = true } label: {
                    LabeledContent("Members") {
                        HStack(spacing: -6) {
                            ForEach(card.members, id: \.userId) { AvatarView($0.user, account: model.account, size: 26) }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.canWrite)
            }
            if !card.labels.isEmpty {
                Button { showLabels = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Labels").font(.footnote).foregroundStyle(.secondary)
                        FlowLayout(spacing: 4) { ForEach(card.labels, id: \.labelId) { LabelChip(label: $0.label) } }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!model.canWrite)
            }
            if card.due != nil || card.start != nil {
                HStack {
                    Button { showDates = true } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dates").font(.footnote).foregroundStyle(.secondary)
                            HStack {
                                if let start = card.start { Text("Starts \(Fmt.due(start))").font(.subheadline) }
                                if let due = card.due { DueBadge(due: due, complete: card.dueComplete, recurrence: card.recurrence) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if card.due != nil && model.canWrite {
                        Toggle("Complete", isOn: Binding(get: { card.dueComplete }, set: { v in
                            model.update(["dueComplete": .bool(v)]) { $0.dueComplete = v }
                        }))
                        .labelsHidden()
                        .accessibilityLabel("Complete")
                    }
                }
            }
        }
    }

    private func descriptionSection(_ card: CardDetail) -> some View {
        Section {
            if card.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Add a more detailed description…") { editingDescription = true }
                    .foregroundStyle(.secondary)
                    .disabled(!model.canWrite)
            } else {
                MarkdownText(text: card.description)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.canWrite { editingDescription = true } }
            }
        } header: {
            Text("Description")
        }
    }

    private func activitySection(_ card: CardDetail) -> some View {
        Section("Activity") {
            if card.activities.isEmpty { Text("No activity yet").foregroundStyle(.secondary) }
            ForEach(card.activities.prefix(20)) { a in ActivityRow(activity: a, account: model.account, onCard: true) }
        }
    }
}

// MARK: Description

struct DescriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel
    @State var text: String
    @State private var preview = false

    var body: some View {
        NavigationStack {
            VStack {
                Picker("Mode", selection: $preview) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                if preview {
                    ScrollView { MarkdownText(text: text).frame(maxWidth: .infinity, alignment: .leading).padding() }
                } else {
                    TextEditor(text: $text).padding(.horizontal, 12)
                }
            }
            .navigationTitle("Description")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = text
                        model.update(["description": .string(t)]) { $0.description = t }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: Dates

struct DatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel
    let card: CardDetail
    @State private var hasStart = false
    @State private var start = Date()
    @State private var hasDue = false
    @State private var due = Date()
    @State private var recurrence: Recurrence?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Start date", isOn: $hasStart)
                    if hasStart { DatePicker("Starts", selection: $start, displayedComponents: [.date]) }
                }
                Section {
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Due", selection: $due).datePickerStyle(.graphical)
                        Picker("Repeat", selection: $recurrence) {
                            Text("Never").tag(Recurrence?.none)
                            ForEach(Recurrence.allCases) { Text($0.label).tag(Optional($0)) }
                        }
                    }
                } footer: {
                    if recurrence != nil && hasDue { Text("Completing a repeating card moves it to its next date and resets its checklists.") }
                }
            }
            .navigationTitle("Dates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let s: Date? = hasStart ? Calendar.current.startOfDay(for: start) : nil
                        let d: Date? = hasDue ? due : nil
                        let r: Recurrence? = hasDue ? recurrence : nil
                        if hasDue { Shared.defaults.set(Calendar.current.dateComponents([.hour, .minute], from: due).hour, forKey: "lastDueHour") }
                        model.update(["start": .orNull(s), "due": .orNull(d), "recurrence": .orNull(r?.rawValue)]) {
                            $0.start = s; $0.due = d; $0.recurrence = r?.rawValue
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                hasStart = card.start != nil
                start = card.start ?? .now
                hasDue = card.due != nil
                // New due dates default to the hour picked last (like the web).
                let hour = Shared.defaults.object(forKey: "lastDueHour") as? Int ?? 17
                due = card.due ?? Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? .now
                recurrence = card.recurrence.flatMap(Recurrence.init(rawValue:))
            }
        }
    }
}

// MARK: Members & labels pickers

struct MembersPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel
    let card: CardDetail

    var body: some View {
        NavigationStack {
            List(model.board?.members ?? []) { m in
                let on = model.card?.members.contains { $0.userId == m.userId } ?? false
                Button {
                    model.mutate({ c in
                        if on { c.members.removeAll { $0.userId == m.userId } } else { c.members.append(CardMemberLink(userId: m.userId, user: m.user)) }
                    }) { [id = card.id] api in try await api.toggleMember(card: id, user: m.userId, on: !on) }
                } label: {
                    HStack {
                        AvatarView(m.user, account: model.account, size: 30)
                        Text(m.user.displayName)
                        Spacer()
                        if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct LabelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel
    let card: CardDetail
    @State private var creating = false
    @State private var newName = ""
    @State private var newColor = "blue"

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.board?.labels ?? []) { l in
                    let on = model.card?.labels.contains { $0.labelId == l.id } ?? false
                    Button {
                        model.mutate({ c in
                            if on { c.labels.removeAll { $0.labelId == l.id } } else { c.labels.append(CardLabelLink(labelId: l.id, label: l)) }
                        }) { [id = card.id] api in try await api.toggleLabel(card: id, label: l.id, on: !on) }
                    } label: {
                        HStack {
                            LabelChip(label: l).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section("New label") {
                    TextField("Name", text: $newName)
                    Picker("Color", selection: $newColor) {
                        ForEach(Palette.labelColors, id: \.self) { Text(Palette.name($0)).tag($0) }
                    }
                    Button("Create and add") {
                        let name = newName, color = newColor
                        guard let boardId = model.board?.id else { return }
                        newName = ""
                        model.mutate { [id = card.id] api in
                            let created = try await api.createLabel(boardId: boardId, name: name, color: color)
                            try await api.toggleLabel(card: id, label: created.id, on: true)
                        }
                        Task { try? await Task.sleep(for: .milliseconds(600)); await model.reloadBoard() }
                    }
                }
            }
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: Move / copy

struct MoveCardSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel
    let card: CardDetail
    let copy: Bool

    @State private var boards: [BoardRef] = []
    @State private var boardId = ""
    @State private var lists: [BoardList] = []
    @State private var listId = ""
    @State private var position = 0
    @State private var title = ""
    @State private var keepChecklists = true
    @State private var keepLabels = true
    @State private var keepMembers = true
    @State private var keepAttachments = true

    var body: some View {
        NavigationStack {
            Form {
                if copy {
                    Section("Title") { TextField("Title", text: $title) }
                    Section("Keep") {
                        Toggle("Checklists", isOn: $keepChecklists)
                        Toggle("Labels", isOn: $keepLabels)
                        Toggle("Members", isOn: $keepMembers)
                        Toggle("Attachments", isOn: $keepAttachments)
                    }
                }
                Section("Destination") {
                    Picker("Board", selection: $boardId) { ForEach(boards) { Text($0.name).tag($0.id) } }
                    Picker("List", selection: $listId) { ForEach(lists) { Text($0.name).tag($0.id) } }
                    if !copy {
                        Picker("Position", selection: $position) {
                            ForEach(0...max(targetCards.count, 0), id: \.self) { Text("\($0 + 1)").tag($0) }
                        }
                    }
                }
            }
            .navigationTitle(copy ? "Copy card" : "Move card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copy ? "Copy" : "Move", action: go).disabled(listId.isEmpty || (copy && title.isEmpty))
                }
            }
            .task {
                title = card.title
                boards = (try? await BoardDirectory.fetch(model.account)) ?? BoardDirectory.cached(model.account.id)
                boardId = card.list.boardId
            }
            .task(id: boardId) {
                guard !boardId.isEmpty else { return }
                lists = boardId == model.board?.id ? (model.board?.lists ?? []) : ((try? await model.api.board(boardId))?.lists ?? [])
                listId = lists.contains(where: { $0.id == card.listId }) ? card.listId : (lists.first?.id ?? "")
            }
            .onChange(of: listId) { _, _ in
                position = targetCards.firstIndex(where: { $0.id == card.id }) ?? targetCards.count
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var targetCards: [BoardCard] {
        (lists.first { $0.id == listId }?.cards ?? []).filter { $0.id != card.id }
    }

    private func go() {
        let cards = targetCards
        let after = position == 0 ? nil : cards[min(position, cards.count) - 1].id
        attempt(app) {
            if copy {
                _ = try await model.api.copyCard(card.id, title: title, listId: listId, keepChecklists: keepChecklists, keepLabels: keepLabels, keepMembers: keepMembers, keepAttachments: keepAttachments)
                app.flash("Copied")
            } else {
                try await model.api.moveCard(card.id, listId: listId, afterId: after)
                await model.load()
                await model.reloadBoard()
            }
            dismiss()
        }
    }
}

// MARK: Dependencies

struct DependenciesSection: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CardDetailModel
    let card: CardDetail

    var body: some View {
        Section("Dependencies") {
            ForEach(card.blockedBy) { d in
                HStack {
                    Image(systemName: "nosign").foregroundStyle(.red)
                    VStack(alignment: .leading) {
                        Text("Blocked by").font(.caption).foregroundStyle(.secondary)
                        Text(d.title).strikethrough(d.dueComplete)
                    }
                    Spacer()
                    if !d.dueComplete && model.canWrite {
                        Button("Complete") { model.mutate { api in try await api.updateCard(d.id, ["dueComplete": true]) } }
                            .glassButton().font(.caption)
                    }
                }
                .swipeActions {
                    if model.canWrite {
                        Button("Remove", role: .destructive) { model.mutate { [id = card.id] api in try await api.setBlocker(card: id, blocker: d.id, on: false) } }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { app.presentedCard = nil; open(d.id) }
            }
            ForEach(card.blocking) { d in
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                    VStack(alignment: .leading) {
                        Text("Blocking").font(.caption).foregroundStyle(.secondary)
                        Text(d.title)
                    }
                }
            }
        }
    }

    private func open(_ id: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            app.presentedCard = CardRoute(account: model.account.id, cardId: id)
        }
    }
}

struct BlockerPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel
    let card: CardDetail
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { c in
                        let on = card.blockedBy.contains { $0.id == c.id }
                        Button {
                            model.mutate { [id = card.id] api in try await api.setBlocker(card: id, blocker: c.id, on: !on) }
                        } label: {
                            HStack {
                                Text(c.title)
                                Spacer()
                                if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("This card shows as Blocked until every blocking card is complete or archived.")
                }
            }
            .searchable(text: $query)
            .navigationTitle("Blocked by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var candidates: [BoardCard] {
        let blocking = Set(card.blocking.map(\.id))
        return model.boardCards.filter { c in
            c.id != card.id && !blocking.contains(c.id) && (query.isEmpty || c.title.localizedCaseInsensitiveContains(query))
        }
    }
}
