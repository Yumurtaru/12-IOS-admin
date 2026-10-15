import SwiftUI

/// Раздел «Заказы» (арбитраж): все заказы площадки.
///
/// GET /api/admin/orders?status=&shop=&q=&from=&to=&min=&max=&page=
///   → {items:[{id,daily_number,shop_id,status,total,payment_type,delivery_type,created_at,shop,client,client_phone}],
///      total, sum, page, pages} — по 50 строк.
/// Сайт показывает только фильтр статуса; сервер умеет больше (поиск по номеру/клиенту/телефону,
/// период, магазин, диапазон суммы) — всё это здесь есть.
/// `openId` — сразу открыть карточку заказа; `shopId` — список заказов одного магазина
/// (для перехода из карточки магазина).
struct OrdersRootView: View {
    let openId: Int?
    let shopId: Int?

    @StateObject private var model: PagedListModel
    @State private var showFilters = false
    @State private var deepLinkShown = false
    @State private var deepLinkHandled = false

    init(openId: Int? = nil, shopId: Int? = nil) {
        self.openId = openId
        self.shopId = shopId
        var initial: [String: String] = [:]
        if let s = shopId { initial["shop"] = String(s) }
        _model = StateObject(wrappedValue: PagedListModel(path: "/api/admin/orders", filters: initial))
    }

    var body: some View {
        AdminListScreen("Заказы", model: model, searchPrompt: "Номер, клиент, телефон",
                        filters: OrdersRootView.filters, emptyText: "Заказов нет",
                        header: AnyView(OrdersSummaryHeader(model: model)),
                        row: { OrdersRow(order: $0) },
                        destination: { item in OrderDetailView(id: item.id ?? 0) })
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFilters = true
                    } label: {
                        Label("Фильтры", systemImage: filterIcon)
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                OrdersFilterSheet(current: model.filters) { values in
                    applyFilters(values)
                }
            }
            .navigationDestination(isPresented: $deepLinkShown) {
                OrderDetailView(id: openId ?? 0)
            }
            .onAppear { openDeepLinkOnce() }
    }

    private var filterIcon: String {
        let keys = ["from", "to", "shop", "min", "max"]
        let active = keys.contains { model.filter($0) != nil }
        return active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    private func applyFilters(_ values: [String: String?]) {
        for key in OrdersFilterSheet.keys {
            let v = values[key] ?? nil
            if model.filter(key) != v {
                model.setFilter(key, v)
            }
        }
    }

    private func openDeepLinkOnce() {
        guard !deepLinkHandled, openId != nil else { return }
        deepLinkHandled = true
        deepLinkShown = true
    }

    /// Статусы заказа (сайт показывает три; сервер принимает любой из них).
    static let statusOptions: [PickerOption] = [
        PickerOption(value: "new", label: "Новые"),
        PickerOption(value: "accepted", label: "Принятые"),
        PickerOption(value: "preparing", label: "Готовятся"),
        PickerOption(value: "ready", label: "Готовы"),
        PickerOption(value: "in_delivery", label: "В пути"),
        PickerOption(value: "done", label: "Выполненные"),
        PickerOption(value: "cancelled", label: "Отменённые"),
    ]

    static let filters: [ListFilter] = [
        ListFilter(key: "status", title: "Статус", options: statusOptions),
    ]
}

/// Подписи кодов заказа по-русски.
enum OrdersLabels {
    static func status(_ code: String?) -> String {
        switch code ?? "" {
        case "new": return "Новый"
        case "accepted": return "Принят"
        case "preparing": return "Готовится"
        case "ready": return "Готов"
        case "in_delivery": return "В пути"
        case "done": return "Выполнен"
        case "cancelled": return "Отменён"
        default: return Fmt.statusLabel(code)
        }
    }

    static func payment(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "cash": return "Наличные"
        case "card_courier": return "Картой курьеру"
        case "sbp": return "СБП"
        case "online_card": return "Онлайн картой"
        case "wallet": return "Кошелёк"
        case "": return "—"
        default: return c
        }
    }

    static func paymentStatus(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "pending": return "Не оплачен"
        case "paid": return "Оплачен"
        case "refunded": return "Деньги возвращены"
        case "awaiting_courier_cash": return "Наличные у курьера"
        case "": return "—"
        default: return c
        }
    }

    static func delivery(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "delivery": return "Доставка"
        case "pickup": return "Самовывоз"
        case "dine_in": return "В зале"
        case "": return "—"
        default: return c
        }
    }
}

/// Сводка над списком: сколько заказов и на какую сумму + активные доп. фильтры.
struct OrdersSummaryHeader: View {
    @ObservedObject var model: PagedListModel

    init(model: PagedListModel) {
        self.model = model
    }

    private var summary: String? {
        guard let t = model.total else { return nil }
        let count = Fmt.plural(t, "заказ", "заказа", "заказов")
        return count + " на " + Fmt.money(model.lastData["sum"])
    }

