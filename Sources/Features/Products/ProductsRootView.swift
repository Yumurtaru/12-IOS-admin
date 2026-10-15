import SwiftUI

/// Раздел «Товары»: модерация товаров площадки (скрыть/вернуть на витрину)
/// и общие категории каталога (на сайте отдельного экрана для них нет —
/// здесь это вкладка «Категории»).
///
/// Ручки: GET /api/admin/products (q, status, shop, page; 50 на страницу),
/// POST /api/admin/products/{id}/status {hide, reason};
/// GET/POST/PUT/DELETE /api/admin/categories…
///
/// `openId` — id товара: список сразу ищется по номеру (сервер ищет по id в q).
struct ProductsRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/products")
    @StateObject private var categories = ObjectLoader(path: "/api/admin/categories")
    @State private var tab: ProductsTab = .products
    @State private var didApplyDeepLink = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        Group {
            switch tab {
            case .products:
                ProductsListScreen(model: model)
            case .categories:
                ProductsCategoriesScreen(loader: categories)
            }
        }
        .safeAreaInset(edge: .top) { tabPicker }
        .onAppear(perform: applyDeepLink)
    }

    private var tabPicker: some View {
        Picker("Раздел", selection: $tab) {
            Text("Товары").tag(ProductsTab.products)
            Text("Категории").tag(ProductsTab.categories)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Brand.bg)
    }

    private func applyDeepLink() {
        guard !didApplyDeepLink else { return }
        didApplyDeepLink = true
        if let id = openId {
            tab = .products
            model.searchText = String(id)
        }
    }
}

/// Вкладки раздела «Товары».
enum ProductsTab: Hashable {
    case products, categories
}

/// Подписи и варианты раздела «Товары».
enum ProductsFormat {
    /// Причины снятия товара (как PM_REASONS на сайте).
    static let hideReasons = [
        "Запрещённый к продаже товар",
        "Вводящее в заблуждение описание",
        "Чужие фотографии или товарный знак",
        "Неверная категория",
        "Цена не соответствует товару",
    ]

    /// Фильтр по статусу (вкладки pm-tabs на сайте).
    static let statusFilter = ListFilter(key: "status", title: "Статус", options: [
        PickerOption(value: "active", label: "Опубликованные"),
        PickerOption(value: "hidden", label: "Скрытые модератором"),
        PickerOption(value: "archived", label: "В архиве"),
    ])

    /// Подпись статуса товара.
    static func statusLabel(_ s: String?) -> String {
        switch s ?? "" {
        case "active": return "Опубликован"
        case "hidden": return "Скрыт модератором"
        case "archived": return "В архиве"
        case "draft": return "Черновик"
        default: return Fmt.statusLabel(s)
        }
    }

    /// Цвет статуса товара.
    static func statusColor(_ s: String?) -> Color {
        switch s ?? "" {
        case "active": return Brand.green
        case "hidden": return Brand.red
        default: return Brand.muted
        }
    }
}

/// Список товаров с поиском, фильтром статуса и действиями «Скрыть»/«Вернуть».
struct ProductsListScreen: View {
    @ObservedObject var model: PagedListModel
    @State private var hideTarget: JSON?
    @State private var pending: ConfirmAction?
    @State private var showTarget: JSON?

    var body: some View {
        AdminListScreen("Товары", model: model,
                        searchPrompt: "Название, артикул, штрихкод или номер",
                        filters: [ProductsFormat.statusFilter],
                        emptyText: "Товаров не найдено",
                        row: { item in rowView(item) },
                        destination: { item in ProductsDetailView(product: item, model: model) })
            .sheet(item: hideSheetBinding) { wrapper in
                hideSheet(wrapper.json)
            }
            .confirmAction($pending) {
                try await performShow()
            }
    }

    private var hideSheetBinding: Binding<ProductsJSONBox?> {
        Binding(get: { hideTarget.map { ProductsJSONBox(json: $0) } },
                set: { if $0 == nil { hideTarget = nil } })
    }

    private func rowView(_ item: JSON) -> some View {
        // Строка обёрнута в NavigationLink (переход к карточке), свайп-действия
        // на вложенном виде не срабатывают — поэтому меню по долгому нажатию.
        ProductsRow(product: item)
            .contextMenu { menuButton(item) }
    }

    @ViewBuilder
    private func menuButton(_ item: JSON) -> some View {
        if item["status"].string == "hidden" {
            Button {
                showTarget = item
                pending = ConfirmAction(title: "Вернуть товар на витрину?",
                                        message: item["name"].string,
                                        confirmLabel: "Вернуть")
            } label: { Label("Вернуть на витрину", systemImage: "eye") }
        } else {
            Button(role: .destructive) {
                hideTarget = item
            } label: { Label("Скрыть с витрины", systemImage: "eye.slash") }
        }
    }

    private func hideSheet(_ item: JSON) -> some View {
        let id = item.id ?? 0
        let name = item["name"].stringValue
        let m = model
        return ModerationReasonSheet(title: "Причина снятия товара",
                                     message: "«" + name + "» пропадёт с витрины и из поиска. Причину увидит продавец.",
                                     reasons: ProductsFormat.hideReasons,
                                     submitTitle: "Скрыть товар") { reason in
            try await ProductsActions.setHidden(id: id, hide: true, reason: reason)
            m.update(id: id) { row in
                row = ProductsActions.patched(row, status: "hidden", reason: reason)
            }
        }
    }

    private func performShow() async throws {
        guard let item = showTarget, let id = item.id else { return }
        try await ProductsActions.setHidden(id: id, hide: false, reason: "")
        model.update(id: id) { row in
            row = ProductsActions.patched(row, status: "active", reason: "")
        }
    }
}

/// JSON в обёртке Identifiable — для `.sheet(item:)`.
struct ProductsJSONBox: Identifiable {
    let json: JSON
    var id: String { json.stableID }
}

/// Действия над товаром.
enum ProductsActions {
    /// POST /api/admin/products/{id}/status {hide, reason}.
    static func setHidden(id: Int, hide: Bool, reason: String) async throws {
        var body: [String: Any?] = ["hide": hide]
        if hide { body["reason"] = reason }
        try await API.shared.post("/api/admin/products/\(id)/status", body: body)
    }

    /// Строка списка с новым статусом и причиной (без перезагрузки списка).
    static func patched(_ row: JSON, status: String, reason: String) -> JSON {
        var o = row.object
        o["status"] = .string(status)
        o["hide_reason"] = .string(reason)
        return .object(o)
    }
}

/// Строка товара: фото, название, магазин, цена, статус, причина скрытия.
struct ProductsRow: View {
    let product: JSON

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImageView(path: ModerationMedia.uploadsPath(product["photo"].string), size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(product["name"].nonEmptyString ?? "Без названия")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    MoneyText(product["price"]).font(.subheadline)
                    StatusBadge(ProductsFormat.statusLabel(product["status"].string),
                                color: ProductsFormat.statusColor(product["status"].string))
                }
                if let r = product["hide_reason"].nonEmptyString {
                    Text("Причина: " + r)
                        .font(.caption)
                        .foregroundColor(Brand.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let shop = product["shop"].nonEmptyString ?? "—"
        return "#" + product["id"].stringValue + " · " + shop
    }
}
