import SwiftUI

/// Раздел «Отзывы»: модерация отзывов клиентов (одобрить / отклонить с причиной,
/// по одному и пачкой) и ответы продавцов на отзывы (снять ответ).
///
/// Ручки: GET /api/admin/reviews (status pending|approved|rejected, q, rating, page),
/// POST /api/admin/reviews/{id}/moderate {decision, note, expected_status},
/// GET /api/admin/review-replies (q, page), DELETE /api/admin/review-replies/{id}.
///
/// `openId` — id отзыва: карточка берётся из GET /api/admin/reviews/{id} (П-29.4);
/// старый сервер без этой ручки — откроется, если отзыв есть на первой странице
/// очереди «На модерации».
struct ReviewsRootView: View {
    let openId: Int?

    @StateObject private var reviews = PagedListModel(path: "/api/admin/reviews", filters: ["status": "pending"])
    @StateObject private var replies = PagedListModel(path: "/api/admin/review-replies")
    @State private var tab: ReviewsTab = .reviews
    @State private var deepLinkPending: Bool
    @State private var deepLinkItem: JSON?
    @State private var deepLinkActive = false
    /// Запрос карточки по id уже сделан (удачно или нет) — дальше можно искать в списке.
    @State private var deepLinkByIdTried = false

    init(openId: Int? = nil) {
        self.openId = openId
        _deepLinkPending = State(initialValue: openId != nil)
    }

    var body: some View {
        Group {
            switch tab {
            case .reviews:
                ReviewsListScreen(model: reviews)
            case .replies:
                ReviewsRepliesScreen(model: replies)
            }
        }
        .safeAreaInset(edge: .top) { tabPicker }
        .onReceive(reviews.$items) { items in
            findDeepLink(in: items)
        }
        .navigationDestination(isPresented: $deepLinkActive) {
            deepLinkDestination
        }
        .task { await openDeepLinkById() }
    }

    @ViewBuilder
    private var deepLinkDestination: some View {
        if let item = deepLinkItem {
            ReviewsDetailView(review: item, model: reviews)
        } else {
            EmptyView()
        }
    }

    private var tabPicker: some View {
        Picker("Раздел", selection: $tab) {
            Text("Отзывы").tag(ReviewsTab.reviews)
            Text("Ответы продавцов").tag(ReviewsTab.replies)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Brand.bg)
    }

    /// П-29.4: отзыв по id — откроется, даже если его нет на первой странице.
    /// Не вышло (старый сервер) — как раньше, ищем в загруженном списке.
    private func openDeepLinkById() async {
        guard deepLinkPending, !deepLinkByIdTried, let id = openId, id > 0 else { return }
        let one = try? await API.shared.get("/api/admin/reviews/" + String(id))
        deepLinkByIdTried = true
        if let item = one, item.id == id, deepLinkPending {
            deepLinkPending = false
            deepLinkItem = item
            deepLinkActive = true
            return
        }
        findDeepLink(in: reviews.items)
    }

    private func findDeepLink(in items: [JSON]) {
        // Сначала ждём ответа карточки по id (openDeepLinkById), потом — список.
        guard deepLinkByIdTried else { return }
        guard deepLinkPending, let id = openId, !items.isEmpty else { return }
        deepLinkPending = false
        if let found = items.first(where: { $0.id == id }) {
            deepLinkItem = found
            deepLinkActive = true
        }
    }
}

/// Вкладки раздела «Отзывы».
enum ReviewsTab: Hashable {
    case reviews, replies
}

/// Подписи и действия раздела «Отзывы».
enum ReviewsFormat {
    /// Причины отклонения (RV_REASONS на сайте).
    static let rejectReasons = ["Спам или реклама", "Оскорбления / мат", "Не относится к товару", "Поддельный отзыв", "Другое"]

    static let statusFilter = ListFilter(key: "status", title: "Статус", options: [
        PickerOption(value: "pending", label: "На модерации"),
        PickerOption(value: "approved", label: "Опубликованные"),
        PickerOption(value: "rejected", label: "Отклонённые"),
    ], allLabel: nil)

    static let ratingFilter = ListFilter(key: "rating", title: "Оценка", options: [
        PickerOption(value: "5", label: "★ 5"),
        PickerOption(value: "4", label: "★ 4"),
        PickerOption(value: "3", label: "★ 3"),
        PickerOption(value: "2", label: "★ 2"),
        PickerOption(value: "1", label: "★ 1"),
    ], allLabel: "Любая")

    static func statusLabel(_ s: String?) -> String {
        switch s ?? "" {
        case "pending": return "На модерации"
        case "approved": return "Опубликован"
        case "rejected": return "Отклонён"
        default: return Fmt.statusLabel(s)
        }
    }

