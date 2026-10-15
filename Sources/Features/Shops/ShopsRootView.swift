import SwiftUI

/// Раздел «Магазины»: список организаций (GET /api/admin/shops) с поиском по
/// названию/ИНН, фильтрами «Статус» (как на сайте) и «Город» (сервер принимает
/// параметр city), очередь модерации сверху и переход в карточку.
///
/// `openId` — id организации: карточка открывается сразу (push «shop_publish_request»).
struct ShopsRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/shops")
    @ObservedObject private var notifier = Notifier.shared
    @State private var cityOptions: [PickerOption] = []
    @State private var openDeepLink = false
    @State private var deepLinkHandled = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var filters: [ListFilter] {
        var list = [ListFilter(key: "status", title: "Статус", options: ShopsLabels.statusFilter, allLabel: "Все статусы")]
        if !cityOptions.isEmpty {
            list.append(ListFilter(key: "city", title: "Город", options: cityOptions, allLabel: "Все города"))
        }
        return list
    }

    var body: some View {
        AdminListScreen("Магазины", model: model, searchPrompt: "Название или ИНН", filters: filters,
                        emptyText: "Магазинов нет", header: queueHeader,
                        row: { ShopsListRow(shop: $0) },
                        destination: { shop in shopDestination(shop) })
            .navigationDestination(isPresented: $openDeepLink) {
                ShopDetailView(id: openId ?? 0, onDeleted: { removed in model.remove(id: removed) })
            }
            .onAppear {
                if let _ = openId, !deepLinkHandled {
                    deepLinkHandled = true
                    openDeepLink = true
                }
            }
            .task { await loadCities() }
    }

    /// Плашка очереди — только когда есть что модерировать (пустой AnyView дал бы пустую строку).
    private var queueHeader: AnyView? {
        let publish = notifier.count(.publish)
        let docs = notifier.count(.documents)
        guard publish > 0 || docs > 0 else { return nil }
        return AnyView(ShopsQueueHeader(publish: publish, docs: docs))
    }

    private func shopDestination(_ shop: JSON) -> some View {
        ShopDetailView(id: shop.id ?? 0, onDeleted: { removed in model.remove(id: removed) })
    }

    /// Города, в которых есть организации (GET /api/admin/cities?with_shops=1, до 4 страниц по 50).
    private func loadCities() async {
        guard cityOptions.isEmpty else { return }
        var out: [PickerOption] = []
        var page = 1
        while page <= 4 {
            let q: [String: String?] = ["with_shops": "1", "page": String(page)]
            guard let data = try? await API.shared.get("/api/admin/cities", query: q) else { break }
            let items = data["items"].array
            for c in items {
                if let id = c["id"].string, let name = c["name"].nonEmptyString {
                    out.append(PickerOption(value: id, label: name))
                }
            }
            let pages = data["pages"].int ?? 1
            if items.isEmpty || page >= pages { break }
            page += 1
        }
        let sorted = out.sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
        cityOptions = sorted
    }
}

/// Строка списка магазинов: название, владелец, город, режим, каталог, баланс, комиссия, статус.
struct ShopsListRow: View {
    let shop: JSON

    init(shop: JSON) {
        self.shop = shop
    }

    private var balance: Decimal { shop["balance"].decimal ?? 0 }

    private var catalog: String {
        var parts: [String] = []
        let p = shop["products_count"].intValue
        let s = shop["services_count"].intValue
        if p > 0 { parts.append(String(p) + " тов.") }
        if s > 0 { parts.append(String(s) + " усл.") }
        return parts.joined(separator: " · ")
    }

    private var metaLine: String {
        var parts: [String] = []
        if let c = shop["city"].nonEmptyString { parts.append(c) }
        parts.append(ShopsLabels.mode(shop["mode"].string))
        let cat = catalog
        if !cat.isEmpty { parts.append(cat) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(shop["name"].nonEmptyString ?? "Без названия")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                StatusBadge(ShopsLabels.status(shop["status"].string),
                            color: ShopsLabels.statusColor(shop["status"].string))
            }
            if let owner = shop["owner"].nonEmptyString {
                Text(owner)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(metaLine)
                .font(.caption)
                .foregroundColor(Brand.muted)
            HStack(spacing: 10) {
                Text("Баланс: " + Fmt.money(balance))
                    .foregroundColor(balance < 500 ? Brand.red : Brand.text)
                Text("Комиссия: " + ShopsLabels.rate(shop["commission_value"], type: shop["commission_type"].string))
                    .foregroundColor(Brand.muted)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 3)
    }
}

/// Плашка над списком: организации ждут публикации / лицензии на проверке
/// (счётчики Notifier). Ведёт в «Заявки магазинов» на нужную вкладку.
struct ShopsQueueHeader: View {
    let publish: Int
    let docs: Int

    var body: some View {
        NavigationLink(destination: RegistrationsRootView(openId: nil, initialTab: publish > 0 ? .publish : .documents)) {
            ShopsQueueLabel(publish: publish, docs: docs)
        }
    }
}

/// Текст плашки очереди.
struct ShopsQueueLabel: View {
    let publish: Int
    let docs: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "seal")
                .foregroundColor(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                if publish > 0 {
                    Text("Готовы к публикации: " + String(publish))
                        .font(.subheadline.weight(.semibold))
                }
                if docs > 0 {
                    Text("Лицензии на проверке: " + String(docs))
                        .font(.subheadline.weight(publish > 0 ? .regular : .semibold))
                }
                Text("Открыть очередь модерации")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 4)
    }
}
