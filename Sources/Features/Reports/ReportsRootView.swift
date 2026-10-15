import SwiftUI

/// Раздел «Отчёты» — финансовый отчёт площадки (GET /api/admin/reports?period=7days|30days|year),
/// как страница /admin/reports сайта: доход, пополнения по способам, отрицательные
/// балансы, комиссии по магазинам (+ выгрузка CSV, как кнопка ⬇ сайта), «Досписать сборы».
///
/// `openId` не используется: в отчёте нет отдельных объектов.
struct ReportsRootView: View {
    let openId: Int?

    @StateObject private var loader = ObjectLoader(path: "/api/admin/reports", query: ["period": "30days"])
    @State private var period = "30days"
    @State private var reloading = false
    @State private var shared: SharedFile?
    @State private var exportError: String?

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private static let periods: [PickerOption] = [
        PickerOption(value: "7days", label: "7 дней"),
        PickerOption(value: "30days", label: "30 дней"),
        PickerOption(value: "year", label: "Год"),
    ]

    private var d: JSON { loader.data }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            list
        }
        .navigationTitle("Отчёты")
        .task { await loader.loadIfNeeded() }
        .onChange(of: period) { p in
            Task { await reload(period: p) }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    exportCSV()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(d["commission_by_shop"].array.isEmpty)
                .accessibilityLabel("Выгрузить CSV")
            }
        }
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

    private func reload(period p: String) async {
        loader.query = ["period": p]
        reloading = true
        await loader.load()
        reloading = false
    }

    private var list: some View {
        List {
            Section {
                Picker("Период", selection: $period) {
                    ForEach(ReportsRootView.periods) { o in
                        Text(o.label).tag(o.value)
                    }
                }
                .pickerStyle(.segmented)
                if reloading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            incomeSection
            deletedSection
            topupsSection
            negativeSection
            byShopSection
            Section {
                ReportsBackfillButton {
                    await loader.load()
                }
            } header: {
                Text("Обслуживание")
            } footer: {
                Text("Списать сборы и комиссии по выполненным заказам, по которым списания ещё не было. По уже списанным повторно не спишет.")
            }
            if d.isObject {
                Section {
                    JSONInspectorView(d)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    // MARK: - Доход

    private var gross: Decimal {
        let a = d["service_fee_income"].decimal ?? 0
        let b = d["commission_income"].decimal ?? 0
        let c = d["subscription_income"].decimal ?? 0
        return a + b + c
    }

    /// Чистый доход: income_net сервера + подписки (как на сайте); nil — сервер не прислал.
    private var net: Decimal? {
        guard let n = d["income_net"].decimal else { return nil }
        return n + (d["subscription_income"].decimal ?? 0)
    }

    private var incomeSection: some View {
        let refunded = d["commission_refunded"].decimal ?? 0
        return Section {
            KVRow("Сервисные сборы", json: d["service_fee_income"], money: true)
            KVRow("Комиссии", json: d["commission_income"], money: true)
            KVRow("Подписки", json: d["subscription_income"], money: true)
            HStack {
                Text("Итого начислено").font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(value: gross).font(.headline)
            }
            if refunded > 0 {
                ReportsNoteRow(title: "Возвращено продавцам", value: Fmt.money(refunded),
                               note: "комиссия и сбор по возвратам товара за период")
                if let n = net {
                    ReportsNoteRow(title: "Чистый доход", value: Fmt.money(n),
                                   note: "начислено за период минус возвращённое продавцам по заказам, начисление по которым ещё в силе")
                }
            }
        } header: {
            Text("Доход площадки")
        }
    }

    @ViewBuilder
    private var deletedSection: some View {
        let del = d["deleted_shops"]
        let comm = del["commission"].decimal ?? 0
        if comm > 0 {
            Section {
                KVRow("Комиссия за всё время", Fmt.money(comm))
                ForEach(del["items"].array, id: \.self) { x in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(x["shop_name"].stringValue).font(.subheadline)
                            Spacer()
                            MoneyText(x["commission_total"]).font(.subheadline)
                        }
                        Text(ReportsRootView.deletedLine(x))
                            .font(.caption2)
                            .foregroundColor(Brand.muted)
                    }
                }
            } header: {
                Text("Удалённые организации")
            } footer: {
                Text("Справочно, за всё время их работы; в итог периода не входит.")
            }
        }
    }

    static func deletedLine(_ x: JSON) -> String {
        let orders = Fmt.plural(x["orders_done"].intValue, "заказ", "заказа", "заказов")
        return orders + " · удалена " + Fmt.date(x["deleted_at"])
    }

    // MARK: - Пополнения, долги, по магазинам

    private var topupsSection: some View {
        let items = d["topups_by_method"].array
        return Section("Пополнения по способам") {
            if items.isEmpty {
                Text("Нет данных").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.self) { t in
                    HStack {
                        Text(WalletsLabels.method(t["method"].string) + " (" + Fmt.number(t["cnt"]) + ")")
                        Spacer()
                        MoneyText(t["total"]).font(.subheadline.weight(.semibold))
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var negativeSection: some View {
        let items = d["negative_shops"].array
        return Section("Отрицательный баланс") {
            if items.isEmpty {
                Text("Нет магазинов с долгом").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.self) { s in
                    HStack {
                        Text(s["name"].stringValue)
                        Spacer()
                        MoneyText(s["balance"]).font(.subheadline.weight(.semibold))
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    private var byShopSection: some View {
        let items = d["commission_by_shop"].array
        return Section {
            if items.isEmpty {
                Text("Нет данных за период").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.self) { s in
                    ReportsShopRow(item: s)
                }
            }
        } header: {
            Text("Комиссии и сборы по магазинам")
        } footer: {
            Text("Выгрузка в CSV — кнопка вверху справа.")
        }
    }

    private func exportCSV() {
        let header = ["Магазин", "Заказов", "Комиссия", "Сервисный сбор", "Всего удержано", "Баланс кошелька"]
        var rows: [[String]] = []
        for s in d["commission_by_shop"].array {
            let total = (s["commission"].decimal ?? 0) + (s["service_fee"].decimal ?? 0)
            rows.append([
                s["name"].stringValue, s["orders"].stringValue,
                ReportsCSV.amount(s["commission"]), ReportsCSV.amount(s["service_fee"]),
                ReportsCSV.amount(decimal: total), ReportsCSV.amount(s["balance"]),
            ])
        }
        do {
            let url = try ReportsCSV.write(name: "reports_" + period, header: header, rows: rows)
            shared = SharedFile(url: url)
        } catch {
            exportError = "Не удалось сохранить файл: " + error.localizedDescription
        }
    }
}

/// Строка «подпись — сумма» с пояснением под ней.
struct ReportsNoteRow: View {
    let title: String
    let value: String
    let note: String

    init(title: String, value: String, note: String) {
        self.title = title
        self.value = value
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundColor(Brand.muted)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.subheadline)
            Text(note).font(.caption2).foregroundColor(Brand.muted)
        }
    }
}

/// Магазин в «Комиссиях и сборах по магазинам».
struct ReportsShopRow: View {
    let item: JSON

    init(item: JSON) { self.item = item }

    private var total: Decimal {
        (item["commission"].decimal ?? 0) + (item["service_fee"].decimal ?? 0)
    }

    private var parts: String {
        "комиссия " + Fmt.money(item["commission"]) + " · сбор " + Fmt.money(item["service_fee"])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["name"].stringValue).font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(value: total).font(.subheadline.weight(.semibold))
            }
            Text(Fmt.plural(item["orders"].intValue, "заказ", "заказа", "заказов") + " · " + parts)
                .font(.caption)
                .foregroundColor(Brand.muted)
            HStack(spacing: 4) {
                Text("Баланс кошелька:").font(.caption)
                MoneyText(item["balance"]).font(.caption)
            }
            .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - CSV

/// Выгрузка таблицы в CSV, как кнопка «Экспорт CSV» сайта: «;», UTF-8 с BOM, CRLF,
/// защита от подстановки формул (ячейка с = + - @ получает апостроф).
enum ReportsCSV {
    /// Сумма для CSV: «1234,5» (без разделителя тысяч и без ₽ — Excel читает числом).
    static func amount(_ j: JSON) -> String {
        guard let v = j.decimal else { return "" }
        return Fmt.decimalInput(v)
    }

    /// То же для Decimal.
    static func amount(decimal v: Decimal) -> String {
        Fmt.decimalInput(v)
    }

    /// Ячейка: экранирование формул и кавычек.
    static func cell(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        var safe = flat
        if let first = flat.first, "=+-@\t".contains(first) {
            // Отрицательное число — не формула: его оставляем как есть.
            let numeric = Decimal(string: flat.replacingOccurrences(of: ",", with: "."),
                                  locale: Locale(identifier: "en_US_POSIX")) != nil
            if !numeric { safe = "'" + flat }
        }
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Записать во временный файл `<name>_<дата>.csv` и вернуть его адрес.
    static func write(name: String, header: [String], rows: [[String]]) throws -> URL {
        var lines: [String] = [header.map { cell($0) }.joined(separator: ";")]
        for r in rows {
            lines.append(r.map { cell($0) }.joined(separator: ";"))
        }
        let text = "\u{FEFF}" + lines.joined(separator: "\r\n")
        let file = name + "_" + Fmt.ymd(Date()) + ".csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        guard let data = text.data(using: .utf8) else {
            throw APIError.badResponse("Не удалось подготовить файл")
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Досписание сборов

/// Досписание сборов по выполненным заказам порциями по 400 (POST /api/admin/finance/backfill-charges
/// {after}), пока сервер говорит `more`. Итог показывается В ЛЮБОМ случае — при обрыве
/// на середине часть списаний уже прошла.
@MainActor
final class ReportsBackfillModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var charged = 0
    @Published var result: String?
    @Published private(set) var resultIsError = false

    func run(onFinish: @escaping () async -> Void) {
        guard !running else { return }
        running = true
        charged = 0
        Task { @MainActor in
            await self.loop()
            self.running = false
            await onFinish()
        }
    }

    private func loop() async {
        var total = 0
        var failed = 0
        var scanned = 0
        var after = 0
        var rounds = 0
        var stopError: String?
        while rounds < 200 {
            rounds += 1
            let cursor = after
            do {
                let r = try await API.shared.post("/api/admin/finance/backfill-charges", body: ["after": cursor])
                total += r["charged"].intValue
                failed += r["failed"].intValue
                scanned += r["scanned"].intValue
                if let a = r["after"].int, a > 0 { after = a }
                charged = total
                if !r["more"].boolValue { break }
            } catch {
                stopError = APIError.isCancellation(error) ? "запрос отменён" : APIError.describe(error)
                break
            }
        }
        var summary = "Списано по " + Fmt.plural(total, "заказу", "заказам", "заказам")
            + " (проверено " + Fmt.number(scanned) + ")"
        if failed > 0 { summary += ", с ошибкой: " + Fmt.number(failed) }
        if let e = stopError { summary += ". Прервано: " + e }
        resultIsError = stopError != nil || failed > 0
        result = summary
        if stopError == nil { Haptics.success() } else { Haptics.error() }
    }
}

/// Кнопка «Досписать сборы» с подтверждением, счётчиком и итогом.
struct ReportsBackfillButton: View {
    let onFinish: () async -> Void

    @StateObject private var model = ReportsBackfillModel()
    @State private var ask = false

    init(onFinish: @escaping () async -> Void) {
        self.onFinish = onFinish
    }

    private var resultTitle: String {
        model.resultIsError ? "Досписание с ошибками" : "Досписание завершено"
    }

    private var resultShown: Binding<Bool> {
        Binding(get: { model.result != nil }, set: { if !$0 { model.result = nil } })
    }

    var body: some View {
        Button {
            Haptics.tap()
            ask = true
        } label: {
            HStack(spacing: 8) {
                if model.running {
                    ProgressView()
                    Text("Досписываю… " + Fmt.number(model.charged))
                } else {
                    Image(systemName: "arrow.down.to.line.circle")
                    Text("Досписать сборы")
                }
            }
        }
        .disabled(model.running)
        .confirmationDialog("Досписать сборы?", isPresented: $ask, titleVisibility: .visible) {
            Button("Досписать", role: .destructive) {
                model.run(onFinish: onFinish)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Списать сборы и комиссии с кошельков магазинов по всем выполненным заказам, по которым списания ещё не было. Повторно по уже списанным — не спишет.")
        }
        .alert(resultTitle, isPresented: resultShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.result ?? "")
        }
    }
}
