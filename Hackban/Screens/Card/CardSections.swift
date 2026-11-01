import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: Checklists

struct ChecklistSection: View {
    @Bindable var model: CardDetailModel
    let checklist: Checklist
    @State private var newItem = ""
    @State private var renaming = false
    @State private var renameText = ""
    @State private var editingItem: CheckItem?
    @State private var itemText = ""
    @State private var dueItem: CheckItem?
    @State private var hideDone = false
    @State private var confirmDelete = false
    @FocusState private var adding: Bool

    var body: some View {
        let done = checklist.items.filter(\.complete).count
        let total = checklist.items.count
        Section {
            if total > 0 {
                HStack {
                    Text("\(total == 0 ? 0 : done * 100 / total)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    ProgressView(value: Double(done), total: Double(max(total, 1))).tint(done == total ? .green : .accentColor)
                }
            }
            ForEach(checklist.items.filter { !hideDone || !$0.complete }) { item in row(item) }
                .onMove { from, to in move(from: from, to: to) }
            if model.canWrite {
                TextField("Add an item", text: $newItem)
                    .focused($adding)
                    .submitLabel(.next)
                    .onSubmit(addItem)
            }
        } header: {
            HStack {
                Text(checklist.name)
                Spacer()
                Menu {
                    Button(hideDone ? "Show checked items" : "Hide checked items") { hideDone.toggle() }
                    if model.canWrite {
                        Button("Rename") { renameText = checklist.name; renaming = true }
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .textCase(nil)
            }
        }
        .alert("Rename checklist", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") { let n = renameText; model.mutate { [id = checklist.id] api in try await api.renameChecklist(id, name: n) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit item", isPresented: Binding(get: { editingItem != nil }, set: { if !$0 { editingItem = nil } })) {
            TextField("Item", text: $itemText)
            Button("Save") {
                if let item = editingItem, !itemText.isEmpty {
                    let n = itemText
                    model.mutate { api in try await api.updateCheckItem(item.id, ["name": .string(n)]) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(checklist.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete checklist", role: .destructive) { model.mutate { [id = checklist.id] api in try await api.deleteChecklist(id) } }
        }
        .sheet(item: $dueItem) { item in CheckItemDueSheet(model: model, item: item) }
    }

    private func row(_ item: CheckItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                let next = !item.complete
                model.mutate({ c in
                    for l in c.checklists.indices {
                        if let i = c.checklists[l].items.firstIndex(where: { $0.id == item.id }) { c.checklists[l].items[i].complete = next }
                    }
                }) { api in try await api.updateCheckItem(item.id, ["complete": .bool(next)]) }
            } label: {
                Image(systemName: item.complete ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(item.complete ? Color.green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!model.canWrite)
            .accessibilityLabel(item.complete ? "Uncheck \(item.name)" : "Check \(item.name)")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).strikethrough(item.complete, color: .secondary).foregroundStyle(item.complete ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let due = item.due { DueBadge(due: due, complete: item.complete, recurrence: nil) }
                    if let m = item.member { AvatarView(m, account: model.account, size: 18) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if model.canWrite { itemText = item.name; editingItem = item } }
            if model.canWrite {
                Menu {
                    Button { dueItem = item } label: { SwiftUI.Label("Due date", systemImage: "calendar") }
                    Menu {
                        Button("Nobody") { model.mutate { api in try await api.updateCheckItem(item.id, ["memberId": .null]) } }
                        ForEach(model.board?.members ?? []) { m in
                            Button(m.user.displayName) { model.mutate { api in try await api.updateCheckItem(item.id, ["memberId": .string(m.userId)]) } }
                        }
                    } label: { SwiftUI.Label("Assign", systemImage: "person") }
                    Button(role: .destructive) { model.mutate { api in try await api.deleteCheckItem(item.id) } } label: { SwiftUI.Label("Delete", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(.vertical, 4) }
            }
        }
        .swipeActions {
            if model.canWrite { Button("Delete", role: .destructive) { model.mutate { api in try await api.deleteCheckItem(item.id) } } }
        }
    }

    private func addItem() {
        let n = newItem.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        newItem = ""
        adding = true
        model.mutate { [id = checklist.id] api in try await api.addCheckItem(checklist: id, name: n) }
    }

    private func move(from: IndexSet, to: Int) {
        guard model.canWrite, let fromIndex = from.first else { return }
        var items = checklist.items
        let item = items[fromIndex]
        items.move(fromOffsets: from, toOffset: to)
        guard let newIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        let after = newIndex == 0 ? nil : items[newIndex - 1].id
        model.mutate({ c in
            if let l = c.checklists.firstIndex(where: { $0.id == checklist.id }) { c.checklists[l].items = items }
        }) { [id = checklist.id] api in try await api.moveCheckItem(item.id, checklist: id, afterId: after) }
    }
}

struct CheckItemDueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: CardDetailModel
    let item: CheckItem
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Due", selection: $date).datePickerStyle(.graphical)
                if item.due != nil {
                    Button("Remove due date", role: .destructive) {
                        model.mutate { api in try await api.updateCheckItem(item.id, ["due": .null]) }
                        dismiss()
                    }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let d = date
                        model.mutate { api in try await api.updateCheckItem(item.id, ["due": .date(d)]) }
                        dismiss()
                    }
                }
            }
            .onAppear { date = item.due ?? Date().addingTimeInterval(86_400) }
        }
        .presentationDetents([.large])
    }
}

// MARK: Attachments

struct AttachmentsSection: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CardDetailModel
    let card: CardDetail
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var addingLink = false
    @State private var linkURL = ""
    @State private var linkName = ""
    @State private var renaming: Attachment?
    @State private var renameText = ""
    @State private var preview: URL?
    @State private var uploading = false

    var body: some View {
        Section {
            ForEach(card.attachments) { a in row(a) }
            if uploading { HStack { ProgressView(); Text("Uploading…").foregroundStyle(.secondary) } }
            if model.canWrite {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                        SwiftUI.Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { importing = true } label: { SwiftUI.Label("Files", systemImage: "folder") }
                    Button { linkURL = UIPasteboard.general.hasURLs ? (UIPasteboard.general.url?.absoluteString ?? "") : ""; linkName = ""; addingLink = true } label: {
                        SwiftUI.Label("Link", systemImage: "link")
                    }
                } label: {
                    SwiftUI.Label("Attach", systemImage: "paperclip")
                }
            }
        } header: {
            Text("Attachments")
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            uploadPhotos(items)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            uploadFiles(urls)
        }
        .alert("Attach a link", isPresented: $addingLink) {
            TextField("https://…", text: $linkURL).keyboardType(.URL).textInputAutocapitalization(.never)
            TextField("Display text (optional)", text: $linkName)
            Button("Attach") {
                let u = linkURL.trimmingCharacters(in: .whitespaces), n = linkName
                model.mutate { [id = card.id] api in try await api.addLink(card: id, url: u, name: n) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename attachment", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let a = renaming, !renameText.isEmpty { let n = renameText; model.mutate { api in try await api.renameAttachment(a.id, name: n) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .quickLookPreview($preview)
    }

    private func row(_ a: Attachment) -> some View {
        HStack(spacing: 12) {
            Group {
                if a.isImage {
                    AuthImage(a.url, account: model.account) { Color(.tertiarySystemFill) }
                } else {
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: a.isUpload == true ? "doc" : "link").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 56, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).lineLimit(2)
                Text([a.createdAt.map { Fmt.relative($0) }, Fmt.bytes(a.size), card.coverAttachmentId == a.id ? "Cover" : nil]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { open(a) }
        .contextMenu {
            Button { open(a) } label: { SwiftUI.Label("Open", systemImage: "eye") }
            if model.canWrite {
                Button { renameText = a.name; renaming = a } label: { SwiftUI.Label("Rename", systemImage: "pencil") }
                if a.isImage {
                    if card.coverAttachmentId == a.id {
                        Button { model.update(["coverAttachmentId": .null]) { $0.coverAttachmentId = nil } } label: { SwiftUI.Label("Remove cover", systemImage: "rectangle.slash") }
                    } else {
                        Button { model.update(["coverAttachmentId": .string(a.id)]) { $0.coverAttachmentId = a.id; $0.coverColor = nil } } label: { SwiftUI.Label("Make cover", systemImage: "rectangle.tophalf.filled") }
                    }
                }
                Button(role: .destructive) { model.mutate { api in try await api.deleteAttachment(a.id) } } label: { SwiftUI.Label("Delete", systemImage: "trash") }
            }
        }
        .swipeActions {
            if model.canWrite { Button("Delete", role: .destructive) { model.mutate { api in try await api.deleteAttachment(a.id) } } }
        }
    }

    private func open(_ a: Attachment) {
        if a.isUpload != true, let url = URL(string: a.url), url.scheme?.hasPrefix("http") == true {
            UIApplication.shared.open(url)
            return
        }
        attempt(app) {
            let data = try await model.api.data(a.url)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(a.id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(a.name.replacingOccurrences(of: "/", with: "-"))
            try data.write(to: file)
            preview = file
        }
    }

    private func uploadPhotos(_ items: [PhotosPickerItem]) {
        uploading = true
        attempt(app) {
            defer { uploading = false }
            var files: [HackbanAPI.UploadFile] = []
            for (i, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first ?? .jpeg
                let ext = type.preferredFilenameExtension ?? "jpg"
                files.append(.init(name: "Photo \(i + 1).\(ext)", mimeType: type.preferredMIMEType ?? "application/octet-stream", data: data))
            }
            if !files.isEmpty { try await model.api.uploadAttachments(card: card.id, files: files) }
            await model.load()
        }
    }

    private func uploadFiles(_ urls: [URL]) {
        uploading = true
        attempt(app) {
            defer { uploading = false }
            var files: [HackbanAPI.UploadFile] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension)
                files.append(.init(name: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream", data: data))
            }
            if !files.isEmpty { try await model.api.uploadAttachments(card: card.id, files: files) }
            await model.load()
        }
    }
}

// MARK: Comments

struct CommentsSection: View {
    @Bindable var model: CardDetailModel
    let card: CardDetail
    @State private var text = ""
    @State private var editing: Comment?
    @State private var editText = ""
    @FocusState private var focused: Bool

    var body: some View {
        Section("Comments") {
            if model.canWrite {
                HStack(alignment: .bottom) {
                    TextField("Write a comment…", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                    Button {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !t.isEmpty else { return }
                        text = ""
                        focused = false
                        model.mutate { [id = card.id] api in try await api.addComment(card: id, text: t) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send comment")
                }
            }
            ForEach(card.comments) { c in
                HStack(alignment: .top, spacing: 10) {
                    AvatarView(c.author, account: model.account, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(c.author.displayName).font(.subheadline.bold())
                            Text(Fmt.relative(c.createdAt) + (c.editedAt != nil ? " (edited)" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                        MarkdownText(text: c.text).font(.subheadline)
                    }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = c.text } label: { SwiftUI.Label("Copy", systemImage: "doc.on.doc") }
                    if c.authorId == model.account.userId {
                        Button { editText = c.text; editing = c } label: { SwiftUI.Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { model.mutate { api in try await api.deleteComment(c.id) } } label: { SwiftUI.Label("Delete", systemImage: "trash") }
                    }
                }
                .swipeActions {
                    if c.authorId == model.account.userId {
                        Button("Delete", role: .destructive) { model.mutate { api in try await api.deleteComment(c.id) } }
                    }
                }
            }
        }
        .alert("Edit comment", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Comment", text: $editText, axis: .vertical)
            Button("Save") {
                if let c = editing, !editText.isEmpty { let t = editText; model.mutate { api in try await api.editComment(c.id, text: t) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
