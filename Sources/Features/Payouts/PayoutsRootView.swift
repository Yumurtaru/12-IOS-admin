import SwiftUI

/// Раздел «Выплаты» — реестр выплат магазинам (как /admin/payouts сайта).
///
///  * GET  /api/admin/payouts?page=&q=&from=&to= — список, «Выплачено всего», «Записей»;
///  * POST /api/admin/payouts {shop_id, amount, method, comment} — записать выплату
///    (магазин из GET /api/admin/shops/options);
///  * POST /api/admin/payouts/{id}/cancel — отменить ошибочную запись (→ pending);
///  * POST /api/admin/payouts/{id}/paid — вернуть отменённую в «выплачено».
///
/// `openId` — номер выплаты: подставляется в поиск (сервер ищет и по номеру).
struct PayoutsRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/payouts", searchParam: "q")
    @State private var showCreate = false
    @State private var period: PayoutsPeriod = .all
    @State private var deepLinkApplied = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Выплаты", model: model, searchPrompt: "Магазин, комментарий или №",
                        emptyText: "Выплат пока нет", header: AnyView(PayoutsHeader(model: model, period: period)),
                        row: { item in
                            PayoutsRow(item: item) {
                                await model.refresh()
                            }
                        })
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                periodMenu
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Записать выплату")
            }
        }
        .sheet(isPresented: $showCreate) {
            PayoutsCreateSheet {
                await model.refresh()
            }
        }
        .task {
            guard !deepLinkApplied else { return }
            deepLinkApplied = true
            if let id = openId { model.searchText = String(id) }
        }
    }

    private var periodMenu: some View {
        Menu {
            ForEach(PayoutsPeriod.allCases) { p in
                Button {
                    apply(p)
                } label: {
                    if p == period { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
        } label: {
            Image(systemName: period == .all ? "calendar" : "calendar.badge.clock")
        }
        .accessibilityLabel("Период")
    }

    private func apply(_ p: PayoutsPeriod) {
        Haptics.tap()
        period = p
        let range = p.range()
        model.setFilter("from", range.map { Fmt.ymd($0.from) })
        model.setFilter("to", range.map { Fmt.ymd($0.to) })
    }
}

/// Период списка выплат (сервер принимает from/to в формате Y-m-d).
enum PayoutsPeriod: String, CaseIterable, Identifiable {
    case all, thisMonth, lastMonth, last30, thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "За всё время"
        case .thisMonth: return "Этот месяц"
        case .lastMonth: return "Прошлый месяц"
        case .last30: return "Последние 30 дней"
        case .thisYear: return "Этот год"
        }
    }

    /// Границы по Москве; nil — без ограничения.
    func range(now: Date = Date()) -> (from: Date, to: Date)? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Fmt.moscow
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        switch self {
        case .all:
            return nil
        case .thisMonth:
            return (monthStart, now)
        case .lastMonth:
            let prevStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
            let prevEnd = cal.date(byAdding: .day, value: -1, to: monthStart) ?? monthStart
            return (prevStart, prevEnd)
        case .last30:
            let start = cal.date(byAdding: .day, value: -29, to: now) ?? now
            return (start, now)
        case .thisYear:
            let yearStart = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            return (yearStart, now)
        }
    }
}

/// Сводка над списком: «Выплачено всего», «Записей», реестр не активирован.
struct PayoutsHeader: View {
    @ObservedObject var model: PagedListModel
    let period: PayoutsPeriod

    init(model: PagedListModel, period: PayoutsPeriod) {
        self.model = model
        self.period = period
    }

