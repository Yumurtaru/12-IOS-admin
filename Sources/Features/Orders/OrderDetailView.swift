import SwiftUI

/// Карточка заказа для администратора (только чтение — менять статус заказа
/// админ не может, это работа магазина; так задумано на сервере).
///
/// GET /api/admin/orders/{id} → o.* + shop, shop_slug, shop_phone, client, client_phone, client_email,
///   courier_name, courier_phone, items[{id,name,price,qty,modifiers_json,return_qty}],
///   log[{status,created_at}], returns[{id,type,status,refund_amount,reason_code,created_at}], address.
/// Ссылки: магазин → ShopDetailView, клиент → UserDetailView, возврат → раздел «Возвраты».
struct OrderDetailView: View {
    let id: Int

    @StateObject private var loader: ObjectLoader

    init(id: Int) {
        self.id = id
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/orders/" + String(id)))
    }

    private var order: JSON { loader.data }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Заказ не найден", retry: { await loader.load() }) {
            content
        }
        .navigationTitle("Заказ #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
    }

    private var content: some View {
        List {
            if let err = loader.lastRefreshError {
                ErrorBanner(message: err, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            OrdersHeaderSection(order: order)
            OrdersPartiesSection(order: order)
            OrdersDeliverySection(order: order)
            OrdersItemsSection(items: order["items"].array)
            OrdersTotalsSection(order: order)
            OrdersPaymentSection(order: order)
            OrdersLogSection(log: order["log"].array)
            OrdersReturnsSection(returns: order["returns"].array)
            Section {
                JSONInspectorView(order)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }
}

/// Пара «подпись — значение» для секций, где строки показываются только при наличии данных.
struct OrdersPair: Identifiable {
    let title: String
    let value: String
    var id: String { title }

    init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    /// Добавить строку, если значение не пустое.
    static func add(_ list: inout [OrdersPair], _ title: String, _ value: String?) {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        list.append(OrdersPair(title: title, value: v))
    }

    /// Добавить сумму, если она есть и не ноль.
    static func addMoney(_ list: inout [OrdersPair], _ title: String, _ json: JSON, keepZero: Bool = false) {
        guard let d = json.decimal else { return }
        if d == 0 && !keepZero { return }
        list.append(OrdersPair(title: title, value: Fmt.money(d)))
    }
}

/// Список пар как строки KVRow.
struct OrdersPairsView: View {
    let pairs: [OrdersPair]

    init(pairs: [OrdersPair]) {
        self.pairs = pairs
    }

    var body: some View {
        ForEach(pairs) { p in
            KVRow(p.title, p.value)
        }
    }
}

/// Шапка: номер, № за день, статус, дата, способ получения.
struct OrdersHeaderSection: View {
    let order: JSON

    init(order: JSON) {
        self.order = order
    }

    private var title: String {
        let base = "Заказ #" + order["id"].stringValue
        guard let d = order["daily_number"].nonEmptyString, d != "0" else { return base }
        return base + " · №" + d
    }

    private var pairs: [OrdersPair] {
        var list: [OrdersPair] = []
        OrdersPair.add(&list, "Создан", Fmt.date(order["created_at"]))
        OrdersPair.add(&list, "Получение", OrdersLabels.delivery(order["delivery_type"].string))
        if order["preorder_at"].exists {
            OrdersPair.add(&list, "Предзаказ на", Fmt.date(order["preorder_at"]))
        }
        if order["assembled_at"].exists {
            OrdersPair.add(&list, "Собран", Fmt.date(order["assembled_at"]))
        }
        if order["issued_at"].exists {
            OrdersPair.add(&list, "Выдан", Fmt.date(order["issued_at"]))
        }
        OrdersPair.add(&list, "Источник", order["source"].nonEmptyString)
        return list
    }

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                StatusBadge(status: order["status"].string, label: OrdersLabels.status(order["status"].string))
            }
            .padding(.vertical, 4)
            HStack {
                Text("Итого")
                    .foregroundColor(Brand.muted)
                Spacer()
                MoneyText(order["total"])
                    .font(.title3.weight(.semibold))
            }
            OrdersPairsView(pairs: pairs)
        }
    }
}

/// Магазин, клиент и курьер — со ссылками на карточки и звонком.
struct OrdersPartiesSection: View {
    let order: JSON

    init(order: JSON) {
        self.order = order
    }