    private var activeFilters: String? {
        var parts: [String] = []
        if let s = model.filter("shop") { parts.append("магазин #" + s) }
        let from = model.filter("from").map { "с " + Fmt.day($0) }
        let to = model.filter("to").map { "по " + Fmt.day($0) }
        let period = [from, to].compactMap { $0 }.joined(separator: " ")
        if !period.isEmpty { parts.append(period) }
        if let mn = model.filter("min") { parts.append("от " + Fmt.money(Fmt.parseDecimal(mn))) }
        if let mx = model.filter("max") { parts.append("до " + Fmt.money(Fmt.parseDecimal(mx))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        if summary != nil || activeFilters != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let s = summary {
                    Text(s)
                        .font(.subheadline.weight(.semibold))
                }
                if let f = activeFilters {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(f).lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Сбросить") { clearExtra() }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                }
            }
            .listRowSeparator(.hidden)
        }
    }

    private func clearExtra() {
        for key in OrdersFilterSheet.keys where model.filter(key) != nil {
            model.setFilter(key, nil)
        }
    }
}

/// Строка заказа: номер, магазин, клиент, сумма, оплата, статус, дата.
struct OrdersRow: View {
    let order: JSON

    init(order: JSON) {
        self.order = order
    }

    private var number: String {
        let base = "#" + order["id"].stringValue
        guard let d = order["daily_number"].nonEmptyString, d != "0" else { return base }
        return base + " · №" + d
    }

    private var client: String {
        let name = order["client"].nonEmptyString ?? "Гость"
        guard let p = order["client_phone"].nonEmptyString else { return name }
        return name + " · " + Fmt.phone(p)
    }

    private var meta: String {
        let pay = OrdersLabels.payment(order["payment_type"].string)
        let del = OrdersLabels.delivery(order["delivery_type"].string)
        let date = Fmt.date(order["created_at"])
        return [del, pay, date].joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(number)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                MoneyText(order["total"])
                    .font(.body.weight(.semibold))
            }
            HStack {
                Text(order["shop"].nonEmptyString ?? "—")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusBadge(status: order["status"].string, label: OrdersLabels.status(order["status"].string))
            }
            Text(client)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
            Text(meta)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

/// Лист доп. фильтров заказов: период, магазин (id), сумма от/до.
struct OrdersFilterSheet: View {
    /// Ключи запроса, которыми управляет лист.
    static let keys = ["from", "to", "shop", "min", "max"]

    let current: [String: String]
    let onApply: ([String: String?]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var useFrom: Bool
    @State private var useTo: Bool
    @State private var from: Date
    @State private var to: Date
    @State private var shop: String
    @State private var minText: String
    @State private var maxText: String

    init(current: [String: String], onApply: @escaping ([String: String?]) -> Void) {
        self.current = current
        self.onApply = onApply
        let fromDate = Fmt.parseDate(current["from"])
        let toDate = Fmt.parseDate(current["to"])
        _useFrom = State(initialValue: fromDate != nil)
        _useTo = State(initialValue: toDate != nil)
        _from = State(initialValue: fromDate ?? Date().addingTimeInterval(-7 * 86_400))
        _to = State(initialValue: toDate ?? Date())
        _shop = State(initialValue: current["shop"] ?? "")
        _minText = State(initialValue: OrdersFilterSheet.decimalText(current["min"]))
        _maxText = State(initialValue: OrdersFilterSheet.decimalText(current["max"]))
    }

    private static func decimalText(_ s: String?) -> String {
        guard let s = s, let d = Decimal(string: s) else { return "" }
        return Fmt.decimalInput(d)
    }

    private var shopInvalid: Bool {
        let t = shop.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && (Int(t) ?? 0) <= 0
    }

    private var amountsInvalid: Bool {
        let a = minText.trimmingCharacters(in: .whitespaces)
        let b = maxText.trimmingCharacters(in: .whitespaces)
        let badA = !a.isEmpty && Fmt.parseDecimal(a) == nil
        let badB = !b.isEmpty && Fmt.parseDecimal(b) == nil
        return badA || badB
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Период") {
                    Toggle("С даты", isOn: $useFrom)
                    if useFrom { FormDateField("С", date: $from) }
                    Toggle("По дату", isOn: $useTo)
                    if useTo { FormDateField("По", date: $to) }
                }
                Section {
                    FormIntField("ID магазина", text: $shop, prompt: "например, 12")
                } header: {
                    Text("Магазин")
                } footer: {
                    Text("ID виден в карточке магазина.")
                }
                Section("Сумма заказа") {
                    FormDecimalField("От", text: $minText)
                    FormDecimalField("До", text: $maxText)
                }
                Section {
                    Button("Сбросить всё", role: .destructive) { reset() }
                }
            }
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Показать") { apply() }
                        .disabled(shopInvalid || amountsInvalid)
                }
            }
        }
    }

    private func reset() {
        useFrom = false
        useTo = false
        shop = ""
        minText = ""
        maxText = ""
    }

    private func amountValue(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let d = Fmt.parseDecimal(t) else { return nil }
        return NSDecimalNumber(decimal: d).stringValue
    }

    private func apply() {
        var out: [String: String?] = [:]
        out["from"] = useFrom ? Fmt.ymd(from) : nil
        out["to"] = useTo ? Fmt.ymd(to) : nil
        let s = shop.trimmingCharacters(in: .whitespaces)
        out["shop"] = s.isEmpty ? nil : s
        out["min"] = amountValue(minText)
        out["max"] = amountValue(maxText)
        onApply(out)
        dismiss()
    }
}
