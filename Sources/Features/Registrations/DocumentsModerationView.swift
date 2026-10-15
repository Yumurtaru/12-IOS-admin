import SwiftUI

/// Лицензионные документы организаций: GET /api/admin/documents?status=…
/// (pending / approved / rejected, сервер отдаёт до 200 последних) и решение
/// PUT /api/admin/documents/{id} {action: approve|reject, note, expected_status}.
///
/// Документ включает/выключает видимость организации в лицензируемой категории
/// (аптека, стоматология…). expected_status — защита от двух модераторов:
/// если документ уже обработали, сервер ответит 409 «обновите список».
/// Причина отказа обязательна (до 190 символов) — она уходит владельцу.
struct DocumentsModerationView: View {
    @ObservedObject var model: PagedListModel
    @State private var rejectTarget: DocumentsRejectTarget?

    init(model: PagedListModel) {
        self.model = model
    }

    private var statusBinding: Binding<String> {
        Binding(get: { model.filter("status") ?? "pending" },
                set: { model.setFilter("status", $0) })
    }

    var body: some View {
        List {
            Picker("Статус", selection: statusBinding) {
                Text("На проверке").tag("pending")
                Text("Одобрены").tag("approved")
                Text("Отклонены").tag("rejected")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            stateContent
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .sheet(item: $rejectTarget) { target in
            DocumentsRejectSheet(target: target) { note in
                try await DocumentsModerationView.decide(id: target.id, action: "reject", note: note,
                                                         expected: target.status)
                model.remove(id: target.id)
                Task { await Notifier.shared.refresh(force: true) }
            }
        }
    }

    /// PUT /api/admin/documents/{id}.
    static func decide(id: Int, action: String, note: String?, expected: String) async throws {
        var payload: [String: Any?] = ["action": action, "expected_status": expected]
        if let n = note { payload["note"] = n }
        try await API.shared.put("/api/admin/documents/" + String(id), body: payload)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.reload() })
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .empty:
            EmptyStateView(title: emptyTitle, systemImage: "doc.text.magnifyingglass")
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(model.items, id: \.stableID) { doc in
                DocumentModerationSection(doc: doc, model: model) {
                    rejectTarget = DocumentsRejectTarget(id: doc.id ?? 0,
                                                         title: doc["title"].nonEmptyString ?? "Документ",
                                                         shopName: doc["shop_name"].stringValue,
                                                         status: doc["status"].stringValue)
                }
            }
            if model.items.count >= 200 {
                Text("Показаны 200 последних документов — больше сервер не отдаёт.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var emptyTitle: String {
        switch model.filter("status") ?? "pending" {
        case "approved": return "Одобренных документов нет"
        case "rejected": return "Отклонённых документов нет"
        default: return "Документов на проверке нет"
        }
    }
}

/// Документ, который отклоняем (для .sheet(item:)).
struct DocumentsRejectTarget: Identifiable {
    let id: Int
    let title: String
    let shopName: String
    let status: String
}

/// Один документ: организация, категория, файл, решение.
struct DocumentModerationSection: View {
    let doc: JSON
    @ObservedObject var model: PagedListModel
    let onReject: () -> Void

    init(doc: JSON, model: PagedListModel, onReject: @escaping () -> Void) {
        self.doc = doc
        self.model = model
        self.onReject = onReject
    }

    private var docId: Int { doc.id ?? 0 }
    private var status: String { doc["status"].stringValue }
    private var fileURL: URL? { API.absoluteURL(doc["file_path"].string) }
    private var isImage: Bool { doc["mime"].stringValue.hasPrefix("image/") }

    private var statusLabel: String {
        switch status {
        case "pending": return "На проверке"
        case "approved": return "Одобрен"
        case "rejected": return "Отклонён"
        default: return status
        }
    }

    var body: some View {
        Section {
            shopLink
            fileRow
            decisionRow
        }
    }

    @ViewBuilder
    private var shopLink: some View {
        let info = VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(doc["shop_name"].nonEmptyString ?? "Организация")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 6)
                StatusBadge(status: status, label: statusLabel)
            }
            Text(doc["category_name"].nonEmptyString ?? "Категория не указана")
                .font(.caption)
                .foregroundColor(Brand.muted)
            Text("Загружен " + Fmt.date(doc["created_at"].string))
                .font(.caption2)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
        if let sid = doc["organization_id"].int {
            NavigationLink(destination: ShopDetailView(id: sid)) { info }
        } else {
            info
        }
    }

    @ViewBuilder
    private var fileRow: some View {
        if let url = fileURL {
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 6) {
                    if isImage {
                        AsyncImageView(path: doc["file_path"].string, height: 160, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                    Label(doc["title"].nonEmptyString ?? "Открыть документ", systemImage: "doc.richtext")
                }
            }
        } else {
            KVRow("Документ", doc["title"].string)
        }
    }

    private var decisionRow: some View {
        HStack(spacing: 10) {
            if status != "approved" {
                ActionButton("Одобрить", systemImage: "checkmark", style: .prominent) {
                    try await DocumentsModerationView.decide(id: docId, action: "approve", note: nil, expected: status)
                    model.remove(id: docId)
                    Task { await Notifier.shared.refresh(force: true) }
                }
            }
            if status != "rejected" {
                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Отклонить", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Причина отказа по документу: шаблоны как на сайте + свой текст (он важнее шаблона).
struct DocumentsRejectSheet: View {
    let target: DocumentsRejectTarget
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preset: String = DocumentsRejectSheet.presets[0]
    @State private var custom = ""
    @State private var busy = false
    @State private var error: String?

    /// Шаблоны причин (admin.js LIC_REASONS).
    static let presets: [String] = [
        "Срок действия документа истёк",
        "Документ не читается",
        "Документ не соответствует виду деятельности",
        "Данные в документе не совпадают с реквизитами организации",
    ]

    init(target: DocumentsRejectTarget, onSubmit: @escaping (String) async throws -> Void) {
        self.target = target
        self.onSubmit = onSubmit
    }

    private var note: String {
        let c = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? preset : c
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(DocumentsRejectSheet.presets, id: \.self) { p in
                        Button {
                            preset = p
                            Haptics.tap()
                        } label: {
                            HStack {
                                Text(p).foregroundColor(Brand.text)
                                Spacer()
                                if p == preset && custom.trimmingCharacters(in: .whitespaces).isEmpty {
                                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                                }
                            }
                        }
                    }
                } header: {
                    Text("«" + target.title + "» · " + target.shopName)
                } footer: {
                    Text("Причина уйдёт владельцу, заведение скроется из своего раздела до загрузки нового документа.")
                }
                Section {
                    TextField("Свой комментарий (необязательно)", text: $custom, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    if note.count > 190 {
                        Text("Сервер сохранит первые 190 символов").foregroundColor(Brand.amber)
                    }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button(role: .destructive) {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Отклонить").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("Причина отказа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        error = nil
        let text = note
        let send = onSubmit
        Task { @MainActor in
            do {
                try await send(text)
                Haptics.success()
                busy = false
                dismiss()
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
        }
    }
}
