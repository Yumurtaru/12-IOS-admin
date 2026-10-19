import SwiftUI

/// Карточка отзыва: строка списка, дополненная GET /api/admin/reviews/{id} (П-29.4:
/// оценки по частям, заказ, ответы продавца). Старый сервер — только строка списка.
/// Действия: одобрить / отклонить с причиной. Решение уходит с expected_status —
/// если отзыв уже обработал другой модератор, сервер ответит 409 с объяснением.
struct ReviewsDetailView: View {
    let model: PagedListModel
    @State private var review: JSON
    @State private var askReject = false
    @State private var enrichTried = false

    init(review: JSON, model: PagedListModel) {
        self.model = model
        _review = State(initialValue: review)
    }

    private var id: Int { review.id ?? 0 }
    private var status: String { review["status"].stringValue }

    var body: some View {
        List {
            mainSection
            photosSection
            infoSection
            repliesSection
            actionsSection
            Section { JSONInspectorView(review) }
        }
        .navigationTitle("Отзыв #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $askReject) { rejectSheet }
        .task { await enrich() }
    }

    /// П-29.4: подробности карточки по id. Дописываем только недостающие поля —
    /// статус, который модератор уже поменял на этом экране, не перетираем.
    private func enrich() async {
        guard !enrichTried, id > 0, review.object["replies"] == nil else { return }
        enrichTried = true
        let rid = id
        guard let one = try? await API.shared.get("/api/admin/reviews/" + String(rid)), one.id == rid else { return }
        var o = review.object
        for (k, v) in one.object where o[k] == nil {
            o[k] = v
        }
        review = .object(o)
    }

    /// Оценки по частям «еда 5 · доставка 4 · сервис 5» (только те, что поставлены).
    private var partsText: String? {
        var parts: [String] = []
        let food = review["rating_food"].intValue
        let delivery = review["rating_delivery"].intValue
        let service = review["rating_service"].intValue
        if food > 0 { parts.append("еда " + String(food)) }
        if delivery > 0 { parts.append("доставка " + String(delivery)) }
        if service > 0 { parts.append("сервис " + String(service)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var repliesSection: some View {
        let replies = review["replies"].array
        if !replies.isEmpty {
            Section("Ответ продавца") {
                ForEach(Array(replies.enumerated()), id: \.offset) { pair in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pair.element["text"].nonEmptyString ?? "—")
                            .font(.subheadline)
                            .textSelection(.enabled)
                        Text(Fmt.date(pair.element["created_at"]))
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var mainSection: some View {
        Section {
            HStack {
                Text(ReviewsFormat.stars(review["rating_overall"].intValue))
                    .font(.title3)
                    .foregroundColor(Brand.amber)
                Spacer()
                StatusBadge(status: status, label: ReviewsFormat.statusLabel(status))
            }
            Text(review["text"].nonEmptyString ?? "Без текста")
                .font(.body)
                .foregroundColor(review["text"].nonEmptyString == nil ? Brand.muted : Brand.text)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var photosSection: some View {
        let photos = ReviewsFormat.photos(review)
        if !photos.isEmpty {
            Section("Фото (" + String(photos.count) + ")") {
                ReviewsPhotoStrip(paths: photos, size: 120)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
    }

    private var infoSection: some View {
        Section("Сведения") {
            shopRow
            KVRow("Автор", review["author"].string)
            KVRow("Дата", Fmt.date(review["created_at"]))
            // Поля карточки по id (П-29.4) — у строки списка их нет.
            if let parts = partsText {
                KVRow("Оценки", parts)
            }
            if let v = review.object["is_verified"] {
                KVRow("Покупка подтверждена", Fmt.yesNo(v.bool))
            }
            if let oid = review["order_id"].int, oid > 0 {
                NavigationLink(destination: OrderDetailView(id: oid)) {
                    KVRow("Заказ", "#" + String(oid))
                }
            }
        }
    }

    @ViewBuilder
    private var shopRow: some View {
        if let shopId = review["shop_id"].int, shopId > 0 {
            NavigationLink(destination: ShopDetailView(id: shopId)) {
                KVRow("Магазин", review["shop"].nonEmptyString ?? ("#" + String(shopId)))
            }
        } else {
            KVRow("Магазин", review["shop"].string)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if status != "approved" {
                ActionButton(status == "pending" ? "Одобрить" : "Опубликовать", systemImage: "checkmark",
                             style: .prominent,
                             confirm: ConfirmAction(title: "Опубликовать отзыв?", confirmLabel: "Опубликовать"),
                             successMessage: "Отзыв опубликован", fullWidth: true) {
                    try await decide(approve: true, note: "")
                }
                .tint(Brand.green)
            }
            if status != "rejected" {
                Button(role: .destructive) {
                    askReject = true
                } label: {
                    Label(status == "pending" ? "Отклонить" : "Снять с публикации", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } footer: {
            Text("Рейтинг магазина пересчитается сразу после решения.")
        }
    }

    private var rejectSheet: some View {
        ModerationReasonSheet(title: "Причина отклонения отзыва", reasons: ReviewsFormat.rejectReasons,
                              submitTitle: "Отклонить") { note in
            try await decide(approve: false, note: note)
        }
    }

    private func decide(approve: Bool, note: String) async throws {
        let rid = id
        try await ReviewsFormat.moderate(id: rid, approve: approve, note: note, expected: status)
        let newStatus = approve ? "approved" : "rejected"
        review = ReviewsFormat.withStatus(review, newStatus)
        // Строку в списке не убираем, а помечаем новым статусом: удаление
        // исходной строки NavigationLink выкинуло бы с этого экрана.
        model.update(id: rid) { row in
            row = ReviewsFormat.withStatus(row, newStatus)
        }
        Task { await Notifier.shared.refresh(force: true) }
    }
}

/// Ответы продавцов на отзывы: публикуются без модерации, здесь их можно снять.
struct ReviewsRepliesScreen: View {
    @ObservedObject var model: PagedListModel
    @State private var pending: ConfirmAction?
    @State private var deleteId: Int?

    var body: some View {
        AdminListScreen("Ответы продавцов", model: model, searchPrompt: "Текст ответа",
                        emptyText: "Ответов нет",
                        row: { item in row(item) })
            .confirmAction($pending) { try await performDelete() }
    }

    private func row(_ item: JSON) -> some View {
        ReviewsReplyRow(reply: item)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    ask(item)
                } label: { Label("Снять", systemImage: "trash") }
            }
            .contextMenu {
                Button(role: .destructive) {
                    ask(item)
                } label: { Label("Снять ответ", systemImage: "trash") }
            }
    }

    private func ask(_ item: JSON) {
        deleteId = item.id
        let shop = item["shop"].nonEmptyString ?? "магазина"
        pending = ConfirmAction(title: "Снять ответ продавца?",
                                message: "Ответ «" + shop + "» удалится с публичной страницы. Это необратимо.",
                                confirmLabel: "Снять", destructive: true)
    }

    private func performDelete() async throws {
        guard let id = deleteId else { return }
        try await API.shared.delete("/api/admin/review-replies/\(id)")
        model.remove(id: id)
    }
}

/// Строка ответа продавца: отзыв (кратко) и сам ответ.
struct ReviewsReplyRow: View {
    let reply: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(reply["shop"].nonEmptyString ?? "Магазин")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(Fmt.date(reply["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            reviewQuote
            Text(reply["text"].nonEmptyString ?? "—")
                .font(.subheadline)
                .textSelection(.enabled)
            Text("Ответ #" + reply["id"].stringValue + " · отзыв #" + reply["review_id"].stringValue)
                .font(.caption2)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }

    private var reviewQuote: some View {
        let stars = ReviewsFormat.stars(reply["rating_overall"].intValue)
        let text = reply["review_text"].nonEmptyString ?? "без текста"
        return HStack(alignment: .top, spacing: 6) {
            Rectangle().fill(Brand.border).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(stars).font(.caption).foregroundColor(Brand.amber)
                Text(text)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