    var body: some View {
        Section("Магазин") {
            shopLink
            OrdersPhoneRow(title: "Телефон магазина", phone: order["shop_phone"].nonEmptyString)
        }
        Section("Клиент") {
            clientLink
            OrdersPhoneRow(title: "Телефон", phone: order["client_phone"].nonEmptyString)
            if let orderPhone = order["phone"].nonEmptyString,
               orderPhone != order["client_phone"].stringValue {
                OrdersPhoneRow(title: "Телефон в заказе", phone: orderPhone)
            }
            if let email = order["client_email"].nonEmptyString {
                KVRow("Почта", email, copyable: true)
            }
        }
        if order["courier_name"].exists || order["courier_phone"].exists {
            Section("Курьер") {
                KVRow("Имя", order["courier_name"].string)
                OrdersPhoneRow(title: "Телефон", phone: order["courier_phone"].nonEmptyString)
            }
        }
    }

    @ViewBuilder
    private var shopLink: some View {
        let name = order["shop"].nonEmptyString ?? ("Магазин #" + order["shop_id"].stringValue)
        if let sid = order["shop_id"].int, sid > 0 {
            NavigationLink(destination: ShopDetailView(id: sid)) {
                Label(name, systemImage: "building.2")
            }
        } else {
            Label(name, systemImage: "building.2")
        }
    }

    @ViewBuilder
    private var clientLink: some View {
        let name = order["client"].nonEmptyString ?? "Гость"
        if let cid = order["client_id"].int, cid > 0 {
            NavigationLink(destination: UserDetailView(id: cid)) {
                Label(name, systemImage: "person")
            }
        } else {
            Label(name, systemImage: "person")
        }
    }
}

/// Телефон: нажатие — позвонить.
struct OrdersPhoneRow: View {
    let title: String
    let phone: String?

    init(title: String, phone: String?) {
        self.title = title
        self.phone = phone
    }

    var body: some View {
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) {
                HStack {
                    Text(title).foregroundColor(Brand.muted)
                    Spacer()
                    Text(Fmt.phone(phone))
                }
                .font(.subheadline)
            }
        } else if phone != nil {
            KVRow(title, phone, copyable: true)
        }
    }
}

/// Доставка: адрес, стол, комментарии.
struct OrdersDeliverySection: View {
    let order: JSON

    init(order: JSON) {
        self.order = order
    }

    private var pairs: [OrdersPair] {
        var list: [OrdersPair] = []
        OrdersPair.add(&list, "Адрес", order["address"].nonEmptyString)
        OrdersPair.add(&list, "Стол", order["table_number"].nonEmptyString)
        OrdersPair.add(&list, "Запись на", order["appointment"].nonEmptyString.map { Fmt.date($0) })
        OrdersPair.add(&list, "Комментарий", order["comment"].nonEmptyString)
        OrdersPair.add(&list, "Комментарий клиента", order["client_comment"].nonEmptyString)
        return list
    }

    var body: some View {
        if !pairs.isEmpty {
            Section("Доставка и комментарии") {
                OrdersPairsView(pairs: pairs)
            }
        }
    }
}

/// Состав заказа.
struct OrdersItemsSection: View {
    let items: [JSON]

    init(items: [JSON]) {
        self.items = items
    }

    var body: some View {
        Section {
            if items.isEmpty {
                Text("Позиции не найдены")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.stableID) { item in
                    OrdersItemLine(item: item)
                }
            }
        } header: {
            Text("Состав · " + Fmt.plural(items.count, "позиция", "позиции", "позиций"))
        }
    }
}

/// Позиция: название, добавки, количество × цена, возвращено.
struct OrdersItemLine: View {
    let item: JSON

    init(item: JSON) {
        self.item = item
    }

    private var qty: Decimal { item["qty"].decimal ?? 0 }
    private var price: Decimal { item["price"].decimal ?? 0 }
    private var returned: Decimal { item["return_qty"].decimal ?? 0 }

    private var lineText: String {
        Fmt.number(qty) + " × " + Fmt.money(price)
    }