    var body: some View {
        let d = model.lastData
        VStack(alignment: .leading, spacing: 8) {
            if d["enabled"].bool == false {
                InfoBanner("Реестр выплат не активирован — примените миграцию 2026_06_admin_payouts.sql.",
                           systemImage: "exclamationmark.triangle", color: Brand.amber)
            } else if d.isObject {
                HStack(alignment: .top, spacing: 12) {
                    PayoutsStat(title: "Выплачено всего", value: Fmt.money(d["total_paid"]))
                    PayoutsStat(title: "Записей", value: Fmt.number(d["total"]))
                }
            }
            if period != .all {
                Text("Период: " + period.title.lowercased())
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
        .listRowSeparator(.hidden)
    }
}

/// Плитка сводки.
struct PayoutsStat: View {
    let title: String
    let value: String

    init(title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(Brand.muted)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Подписи способов выплаты (как MET на сайте).
enum PayoutsMethod {
    static let options: [PickerOption] = [
        PickerOption(value: "bank", label: "Банк"),
        PickerOption(value: "card", label: "Карта"),
        PickerOption(value: "cash", label: "Наличные"),
        PickerOption(value: "other", label: "Другое"),
    ]

    static func label(_ code: String?) -> String {
        let c = code ?? ""
        return options.first { $0.value == c }?.label ?? (c.isEmpty ? "—" : c)
    }
}

/// Строка выплаты: данные + «Отменить запись» / «Вернуть в выплачено».
struct PayoutsRow: View {
    let item: JSON
    let onChanged: () async -> Void

    init(item: JSON, onChanged: @escaping () async -> Void) {
        self.item = item
        self.onChanged = onChanged
    }

    private var isPaid: Bool { item["status"].string == "paid" }
    private var shop: String { item["shop"].nonEmptyString ?? "магазин удалён" }
    private var amountText: String { Fmt.money(item["amount"]) }

    private var cancelConfirm: ConfirmAction {
        ConfirmAction(title: "Отменить запись о выплате " + amountText + " магазину «" + shop + "»?",
                      message: "Реальный перевод это не отменяет — только запись в реестре. Сумма перестанет входить в «Выплачено всего».",
                      confirmLabel: "Отменить запись", destructive: true)
    }

    private var restoreConfirm: ConfirmAction {
        ConfirmAction(title: "Вернуть выплату " + amountText + " магазину «" + shop + "» в «выплачено»?",
                      message: "Сумма снова войдёт в «Выплачено всего».",
                      confirmLabel: "Вернуть")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("№" + String(item.id ?? 0)).font(.caption).foregroundColor(Brand.muted)
                Text(shop).font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(item["amount"]).font(.headline)
            }
            HStack(spacing: 6) {
                if isPaid {
                    StatusBadge("Выплачено", color: Brand.green)
                } else {
                    StatusBadge("Отменена", color: Brand.amber)
                }
                Text(PayoutsMethod.label(item["method"].string) + " · " + Fmt.date(item["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let c = item["comment"].nonEmptyString {
                Text(c).font(.caption)
            }
            if let a = item["author"].nonEmptyString {
                Text("Записал: " + a).font(.caption2).foregroundColor(Brand.muted)
            }
            actionButton
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var actionButton: some View {
        let id = item.id ?? 0
        if isPaid {
            ActionButton("Отменить запись", systemImage: "arrow.uturn.backward", role: .destructive,
                         style: .bordered, confirm: cancelConfirm) {
                try await API.shared.post("/api/admin/payouts/\(id)/cancel")
                await onChanged()
            }
        } else {
            ActionButton("Вернуть в «выплачено»", systemImage: "checkmark.circle", style: .bordered,
                         confirm: restoreConfirm) {
                try await API.shared.post("/api/admin/payouts/\(id)/paid")
                await onChanged()
            }
        }
    }
}

/// Лист «Записать выплату»: магазин, сумма, способ, комментарий → подтверждение с суммой.
struct PayoutsCreateSheet: View {
    let onCreated: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var shops: [JSON] = []
    @State private var shopsState: LoadState = .idle
    @State private var shopId: Int?
    @State private var shopName = ""
    @State private var amountText = ""
    @State private var method = "bank"
    @State private var comment = ""
    @State private var askConfirm = false
    @State private var busy = false
    @State private var error: String?

    init(onCreated: @escaping () async -> Void) {
        self.onCreated = onCreated
    }

    private var amount: Decimal? {
        Fmt.parseDecimal(amountText.trimmingCharacters(in: .whitespaces))
    }

    /// Предел колонки DECIMAL(12,2) на сервере.
    private static let maxAmount = Decimal(string: "9999999999.99", locale: Locale(identifier: "en_US_POSIX")) ?? 0

    /// Что мешает записать (nil — можно).
    private var problem: String? {
        if shopId == nil { return "Выберите магазин" }
        let t = amountText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Укажите сумму" }
        guard let a = amount else { return "Сумма — число, не больше двух знаков после запятой" }
        if a <= 0 { return "Сумма должна быть больше нуля" }
        if a > PayoutsCreateSheet.maxAmount {
            return "Сумма выплаты слишком велика"
        }
        return nil
    }

    private var trimmedComment: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var confirmTitle: String {
        let sum = Fmt.money(amount)
        return "Записать выплату " + sum + " магазину «" + shopName + "»?"
    }

    private var confirmMessage: String {
        var s = "Способ: " + PayoutsMethod.label(method) + "."
        if !trimmedComment.isEmpty { s += " Комментарий: " + trimmedComment + "." }
        s += " Деньги приложение не переводит — это запись в реестре о сделанной выплате."
        return s
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Магазин") {
                    shopField
                }
                Section {
                    FormDecimalField("Сумма", text: $amountText)
                    FormPicker("Способ", selection: $method, options: PayoutsMethod.options)
                    FormTextField("Комментарий", text: $comment, prompt: "№ платёжки, период…")
                }
                if let p = problem, shopId != nil || !amountText.isEmpty {
                    Section {
                        Text(p).font(.footnote).foregroundColor(Brand.red)
                    }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button {
                        Haptics.tap()
                        askConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Записать выплату").bold() }
                            Spacer()
                        }
                    }
                    .disabled(problem != nil || busy)
                }
            }
            .navigationTitle("Выплата магазину")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
            .confirmationDialog(confirmTitle, isPresented: $askConfirm, titleVisibility: .visible) {
                Button("Записать " + Fmt.money(amount)) { submit() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
            .task { await loadShopsIfNeeded() }
        }
        .interactiveDismissDisabled(busy)
    }

    @ViewBuilder
    private var shopField: some View {
        switch shopsState {
        case .idle, .loading:
            HStack { ProgressView(); Text("Загружаю магазины…").foregroundColor(Brand.muted) }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(.footnote).foregroundColor(Brand.red)
                Button("Повторить") { Task { await loadShops() } }
            }
        case .empty:
            Text("Нет доступных магазинов").foregroundColor(Brand.muted)
        case .loaded:
            NavigationLink(destination: picker) {
                HStack {
                    Text(shopId == nil ? "Выберите магазин" : shopName)
                        .foregroundColor(shopId == nil ? Brand.muted : Brand.text)
                    Spacer()
                }
            }
        }
    }

    private var picker: some View {
        PayoutsShopPicker(shops: shops, selectedId: shopId) { id, name in
            shopId = id
            shopName = name
        }
    }

    private func loadShopsIfNeeded() async {
        if shopsState == .idle { await loadShops() }
    }

    private func loadShops() async {
        shopsState = .loading
        do {
            let r = try await API.shared.get("/api/admin/shops/options")
            let list = r.isArray ? r.array : r["items"].array
            shops = list.filter { ($0.id ?? 0) > 0 }
            shopsState = shops.isEmpty ? .empty(nil) : .loaded
        } catch {
            if !APIError.isCancellation(error) {
                shopsState = .failed(APIError.describe(error))
            }
        }
    }

    private func submit() {
        guard problem == nil, !busy, let sid = shopId, let value = amount else { return }
        let m = method
        let c = trimmedComment
        let done = onCreated
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await API.shared.post("/api/admin/payouts",
                                          body: ["shop_id": sid, "amount": value, "method": m, "comment": c])
                Haptics.success()
                busy = false
                await done()
                dismiss()
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
        }
    }
}

/// Выбор магазина из GET /api/admin/shops/options (до 1000, без заблокированных) с поиском.
struct PayoutsShopPicker: View {
    let shops: [JSON]
    let selectedId: Int?
    let onPick: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    init(shops: [JSON], selectedId: Int?, onPick: @escaping (Int, String) -> Void) {
        self.shops = shops
        self.selectedId = selectedId
        self.onPick = onPick
    }

    private var filtered: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return shops }
        return shops.filter { s in
            s["name"].stringValue.lowercased().contains(q) || String(s.id ?? 0) == q
        }
    }

    var body: some View {
        List {
            ForEach(filtered, id: \.stableID) { s in
                Button {
                    Haptics.tap()
                    onPick(s.id ?? 0, s["name"].stringValue)
                    dismiss()
                } label: {
                    HStack {
                        Text(s["name"].stringValue).foregroundColor(Brand.text)
                        Spacer()
                        if s.id == selectedId {
                            Image(systemName: "checkmark").foregroundColor(Brand.accent)
                        }
                    }
                }
            }
            if filtered.isEmpty {
                Text("Ничего не найдено").foregroundColor(Brand.muted)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название магазина")
        .navigationTitle("Магазин")
        .navigationBarTitleDisplayMode(.inline)
    }
}
