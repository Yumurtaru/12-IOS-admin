import SwiftUI

/// Раздел «Рефералы»: долг площадки магазинам за потраченные реферальные баллы
/// (как /admin/referrals сайта).
///
///  * GET  /api/admin/referral-debt[?shop_id=] — сводка, магазины, строки и отметки магазина;
///  * POST /api/admin/referral-debt/settle {shop_id} — отметить долг возмещённым
///    (деньги не двигаются — только отметка в реестре);
///  * POST /api/admin/referral-debt/unsettle {shop_id, settled_at} — снять отметку.
///
/// `openId` — id магазина: сразу открывается его карточка долга.
struct ReferralsRootView: View {
    let openId: Int?

    @StateObject private var loader = ObjectLoader(path: "/api/admin/referral-debt")
    @State private var deepLinkShown: Bool
    @State private var settleShop: JSON?
    @State private var pending: ConfirmAction?
    @State private var notice: String?

    init(openId: Int? = nil) {
        self.openId = openId
        _deepLinkShown = State(initialValue: openId != nil)
    }

    private var d: JSON { loader.data }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            list
        }
        .navigationTitle("Рефералы")
        .task { await loader.loadIfNeeded() }
        .navigationDestination(isPresented: $deepLinkShown) {
            ReferralsShopView(shopId: openId ?? 0, shopName: nil) {
                await loader.load()
            }
        }
        .confirmAction($pending) {
            try await settle()
        }
        .alert(notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private var list: some View {
        List {
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            if d["enabled"].bool == false {
                Section {
                    InfoBanner("Реестр появится после первого реферального бонуса — до этого считать нечего.")
                }
            } else {
                statsSection
                shopsSection
            }
            Section {
                ReferralsExplain()
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    private var statsSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                ReferralsStat(title: "Долг сейчас", value: Fmt.money(d["total_debt"]), strong: true)
                ReferralsStat(title: "Возможный долг", value: Fmt.money(d["total_pending"]), strong: false)
                ReferralsStat(title: "Возмещено", value: Fmt.money(d["total_settled"]), strong: false)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var shopsSection: some View {
        let items = d["items"].array
        Section {
            if items.isEmpty {
                Text("Реферальных бонусов ещё не начисляли").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.self) { x in
                    NavigationLink(destination: ReferralsShopView(shopId: x["shop_id"].intValue,
                                                                  shopName: x["shop"].string,
                                                                  onChanged: { await loader.load() })) {
                        ReferralsShopRow(item: x)
                    }
                    .swipeActions(edge: .trailing) {
                        if (x["debt"].decimal ?? 0) > 0 {
                            Button("Возместить") {
                                askSettle(x)
                            }
                            .tint(Brand.green)
                        }
                    }
                }
            }
        } header: {
            Text("По магазинам")
        } footer: {
            Text(sinceText)
        }
    }

    private var sinceText: String {
        var s = "Реестр ведётся с момента обновления"
        if let since = d["since"].nonEmptyString { s += " (первая запись " + Fmt.date(since) + ")" }
        return s + ": бонусы, выданные раньше, в нём не учтены. Смахните строку влево, чтобы отметить долг возмещённым."
    }

    private func askSettle(_ x: JSON) {
        settleShop = x
        pending = ReferralsSettle.confirm(shop: x["shop"].stringValue, debt: x["debt"].decimal)
    }

    private func settle() async throws {
        guard let x = settleShop else { return }
        let text = try await ReferralsSettle.run(shopId: x["shop_id"].intValue, shown: x["debt"].decimal)
        notice = text
        await loader.load()
    }
}

/// Отметка «возмещено»: подтверждение и запрос — общие для списка и карточки.
enum ReferralsSettle {
    static func confirm(shop: String, debt: Decimal?) -> ConfirmAction {
        ConfirmAction(title: "Отметить " + Fmt.money(debt) + " как возмещённые магазину «" + shop + "»?",
                      message: "Деньги это не переводит — только отметка в реестре. Перевод делайте как обычно (раздел «Выплаты»).",
                      confirmLabel: "Отметить возмещённым")
    }

    /// POST settle; возвращает текст итога. Если сервер отметил другую сумму (за это
    /// время клиент потратил ещё баллы) — говорит об этом.
    static func run(shopId: Int, shown: Decimal?) async throws -> String {
        let r = try await API.shared.post("/api/admin/referral-debt/settle", body: ["shop_id": shopId])
        let settled = r["settled"].decimal
        var text = "Отмечено возмещённым: " + Fmt.money(settled)
        if let s = settled, let w = shown, s != w {
            text += " (на экране было " + Fmt.money(w) + " — за это время добавились записи)"
        }
        return text
    }
}

/// Плитка сводки.
struct ReferralsStat: View {
    let title: String
    let value: String
    let strong: Bool

    init(title: String, value: String, strong: Bool) {
        self.title = title
        self.value = value
        self.strong = strong
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(Brand.muted)
            Text(value)
                .font(strong ? .headline : .subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Строка магазина: долг, возможный долг, записей, последняя, возмещено.
struct ReferralsShopRow: View {
    let item: JSON

    init(item: JSON) { self.item = item }

    private var details: String {
        var s = "возможный " + Fmt.money(item["pending"]) + " · возмещено " + Fmt.money(item["settled"])
        s += " · " + Fmt.plural(item["cnt"].intValue, "запись", "записи", "записей")
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["shop"].stringValue).font(.subheadline.weight(.semibold))
                Spacer()
                Text(Fmt.money(item["debt"]))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundColor((item["debt"].decimal ?? 0) > 0 ? Brand.red : Brand.text)
            }
            Text(details).font(.caption).foregroundColor(Brand.muted)
            if let last = item["last_at"].nonEmptyString {
                Text("Последняя: " + Fmt.date(last)).font(.caption2).foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Пояснение, как считается долг (текст с сайта).
struct ReferralsExplain: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Реферальный бонус начисляется баллами того заведения, где прошёл первый заказ приглашённого, и тратится тоже в нём. Когда человек платит этими баллами, недополучает деньги заведение — здесь видно, сколько ему возместить.")
            Text("Долг — реферальные баллы, уже потраченные в магазине. Возможный долг — начислено, но пока не потрачено. «Отметить возмещённым» — только отметка в реестре, деньги не двигаются.")
            Text("Баллы обезличены: реферальные тратятся первыми, больше начисленного по рефералам в долг не попадёт. Сгоревшие по сроку или снятые продавцом баллы долгом не становятся.")
        }
        .font(.footnote)
        .foregroundColor(Brand.muted)
    }
}

/// Карточка долга одного магазина: строки, отметки о возмещении, «Отметить», «Снять отметку».
struct ReferralsShopView: View {
    let shopId: Int
    let shopName: String?
    let onChanged: () async -> Void

    @StateObject private var loader: ObjectLoader
    @State private var pending: ConfirmAction?
    @State private var pendingBatch: JSON?
    @State private var notice: String?

    init(shopId: Int, shopName: String?, onChanged: @escaping () async -> Void) {
        self.shopId = shopId
        self.shopName = shopName
        self.onChanged = onChanged
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/referral-debt",
                                                         query: ["shop_id": String(shopId)]))
    }

    private var summary: JSON {
        loader.data["items"].array.first { $0["shop_id"].int == shopId } ?? .null
    }

    private var name: String {
        summary["shop"].nonEmptyString ?? shopName ?? ("Магазин #" + String(shopId))
    }

    private var debt: Decimal { summary["debt"].decimal ?? 0 }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            List {
                if let e = loader.lastRefreshError {
                    ErrorBanner(message: e, retry: { Task { await loader.load() } })
                        .listRowSeparator(.hidden)
                }
                summarySection
                rowsSection
                batchesSection
                Section {
                    JSONInspectorView(loader.data)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loader.load() }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
        .confirmAction($pending) {
            try await unsettle()
        }
        .alert(notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private func changed() async {
        await loader.load()
        await onChanged()
    }

    private var summarySection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                ReferralsStat(title: "Долг", value: Fmt.money(debt), strong: true)
                ReferralsStat(title: "Возможный долг", value: Fmt.money(summary["pending"]), strong: false)
                ReferralsStat(title: "Возмещено", value: Fmt.money(summary["settled"]), strong: false)
            }
            .padding(.vertical, 4)
            if debt > 0 {
                ActionButton("Отметить " + Fmt.money(debt) + " возмещёнными", systemImage: "checkmark.seal",
                             style: .prominent, confirm: ReferralsSettle.confirm(shop: name, debt: debt),
                             fullWidth: true) {
                    let text = try await ReferralsSettle.run(shopId: shopId, shown: debt)
                    notice = text
                    await changed()
                }
            }
            NavigationLink(destination: ShopDetailView(id: shopId)) {
                Label("Карточка магазина", systemImage: "storefront")
            }
        } footer: {
            Text("Деньги здесь не двигаются: перевод магазину делайте как обычно (раздел «Выплаты»).")
        }
    }

    @ViewBuilder
    private var rowsSection: some View {
        let rows = loader.data["rows"].array
        Section {
            if rows.isEmpty {
                Text("Записей нет").foregroundColor(Brand.muted)
            } else {
                ForEach(rows, id: \.stableID) { x in
                    rowView(x)
                }
            }
        } header: {
            Text("Записи (" + String(rows.count) + ")")
        } footer: {
            if rows.count >= 200 { Text("Показаны 200 последних.") }
        }
    }

    @ViewBuilder
    private func rowView(_ x: JSON) -> some View {
        if let oid = x["order_id"].int, oid > 0 {
            NavigationLink(destination: OrderDetailView(id: oid)) {
                ReferralsDebtRow(item: x)
            }
        } else {
            ReferralsDebtRow(item: x)
        }
    }

    @ViewBuilder
    private var batchesSection: some View {
        let batches = loader.data["batches"].array
        if !batches.isEmpty {
            Section {
                ForEach(batches, id: \.self) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.date(b["settled_at"])).font(.subheadline)
                            Text(Fmt.plural(b["cnt"].intValue, "запись", "записи", "записей"))
                                .font(.caption)
                                .foregroundColor(Brand.muted)
                        }
                        Spacer()
                        MoneyText(b["amount"]).font(.subheadline.weight(.semibold))
                        Button {
                            askUnsettle(b)
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Снять отметку")
                    }
                }
            } header: {
                Text("Отметки о возмещении")
            } footer: {
                Text("Ошибочную отметку можно снять — долг вернётся в список.")
            }
        }
    }

    private func askUnsettle(_ b: JSON) {
        pendingBatch = b
        let count = Fmt.plural(b["cnt"].intValue, "запись", "записи", "записей")
        let when = Fmt.date(b["settled_at"])
        let sum = Fmt.money(b["amount"])
        let msg = sum + " (" + count + ") вернутся в долг магазину «" + name + "»."
        pending = ConfirmAction(title: "Снять отметку о возмещении от " + when + "?",
                                message: msg,
                                confirmLabel: "Снять отметку", destructive: true)
    }

    private func unsettle() async throws {
        guard let b = pendingBatch, let stamp = b["settled_at"].nonEmptyString else { return }
        let r = try await API.shared.post("/api/admin/referral-debt/unsettle",
                                          body: ["shop_id": shopId, "settled_at": stamp])
        notice = "Отметка снята: " + Fmt.plural(r["restored"].intValue, "запись", "записи", "записей") + " снова в долге"
        await changed()
    }
}

/// Строка реестра: дата, клиент, заказ, сумма, когда возмещено.
struct ReferralsDebtRow: View {
    let item: JSON

    init(item: JSON) { self.item = item }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["client"].nonEmptyString ?? "—").font(.subheadline)
                Spacer()
                MoneyText(item["amount"]).font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(Fmt.date(item["created_at"]))
                if let o = item["order_id"].int, o > 0 {
                    Text("· заказ №" + String(o))
                }
                Spacer()
                if let s = item["settled_at"].nonEmptyString {
                    StatusBadge("возмещено " + Fmt.day(s), color: Brand.green)
                } else {
                    StatusBadge("долг", color: Brand.amber)
                }
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }
}