    /// modifiers_json — строка с JSON-массивом добавок ([{id,name,price}] или просто имена).
    private var modifiers: String? {
        guard let raw = item["modifiers_json"].nonEmptyString,
              let data = raw.data(using: .utf8),
              let parsed = JSON.parse(data) else { return nil }
        var names: [String] = []
        for m in parsed.array {
            if let s = OrdersItemLine.modifierName(m) { names.append(s) }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static func modifierName(_ m: JSON) -> String? {
        if m.isObject {
            guard let n = m["name"].nonEmptyString else { return nil }
            guard let p = m["price"].decimal, p != 0 else { return n }
            return n + " (" + Fmt.moneySigned(p) + ")"
        }
        return m.nonEmptyString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["name"].nonEmptyString ?? "—")
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text(Fmt.money(qty * price))
                    .font(.subheadline.monospacedDigit())
            }
            if let mods = modifiers {
                Text("+ " + mods)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            HStack(spacing: 8) {
                Text(lineText)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if returned > 0 {
                    StatusBadge("возвращено " + Fmt.number(returned), color: Brand.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Итоги: подытог, доставка, сборы, скидки, баллы, чаевые, итого.
struct OrdersTotalsSection: View {
    let order: JSON

    init(order: JSON) {
        self.order = order
    }

    private var pairs: [OrdersPair] {
        var list: [OrdersPair] = []
        OrdersPair.addMoney(&list, "Товары", order["subtotal"], keepZero: true)
        OrdersPair.addMoney(&list, "Доставка", order["delivery_price"])
        OrdersPair.addMoney(&list, "Сервисный сбор", order["service_fee"])
        OrdersPair.addMoney(&list, "Скидка", order["discount"])
        if let code = order["promo_code"].nonEmptyString {
            let amount = order["promo_discount"].decimal.map { " · −" + Fmt.money($0) } ?? ""
            list.append(OrdersPair(title: "Промокод", value: code + amount))
        }
        OrdersPair.addMoney(&list, "Оплачено баллами", order["points_spent"])
        OrdersPair.addMoney(&list, "Чаевые", order["tip"])
        OrdersPair.addMoney(&list, "Итого", order["total"], keepZero: true)
        OrdersPair.addMoney(&list, "Начислено баллов", order["points_earned"])
        OrdersPair.addMoney(&list, "Кешбэк", order["cashback_amount"])
        return list
    }

    var body: some View {
        Section("Суммы") {
            OrdersPairsView(pairs: pairs)
        }
    }
}

/// Оплата: способ, статус, фактический способ и наличные.
struct OrdersPaymentSection: View {
    let order: JSON

    init(order: JSON) {
        self.order = order
    }

    private var pairs: [OrdersPair] {
        var list: [OrdersPair] = []
        OrdersPair.add(&list, "Способ", OrdersLabels.payment(order["payment_type"].string))
        if order["payment_status"].exists {
            OrdersPair.add(&list, "Статус оплаты", OrdersLabels.paymentStatus(order["payment_status"].string))
        }
        OrdersPair.add(&list, "Фактически", order["paid_method"].nonEmptyString)
        OrdersPair.addMoney(&list, "Наличными", order["paid_cash"])
        OrdersPair.add(&list, "Наличные курьера", order["courier_cash_status"].nonEmptyString)
        OrdersPair.addMoney(&list, "Курьер должен сдать", order["courier_cash_expected"])
        OrdersPair.add(&list, "Заметка об оплате", order["payment_note"].nonEmptyString)
        return list
    }

    var body: some View {
        Section("Оплата") {
            OrdersPairsView(pairs: pairs)
        }
    }
}

/// История статусов заказа.
struct OrdersLogSection: View {
    let log: [JSON]

    init(log: [JSON]) {
        self.log = log
    }

    var body: some View {
        if !log.isEmpty {
            Section("История статусов") {
                ForEach(Array(log.enumerated()), id: \.offset) { pair in
                    HStack {
                        StatusBadge(status: pair.element["status"].string,
                                    label: OrdersLabels.status(pair.element["status"].string))
                        Spacer()
                        Text(Fmt.date(pair.element["created_at"]))
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                    }
                }
            }
        }
    }
}

/// Возвраты по заказу — ссылка открывает заявку (решение, выплата).
struct OrdersReturnsSection: View {
    let returns: [JSON]

    init(returns: [JSON]) {
        self.returns = returns
    }

    var body: some View {
        if !returns.isEmpty {
            Section("Возвраты") {
                ForEach(returns, id: \.stableID) { r in
                    NavigationLink(destination: ReturnDetailView(id: r.id ?? 0)) {
                        OrdersReturnLine(ret: r)
                    }
                }
            }
        }
    }
}

/// Строка возврата в карточке заказа.
struct OrdersReturnLine: View {
    let ret: JSON

    init(ret: JSON) {
        self.ret = ret
    }

    private var subtitle: String {
        let type = ReturnsLabels.type(ret["type"].string)
        let reason = ReturnsLabels.reason(ret["reason_code"].string)
        let date = Fmt.date(ret["created_at"])
        return [type, reason, date].joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Возврат #" + ret["id"].stringValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(ret["refund_amount"])
                    .font(.subheadline)
            }
            HStack {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ReturnsStatusBadge(status: ret["status"].string)
            }
        }
    }
}
