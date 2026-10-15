import SwiftUI

/// Карточка пользователя (как userCard в admin.js): контакты, статус, роли,
/// показатели заказов, бонусы, кошелёк клиента, магазины во владении,
/// последние заказы, блокировка/разблокировка с причиной.
///
/// GET  /api/admin/users/{id}        → id, name, phone, email, account_type, status, bonus_balance,
///                                     created_at, orders[], is_admin, roles[], shops[], order_stats, block_reason
/// POST /api/admin/users/{id}/block  {reason} — заблокировать; {unblock: true} — разблокировать.
/// Администратора (и себя) сервер заблокировать не даёт — кнопку не показываем, как сайт.
struct UserDetailView: View {
    let id: Int
    /// Вызывается после блокировки/разблокировки — список обновит строку.
    let onChanged: (() -> Void)?

    @StateObject private var loader: ObjectLoader
    @State private var askBlockReason = false

    init(id: Int, onChanged: (() -> Void)? = nil) {
        self.id = id
        self.onChanged = onChanged
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/users/" + String(id)))
    }

    private var user: JSON { loader.data }
    private var isBlocked: Bool { user["status"].string == "blocked" }

    private var screenTitle: String {
        user["name"].nonEmptyString ?? ("Пользователь #" + String(id))
    }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Пользователь не найден", retry: { await loader.load() }) {
            content
        }
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
        .sheet(isPresented: $askBlockReason) {
            TextInputSheet(title: "Заблокировать",
                           message: "Причина блокировки (необязательно). Пользователь не сможет войти и оформлять заказы.",
                           placeholder: "нарушение правил…", multiline: true,
                           submitTitle: "Заблокировать", minLength: 0, destructive: true) { text in
                try await block(reason: text)
            }
        }
    }

    private var content: some View {
        List {
            if let err = loader.lastRefreshError {
                ErrorBanner(message: err, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            UsersHeaderSection(user: user)
            if isBlocked, let reason = user["block_reason"].nonEmptyString {
                Section {
                    InfoBanner("Причина блокировки: " + reason, systemImage: "hand.raised.fill", color: Brand.red)
                }
            }
            UsersRolesSection(roles: user["roles"].array)
            statsSection
            UsersWalletSection(userId: id)
            UsersShopsSection(shops: user["shops"].array)
            UsersOrdersSection(orders: user["orders"].array)
            actionsSection
            Section {
                JSONInspectorView(user)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    private var statsSection: some View {
        let stats = user["order_stats"]
        return Section("Показатели") {
            KVRow("Заказов (без отменённых)", Fmt.number(stats["count"]))
            KVRow("Сумма заказов", json: stats["total"], money: true)
            KVRow("Последний заказ", Fmt.date(stats["last"]))
            KVRow("Бонусы", json: user["bonus_balance"], money: true)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if user["is_admin"].boolValue {
                Text("Администратор — блокировка недоступна")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            } else if isBlocked {
                ActionButton("Разблокировать", systemImage: "lock.open", style: .prominent,
                             confirm: ConfirmAction(title: "Разблокировать пользователя?",
                                                    message: "Он снова сможет входить и оформлять заказы.",
                                                    confirmLabel: "Разблокировать"),
                             successMessage: "Разблокирован", fullWidth: true) {
                    try await unblock()
                }
            } else {
                Button(role: .destructive) {
                    askBlockReason = true
                } label: {
                    Label("Заблокировать", systemImage: "hand.raised")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Доступ")
        }
    }

    // MARK: - Действия

    private func block(reason: String) async throws {
        let path = "/api/admin/users/" + String(id) + "/block"
        try await API.shared.post(path, body: ["reason": reason])
        await afterChange()
    }

    private func unblock() async throws {
        let path = "/api/admin/users/" + String(id) + "/block"
        try await API.shared.post(path, body: ["unblock": true])
        await afterChange()
    }

    private func afterChange() async {
        await loader.load()
        onChanged?()
    }
}

/// Шапка карточки: имя, контакты (звонок/почта), статус, тип, дата регистрации.
struct UsersHeaderSection: View {
    let user: JSON

    init(user: JSON) {
        self.user = user
    }

    private var subtitle: String {
        let type = UsersLabels.accountType(user["account_type"].string)
        let since = user["created_at"].nonEmptyString.map { " · с " + Fmt.day($0) } ?? ""
        return type + since
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(user["name"].nonEmptyString ?? "Без имени")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    StatusBadge(status: user["status"].string, label: UsersLabels.status(user["status"].string))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                }
            }
            .padding(.vertical, 4)
            phoneRow
            emailRow
            KVRow("ID", user["id"].string, copyable: true)
        }
    }

    @ViewBuilder
    private var phoneRow: some View {
        let phone = user["phone"].nonEmptyString
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) {
                Label(Fmt.phone(phone), systemImage: "phone")
            }
        } else {
            KVRow("Телефон", phone)
        }
    }

    @ViewBuilder
    private var emailRow: some View {
        if let email = user["email"].nonEmptyString {
            if let url = URL(string: "mailto:" + email) {
                Link(destination: url) {
                    Label(email, systemImage: "envelope")
                }
            } else {
                KVRow("Почта", email, copyable: true)
            }
        }
    }
}

/// Роли пользователя: «Продавец: Пекарня» и т.п. (роль в магазине ведёт в магазин).
struct UsersRolesSection: View {
    let roles: [JSON]

    init(roles: [JSON]) {
        self.roles = roles
    }

    var body: some View {
        Section("Роли") {
            if roles.isEmpty {
                Text("Только клиент")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(Array(roles.enumerated()), id: \.offset) { pair in
                    roleRow(pair.element)
                }
            }
        }
    }

    private func roleText(_ r: JSON) -> String {
        let label = UsersLabels.role(r["slug"].string, name: r["name"].string)
        guard let shop = r["shop"].nonEmptyString else { return label }
        return label + ": " + shop
    }

    @ViewBuilder
    private func roleRow(_ r: JSON) -> some View {
        if let shopId = r["shop_id"].int, shopId > 0 {
            NavigationLink(destination: ShopDetailView(id: shopId)) {
                Label(roleText(r), systemImage: "person.badge.key")
            }
        } else {
            Label(roleText(r), systemImage: "person.badge.key")
        }
    }
}

/// Магазины во владении — со ссылкой на карточку магазина.
struct UsersShopsSection: View {
    let shops: [JSON]

    init(shops: [JSON]) {
        self.shops = shops
    }

    var body: some View {
        if !shops.isEmpty {
            Section("Магазины во владении") {
                ForEach(shops, id: \.stableID) { shop in
                    NavigationLink(destination: ShopDetailView(id: shop.id ?? 0)) {
                        HStack {
                            Text(shop["name"].nonEmptyString ?? ("Магазин #" + shop["id"].stringValue))
                                .lineLimit(1)
                            Spacer()
                            StatusBadge(status: shop["status"].string)
                        }
                    }
                }
            }
        }
    }
}

/// Последние заказы пользователя (до 50) — со ссылкой на карточку заказа.
struct UsersOrdersSection: View {
    let orders: [JSON]

    init(orders: [JSON]) {
        self.orders = orders
    }

    var body: some View {
        Section {
            if orders.isEmpty {
                Text("Нет заказов")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(orders, id: \.stableID) { order in
                    NavigationLink(destination: OrderDetailView(id: order.id ?? 0)) {
                        UsersOrderLine(order: order)
                    }
                }
            }
        } header: {
            Text("Последние заказы")
        }
    }
}

/// Строка заказа в карточке пользователя.
struct UsersOrderLine: View {
    let order: JSON

    init(order: JSON) {
        self.order = order
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("#" + order["id"].stringValue)
                    .font(.subheadline.weight(.semibold))
                Text(Fmt.date(order["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(order["total"])
                    .font(.subheadline)
                StatusBadge(status: order["status"].string)
            }
        }
    }
}

/// Кошелёк клиента — только просмотр (GET /api/admin/user-wallets/{id}: тот же id
/// пользователя). Корректировки баланса — в разделе «Кошельки», как на сайте.
struct UsersWalletSection: View {
    let userId: Int
    @StateObject private var loader: ObjectLoader

    init(userId: Int) {
        self.userId = userId
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/user-wallets/" + String(userId)))
    }

    private var recent: [JSON] {
        Array(loader.data["transactions"].array.prefix(5))
    }

    private var pendingTopups: Int {
        loader.data["topups"].array.filter { $0["status"].string == "pending" }.count
    }

    var body: some View {
        Section {
            stateContent
        } header: {
            Text("Кошелёк клиента")
        } footer: {
            Text("Изменить баланс можно в разделе «Кошельки».")
        }
        .task { await loader.loadIfNeeded() }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch loader.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
        case .failed(let msg):
            HStack {
                Text(msg)
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                Spacer()
                Button("Повторить") { Task { await loader.load() } }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        case .empty:
            Text("Нет данных").font(.footnote).foregroundColor(Brand.muted)
        case .loaded:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        KVRow("Баланс", json: loader.data["user"]["balance"], money: true)
        if pendingTopups > 0 {
            KVRow("Пополнения ждут оплаты", String(pendingTopups))
        }
        if recent.isEmpty {
            Text("Операций нет").font(.footnote).foregroundColor(Brand.muted)
        } else {
            ForEach(recent, id: \.stableID) { tx in
                UsersWalletTxLine(tx: tx)
            }
        }
    }
}

/// Операция кошелька клиента.
struct UsersWalletTxLine: View {
    let tx: JSON

    init(tx: JSON) {
        self.tx = tx
    }

    private var amount: Decimal { tx["amount"].decimal ?? 0 }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tx["type_label"].nonEmptyString ?? tx["type"].stringValue)
                    .font(.subheadline)
                if let d = tx["description"].nonEmptyString {
                    Text(d).font(.caption).foregroundColor(Brand.muted).lineLimit(2)
                }
                Text(Fmt.date(tx["created_at"]))
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
            Spacer()
            Text(Fmt.moneySigned(amount))
                .font(.subheadline.monospacedDigit())
                .foregroundColor(amount < 0 ? Brand.red : Brand.green)
        }
    }
}
