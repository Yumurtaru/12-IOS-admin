import SwiftUI

/// Вкладка «Финансы»: сводка площадки за период (GET /api/admin/finance?from=&to=)
/// и досписание сборов (POST /api/admin/finance/backfill-charges).
///
/// На сайте отдельной страницы «Финансы» нет — сводку читает только API, а
/// досписание стоит в «Отчётах». Здесь — и то и другое, плюс выгрузка CSV.
struct WalletsFinanceView: View {
    @ObservedObject var loader: ObjectLoader
    @Binding var from: Date
    @Binding var to: Date

    @State private var shared: SharedFile?
    @State private var exportError: String?
    @State private var reloading = false

    init(loader: ObjectLoader, from: Binding<Date>, to: Binding<Date>) {
        self.loader = loader
        self._from = from
        self._to = to
    }

    private var d: JSON { loader.data }
    private var periodValid: Bool { Fmt.ymd(from) <= Fmt.ymd(to) }

    var body: some View {
        List {
            periodSection
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await apply() } })
                    .listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.insetGrouped)
        .refreshable { await apply() }
        .task { await loader.loadIfNeeded() }
        .onChange(of: from) { _ in Task { await apply() } }
        .onChange(of: to) { _ in Task { await apply() } }
        .sheet(item: $shared) { f in
            ShareSheet(items: [f.url])
        }
        .alert("Не получилось", isPresented: exportErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var exportErrorShown: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private func apply() async {
        guard periodValid else { return }
        loader.query = ["from": Fmt.ymd(from), "to": Fmt.ymd(to)]
        reloading = true
        await loader.load()
        reloading = false
    }

    private var periodSection: some View {
        Section {
            FormDateField("С", date: $from)
            FormDateField("По", date: $to)
            if !periodValid {
                Text("Дата «С» позже даты «По»").font(.footnote).foregroundColor(Brand.red)
            }
        } header: {
            HStack {
                Text("Период")
                if reloading { ProgressView().scaleEffect(0.7) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 30)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await apply() })
                .frame(minHeight: 220)
        case .empty:
            EmptyStateView(title: "Нет данных", systemImage: "tray")
        case .loaded:
            loadedSections
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        if let f = d["from"].nonEmptyString, let t = d["to"].nonEmptyString {
            Section {
                Text("Данные за " + Fmt.day(f) + " — " + Fmt.day(t))
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
        }
        ordersSection
        chargedSection
        moneySection
        shopsSection
        Section {
            ReportsBackfillButton {
                await apply()
            }
        } header: {
            Text("Обслуживание")
        } footer: {
            Text("Списать сборы и комиссии по выполненным заказам, по которым списания ещё не было. По уже списанным повторно не спишет.")
        }
        Section {
            JSONInspectorView(d)
        }
    }

    private var ordersSection: some View {
        let o = d["orders"]
        return Section("Заказы за период (без отменённых)") {
            KVRow("Заказов", Fmt.number(o["cnt"]))
            KVRow("Оборот", json: o["gmv"], money: true)
            KVRow("Комиссия по заказам", json: o["commission"], money: true)
            KVRow("Сервисный сбор по заказам", json: o["service_fee"], money: true)
        }
    }

    private var chargedSection: some View {
        Section {
            KVRow("Комиссия", json: d["commission_charged"], money: true)
            KVRow("Сервисный сбор", json: d["service_fee_charged"], money: true)
            if (d["subscription"].decimal ?? 0) != 0 {
                KVRow("Абонплата", json: d["subscription"], money: true)
            }
            KVRow("Возвращено продавцам", json: d["refunded"], money: true)
        } header: {
            Text("Списано с кошельков магазинов")
        } footer: {
            Text("Фактические проводки кошельков за период. «Возвращено» — комиссия и сбор, вернувшиеся продавцам при возвратах.")
        }
    }

    private var moneySection: some View {
        let tu = d["topups"]
        let tc = d["topups_users"]
        let po = d["payouts"]
        return Section {
            KVRow("Пополнения магазинов", WalletsFinanceView.countMoney(tu))
            KVRow("Пополнения клиентов", WalletsFinanceView.countMoney(tc))
            KVRow("Выплаты магазинам", WalletsFinanceView.countMoney(po))
            HStack {
                Text("Долг магазинов площадке").foregroundColor(Brand.muted)
                Spacer()
                MoneyText(d["debt"]).font(.subheadline.weight(.semibold))
            }
            .font(.subheadline)
        } header: {
            Text("Деньги")
        } footer: {
            Text("Пополнения — по дате зачисления, за вычетом возвратов. Долг — сумма отрицательных балансов на сейчас.")
        }
    }

    static func countMoney(_ j: JSON) -> String {
        Fmt.money(j["amount"]) + " · " + Fmt.plural(j["cnt"].intValue, "операция", "операции", "операций")
    }

    @ViewBuilder
    private var shopsSection: some View {
        let shops = d["shops"].array
        Section {
            if shops.isEmpty {
                Text("Нет магазинов с оборотом").foregroundColor(Brand.muted)
            } else {
                Button {
                    export(shops)
                } label: {
                    Label("Выгрузить CSV", systemImage: "square.and.arrow.up")
                }
                ForEach(shops, id: \.stableID) { s in
                    NavigationLink(destination: ShopDetailView(id: s.id ?? 0)) {
                        WalletsFinanceShopRow(item: s)
                    }
                }
            }
        } header: {
            Text("По магазинам (" + String(shops.count) + ")")
        } footer: {
            Text("«Начислено» — по заказам, «списано» — фактически с кошелька; итоги выше сходятся со списанным.")
        }
    }

    private func export(_ shops: [JSON]) {
        let header = ["Магазин", "Заказов", "Оборот", "Комиссия начислено", "Сбор начислено",
                      "Комиссия списано", "Сбор списано", "Баланс"]
        var rows: [[String]] = []
        for s in shops {
            rows.append([
                s["name"].stringValue, s["orders"].stringValue,
                ReportsCSV.amount(s["gmv"]), ReportsCSV.amount(s["commission_accrued"]),
                ReportsCSV.amount(s["fee_accrued"]), ReportsCSV.amount(s["commission"]),
                ReportsCSV.amount(s["service_fee"]), ReportsCSV.amount(s["balance"]),
            ])
        }
        let base = "finance_" + Fmt.ymd(from) + "_" + Fmt.ymd(to)
        do {
            let url = try ReportsCSV.write(name: base, header: header, rows: rows)
            shared = SharedFile(url: url)
        } catch {
            exportError = "Не удалось сохранить файл: " + error.localizedDescription
        }
    }
}

/// Строка магазина в «Финансах».
struct WalletsFinanceShopRow: View {
    let item: JSON

    init(item: JSON) { self.item = item }

    private var accrued: String {
        "начислено: комиссия " + Fmt.money(item["commission_accrued"]) + ", сбор " + Fmt.money(item["fee_accrued"])
    }

    private var charged: String {
        "списано: комиссия " + Fmt.money(item["commission"]) + ", сбор " + Fmt.money(item["service_fee"])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["name"].stringValue).font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(item["balance"]).font(.subheadline)
            }
            Text(Fmt.plural(item["orders"].intValue, "заказ", "заказа", "заказов") + " · оборот " + Fmt.money(item["gmv"]))
                .font(.caption)
            Text(accrued).font(.caption2).foregroundColor(Brand.muted)
            Text(charged).font(.caption2).foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }
}