    /// «★★★★☆» по оценке 0…5.
    static func stars(_ n: Int) -> String {
        let k = max(0, min(5, n))
        return String(repeating: "★", count: k) + String(repeating: "☆", count: 5 - k)
    }

    /// Пути фото отзыва из photos_json (строка с JSON-массивом или массив).
    static func photos(_ review: JSON) -> [String] {
        let raw = review["photos_json"]
        var list: [JSON] = raw.array
        if !raw.isArray, let s = raw.nonEmptyString, let parsed = JSON.parse(Data(s.utf8)) {
            list = parsed.array
        }
        var out: [String] = []
        for p in list {
            if let path = ModerationMedia.uploadsPath(p.string) { out.append(path) }
        }
        return out
    }

    /// POST /api/admin/reviews/{id}/moderate.
    static func moderate(id: Int, approve: Bool, note: String, expected: String?) async throws {
        var body: [String: Any?] = ["decision": approve ? "approve" : "reject"]
        if !approve && !note.isEmpty { body["note"] = note }
        if let e = expected, !e.isEmpty { body["expected_status"] = e }
        try await API.shared.post("/api/admin/reviews/\(id)/moderate", body: body)
    }

    /// Строка с новым статусом.
    static func withStatus(_ row: JSON, _ status: String) -> JSON {
        var o = row.object
        o["status"] = .string(status)
        return .object(o)
    }
}

/// Очередь отзывов: фильтры, свайпы, выбор нескольких и действия пачкой.
struct ReviewsListScreen: View {
    @ObservedObject var model: PagedListModel
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var rejectTarget: ReviewsRejectTarget?
    @State private var bulkBusy = false
    @State private var bulkResult: String?
    @State private var pending: ConfirmAction?
    @State private var approveId: Int?

    private var isPendingQueue: Bool { (model.filter("status") ?? "pending") == "pending" }

    var body: some View {
        AdminListScreen("Отзывы", model: model, searchPrompt: "Текст, магазин или автор",
                        filters: [ReviewsFormat.statusFilter, ReviewsFormat.ratingFilter],
                        emptyText: "Отзывов нет",
                        row: { item in row(item) })
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { bulkBar }
            .sheet(item: $rejectTarget) { t in rejectSheet(t) }
            .confirmAction($pending) { try await approveSingle() }
            .alert(bulkResult ?? "", isPresented: bulkResultShown) {
                Button("OK", role: .cancel) {}
            }
            .onChange(of: model.filter("status")) { _ in
                selecting = false
                selected = []
            }
    }

