import SwiftUI

/// Организации, готовые к публикации: GET /api/admin/publish-requests.
///
/// Продавец заполнил организацию и нажал «Показать организацию» (status = review).
/// Здесь: открыть карточку (товары, условия), «Опубликовать» —
/// POST /api/admin/shops/{id}/publish, «На доработку» —
/// POST /api/admin/shops/{id}/publish-reject {note} (не короче 5 символов).
struct PublishRequestsView: View {
    @ObservedObject var model: PagedListModel
    @State private var rejectTarget: PublishRejectTarget?

    init(model: PagedListModel) {
        self.model = model
    }

    var body: some View {
        List {
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
            TextInputSheet(title: "На доработку",
                           message: "Что нужно исправить в «" + target.name + "»? Текст увидит продавец в панели.",
                           placeholder: "Например: добавьте фото товаров и часы работы",
                           multiline: true, submitTitle: "Вернуть на доработку", minLength: 5,
                           destructive: true) { text in
                try await API.shared.post("/api/admin/shops/" + String(target.id) + "/publish-reject", body: ["note": text])
                model.remove(id: target.id)
                Task { await Notifier.shared.refresh(force: true) }
            }
        }
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
            EmptyStateView(title: "Никто не ждёт публикации", systemImage: "checkmark.seal",
                           message: "Когда продавец заполнит организацию и отправит её на проверку, она появится здесь.")
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .loaded:
            Section {
                Text("Продавец заполнил организацию и ждёт проверки. Откройте карточку, посмотрите каталог и условия — и опубликуйте или верните с замечанием.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
            ForEach(model.items, id: \.stableID) { item in
                PublishRequestSection(item: item, model: model) {
                    rejectTarget = PublishRejectTarget(id: item.id ?? 0, name: item["name"].stringValue)
                }
            }
        }
    }
}

/// Кому возвращаем на доработку (для .sheet(item:)).
struct PublishRejectTarget: Identifiable {
    let id: Int
    let name: String
}

/// Одна организация в очереди: сведения + кнопки.
struct PublishRequestSection: View {
    let item: JSON
    @ObservedObject var model: PagedListModel
    let onReject: () -> Void

    init(item: JSON, model: PagedListModel, onReject: @escaping () -> Void) {
        self.item = item
        self.model = model
        self.onReject = onReject
    }

    private var shopId: Int { item.id ?? 0 }
    private var name: String { item["name"].nonEmptyString ?? "Без названия" }

    private var catalog: String {
        String(item["products_count"].intValue) + " тов. / " + String(item["services_count"].intValue) + " усл."
    }

    private var metaLine: String {
        let city = item["city"].nonEmptyString ?? "—"
        let mode = ShopsLabels.mode(item["mode"].string)
        return [city, mode, catalog].joined(separator: " · ")
    }

    private var owner: String {
        var parts: [String] = []
        if let o = item["owner"].nonEmptyString { parts.append(o) }
        if let p = item["owner_phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    var body: some View {
        Section {
            NavigationLink(destination: ShopDetailView(id: shopId, onDeleted: { removed in model.remove(id: removed) })) {
                info
            }
            HStack(spacing: 10) {
                ActionButton("Опубликовать", systemImage: "checkmark.seal", style: .prominent,
                             confirm: ConfirmAction(title: "Опубликовать «" + name + "»?",
                                                    message: "Организация появится на сайте и в мобильных приложениях, а клиенты города получат уведомление.",
                                                    confirmLabel: "Опубликовать")) {
                    try await API.shared.post("/api/admin/shops/" + String(shopId) + "/publish", body: [:])
                    model.remove(id: shopId)
                    Task { await Notifier.shared.refresh(force: true) }
                }
                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("На доработку", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 2)
        }
    }

    private var info: some View {
        HStack(alignment: .top, spacing: 12) {
            if let logo = item["logo"].nonEmptyString {
                AsyncImageView(path: logo, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold))
                if let slug = item["slug"].nonEmptyString {
                    Text(slug).font(.caption2).foregroundColor(Brand.muted)
                }
                Text(metaLine)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                Text("Владелец: " + owner)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if let sent = item["submitted_at"].nonEmptyString {
                    Text("Отправлено " + Fmt.date(sent))
                        .font(.caption2)
                        .foregroundColor(Brand.muted)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
