import SwiftUI

/// Карточка жалобы: что случилось, на что жалуются, кто пожаловался,
/// резолюция модератора и решение («В работу» / «Отклонить» / «Решить»).
///
/// expected_status — статус, который модератор ВИДЕЛ: если жалобу за это время
/// обработал кто-то другой, сервер ответит 409, и карточка перезагрузится.
struct ComplaintsDetailView: View {
    let id: Int
    let model: PagedListModel?

    @StateObject private var loader: ObjectLoader
    @State private var resolution = ""
    @State private var resolutionEdited = false
    @State private var askRejectReview = false
    @State private var replyConfirm: ConfirmAction?

    init(id: Int, model: PagedListModel? = nil) {
        self.id = id
        self.model = model
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/complaints/\(id)"))
    }

    private var c: JSON { loader.data }
    private var status: String { c["status"].stringValue }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            content
        }
        .navigationTitle("Жалоба #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
        .onReceive(loader.$data) { d in
            if !resolutionEdited { resolution = d["resolution"].stringValue }
        }
        .sheet(isPresented: $askRejectReview) { rejectReviewSheet }
        .confirmAction($replyConfirm) { try await deleteReply() }
    }

    private var content: some View {
        List {
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            mainSection
            ComplaintsTargetSection(target: c["target"],
                                    onRejectReview: { askRejectReview = true },
                                    onDeleteReply: { askDeleteReply() })
            authorSection
            resolutionSection
            actionsSection
            Section { JSONInspectorView(c) }
        }
        .refreshable { await loader.load() }
    }

    private var mainSection: some View {
        Section {
            HStack {
                Text(Fmt.date(c["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                Spacer()
                StatusBadge(ComplaintsFormat.statusLabel(status), color: ComplaintsFormat.statusColor(status))
            }
            Text(c["reason"].nonEmptyString ?? "Жалоба")
                .font(.headline)
            if let t = c["text"].nonEmptyString {
                Text(t)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }

    private var authorSection: some View {
        Section("Автор") {
            authorNameRow
            if let phone = c["author_phone"].nonEmptyString {
                phoneRow(phone)
            }
            if let email = c["author_email"].nonEmptyString {
                KVRow("Почта", email, copyable: true)
            }
        }
    }

    @ViewBuilder
    private var authorNameRow: some View {
        let name = c["author"].nonEmptyString ?? "—"
        if let uid = c["author_id"].int, uid > 0 {
            NavigationLink(destination: UserDetailView(id: uid)) {
                KVRow("Имя", name)
            }
        } else {
            KVRow("Имя", name)
        }
    }

    @ViewBuilder
    private func phoneRow(_ phone: String) -> some View {
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) {
                KVRow("Телефон", Fmt.phone(phone))
            }
        } else {
            KVRow("Телефон", Fmt.phone(phone), copyable: true)
        }
    }

    private var resolutionSection: some View {
        Section {
            TextField("Что сделано по жалобе…", text: resolutionBinding, axis: .vertical)
                .lineLimit(3...10)
            if let mod = c["moderator"].nonEmptyString {
                let when = c["resolved_at"].nonEmptyString.map { " · " + Fmt.date($0) } ?? ""
                Text("Обработал: " + mod + when)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        } header: {
            Text("Резолюция модератора")
        } footer: {
            Text("Резолюция сохраняется вместе с выбранным решением.")
        }
    }

    private var resolutionBinding: Binding<String> {
        Binding(get: { resolution }, set: { resolution = $0; resolutionEdited = true })
    }

    private var actionsSection: some View {
        Section {
            if status != "reviewing" {
                ActionButton("В работу", systemImage: "hourglass", style: .bordered,
                             successMessage: "Жалоба взята в работу", fullWidth: true) {
                    try await setStatus("reviewing")
                }
            }
            ActionButton("Решить", systemImage: "checkmark.seal", style: .prominent,
                         successMessage: "Жалоба решена", fullWidth: true) {
                try await setStatus("resolved")
            }
            ActionButton("Отклонить", systemImage: "xmark", role: .destructive, style: .bordered,
                         confirm: ConfirmAction(title: "Отклонить жалобу?",
                                                message: "Жалоба будет закрыта без мер.",
                                                confirmLabel: "Отклонить", destructive: true),
                         successMessage: "Жалоба отклонена", fullWidth: true) {
                try await setStatus("rejected")
            }
        }
    }

    // MARK: - Действия

    private func setStatus(_ newStatus: String) async throws {
        let seen = status
        let body: [String: Any?] = ["status": newStatus, "resolution": resolution, "expected_status": seen]
        do {
            try await API.shared.post("/api/admin/complaints/\(id)/status", body: body)
        } catch {
            // 409 — жалобу уже обработал другой модератор: показываем свежую.
            if let e = error as? APIError, e.status == 409 {
                resolutionEdited = false
                await loader.load()
            }
            throw error
        }
        resolutionEdited = false
        await loader.load()
        let cid = id
        model?.update(id: cid) { row in
            row = ComplaintsFormat.withStatus(row, newStatus)
        }
        Task { await Notifier.shared.refresh(force: true) }
    }

    private var rejectReviewSheet: some View {
        let rid = c["target"]["id"].intValue
        return ModerationReasonSheet(title: "Отклонить отзыв #" + String(rid),
                                     message: "Отзыв снимется с публикации, рейтинг магазина пересчитается.",
                                     reasons: ReviewsFormat.rejectReasons,
                                     submitTitle: "Отклонить отзыв") { note in
            try await ReviewsFormat.moderate(id: rid, approve: false, note: note, expected: nil)
            Task { await Notifier.shared.refresh(force: true) }
        }
    }

    private func askDeleteReply() {
        replyConfirm = ConfirmAction(title: "Снять ответ продавца?",
                                     message: "Ответ удалится с публичной страницы. Это необратимо.",
                                     confirmLabel: "Снять", destructive: true)
    }

    private func deleteReply() async throws {
        let rid = c["target"]["id"].intValue
        guard rid > 0 else { return }
        try await API.shared.delete("/api/admin/review-replies/\(rid)")
        await loader.load()
    }
}

/// «Объект жалобы»: подпись, подробности, переход или действие по типу.
struct ComplaintsTargetSection: View {
    let target: JSON
    let onRejectReview: () -> Void
    let onDeleteReply: () -> Void

    private var type: String { target["type"].stringValue }
    private var tid: Int { target["id"].intValue }

    var body: some View {
        if target.isObject && !type.isEmpty {
            Section("Объект жалобы") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ComplaintsFormat.targetType(type))
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                    Text(target["label"].nonEmptyString ?? "—")
                        .font(.subheadline.weight(.semibold))
                    if let d = target["detail"].nonEmptyString {
                        Text(d)
                            .font(.subheadline)
                            .foregroundColor(Brand.muted)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if tid > 0 {
            switch type {
            case "order":
                NavigationLink("Открыть заказ", destination: OrderDetailView(id: tid))
            case "shop":
                NavigationLink("Открыть магазин", destination: ShopDetailView(id: tid))
            case "user":
                NavigationLink("Открыть пользователя", destination: UserDetailView(id: tid))
            case "product":
                NavigationLink("Найти товар (скрыть с витрины)", destination: ProductsRootView(openId: tid))
            case "review":
                Button(role: .destructive, action: onRejectReview) {
                    Label("Отклонить отзыв", systemImage: "xmark")
                }
            case "review_reply":
                Button(role: .destructive, action: onDeleteReply) {
                    Label("Снять ответ продавца", systemImage: "trash")
                }
            default:
                EmptyView()
            }
        }
    }
}