    private var bulkResultShown: Binding<Bool> {
        Binding(get: { bulkResult != nil }, set: { if !$0 { bulkResult = nil } })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if isPendingQueue && !model.items.isEmpty {
                Button(selecting ? "Готово" : "Выбрать") {
                    selecting.toggle()
                    if !selecting { selected = [] }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: JSON) -> some View {
        if selecting {
            selectableRow(item)
        } else {
            NavigationLink(destination: ReviewsDetailView(review: item, model: model)) {
                ReviewsRow(review: item)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) { approveSwipe(item) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) { rejectSwipe(item) }
        }
    }

    private func selectableRow(_ item: JSON) -> some View {
        let id = item.id ?? -1
        let on = selected.contains(id)
        return Button {
            Haptics.tap()
            if on { selected.remove(id) } else { selected.insert(id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(on ? Brand.accent : Brand.muted)
                ReviewsRow(review: item)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func approveSwipe(_ item: JSON) -> some View {
        if item["status"].string == "pending" {
            Button {
                approveId = item.id
                pending = ConfirmAction(title: "Опубликовать отзыв?",
                                        message: ReviewsRow.preview(item),
                                        confirmLabel: "Опубликовать")
            } label: { Label("Одобрить", systemImage: "checkmark") }
            .tint(Brand.green)
        }
    }

    @ViewBuilder
    private func rejectSwipe(_ item: JSON) -> some View {
        if item["status"].string == "pending" {
            Button {
                rejectTarget = ReviewsRejectTarget(ids: [item.id ?? 0], expected: item["status"].string)
            } label: { Label("Отклонить", systemImage: "xmark") }
            .tint(Brand.red)
        }
    }

    @ViewBuilder
    private var bulkBar: some View {
        if selecting {
            VStack(spacing: 8) {
                HStack {
                    Text("Выбрано: " + String(selected.count))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(selected.count == model.items.count ? "Снять все" : "Выбрать все") {
                        toggleAll()
                    }
                    .font(.subheadline)
                }
                HStack(spacing: 10) {
                    bulkApproveButton
                    bulkRejectButton
                }
            }
            .padding(12)
            .background(Brand.card)
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(Brand.border), alignment: .top)
        }
    }

    private var bulkApproveButton: some View {
        Button {
            runBulk(approve: true, note: "")
        } label: {
            HStack {
                if bulkBusy { ProgressView() }
                Text("Одобрить")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.green)
        .disabled(selected.isEmpty || bulkBusy)
    }

    private var bulkRejectButton: some View {
        Button(role: .destructive) {
            rejectTarget = ReviewsRejectTarget(ids: selected.sorted(), expected: "pending")
        } label: {
            Text("Отклонить").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(selected.isEmpty || bulkBusy)
    }

    private func toggleAll() {
        if selected.count == model.items.count {
            selected = []
            return
        }
        var all = Set<Int>()
        for row in model.items {
            if let id = row.id { all.insert(id) }
        }
        selected = all
    }

    private func rejectSheet(_ t: ReviewsRejectTarget) -> some View {
        let ids = t.ids
        let expected = t.expected
        let title = ids.count > 1 ? "Причина отклонения отзывов" : "Причина отклонения отзыва"
        let msg = ids.count > 1 ? "Отклонить " + Fmt.plural(ids.count, "отзыв", "отзыва", "отзывов") + "." : nil
        return ModerationReasonSheet(title: title, message: msg, reasons: ReviewsFormat.rejectReasons,
                                     submitTitle: "Отклонить") { note in
            if ids.count == 1, let id = ids.first {
                try await ReviewsFormat.moderate(id: id, approve: false, note: note, expected: expected)
                model.remove(id: id)
                selected.remove(id)
                Task { await Notifier.shared.refresh(force: true) }
            } else {
                runBulk(approve: false, note: note)
            }
        }
    }

    private func approveSingle() async throws {
        guard let id = approveId else { return }
        try await ReviewsFormat.moderate(id: id, approve: true, note: "", expected: "pending")
        model.remove(id: id)
        Task { await Notifier.shared.refresh(force: true) }
    }

    /// Пачка: по одному запросу на отзыв (как bulkRun на сайте), итог — алертом.
    private func runBulk(approve: Bool, note: String) {
        let ids = selected.sorted()
        guard !ids.isEmpty, !bulkBusy else { return }
        bulkBusy = true
        let m = model
        Task { @MainActor in
            var ok = 0
            var firstError: String?
            for id in ids {
                do {
                    try await ReviewsFormat.moderate(id: id, approve: approve, note: note, expected: "pending")
                    ok += 1
                    m.remove(id: id)
                    selected.remove(id)
                } catch {
                    if firstError == nil { firstError = APIError.describe(error) }
                }
            }
            bulkBusy = false
            let verb = approve ? "Одобрено: " : "Отклонено: "
            var text = verb + String(ok) + " из " + String(ids.count)
            if let e = firstError { text += ". Ошибка: " + e }
            bulkResult = text
            if ok > 0 { Haptics.success() } else { Haptics.error() }
            if selected.isEmpty { selecting = false }
            await m.refresh()
            await Notifier.shared.refresh(force: true)
        }
    }
}

/// Что отклоняем (один отзыв или пачку) — для `.sheet(item:)`.
struct ReviewsRejectTarget: Identifiable {
    let id = UUID()
    let ids: [Int]
    let expected: String?
}

/// Строка отзыва: магазин, автор, оценка, текст, фото.
struct ReviewsRow: View {
    let review: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(review["shop"].nonEmptyString ?? "Магазин")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(Fmt.date(review["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            HStack(spacing: 6) {
                Text(ReviewsFormat.stars(review["rating_overall"].intValue))
                    .foregroundColor(Brand.amber)
                Text(review["author"].nonEmptyString ?? "—")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if review["status"].string != "pending" {
                    StatusBadge(status: review["status"].string,
                                label: ReviewsFormat.statusLabel(review["status"].string))
                }
            }
            if let t = review["text"].nonEmptyString {
                Text(t)
                    .font(.subheadline)
                    .lineLimit(4)
            }
            ReviewsPhotoStrip(paths: ReviewsFormat.photos(review), size: 48)
        }
        .padding(.vertical, 2)
    }

    /// Кратко для подтверждения.
    static func preview(_ r: JSON) -> String {
        let stars = ReviewsFormat.stars(r["rating_overall"].intValue)
        let text = String((r["text"].stringValue).prefix(120))
        return stars + " " + text
    }
}

/// Лента миниатюр фото отзыва.
struct ReviewsPhotoStrip: View {
    let paths: [String]
    let size: CGFloat

    var body: some View {
        if !paths.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(paths, id: \.self) { p in
                        AsyncImageView(path: p, size: size)
                    }
                }
            }
        }
    }
}
