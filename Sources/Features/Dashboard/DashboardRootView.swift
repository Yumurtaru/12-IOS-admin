import Charts
import SwiftUI

/// «Сводка» — дашборд маркетплейса: GET /api/admin/dashboard?period=7|14|30|90.
///
/// Всё, что показывает главная веб-админки (admin/index.php + admin.js dashboard):
/// красная плашка, если крон не работает; 13 показателей; графики «Выручка по
/// дням» (линия) и «Заказы по дням» (столбцы); топ магазинов и магазины по
/// городам. Плюс быстрые переходы в очереди, которые ждут администратора
/// (счётчики сводки и Notifier).
///
/// `openId` у сводки не используется (объекта нет) — параметр для единообразия.
struct DashboardRootView: View {
    let openId: Int?

    @StateObject private var loader = ObjectLoader(path: "/api/admin/dashboard", query: ["period": "30"])
    @ObservedObject private var notifier = Notifier.shared
    @State private var period = 30

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var d: JSON { loader.data }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            content
        }
        .navigationTitle("Сводка")
        .task { await loader.loadIfNeeded() }
        .onChange(of: period) { p in
            loader.query = ["period": String(p)]
            Task { await loader.load() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Период", selection: $period) {
                    Text("7 дней").tag(7)
                    Text("14 дней").tag(14)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
                if let e = loader.lastRefreshError {
                    ErrorBanner(message: e, retry: { Task { await loader.load() } })
                }
                if d["cron"]["stale"].boolValue {
                    DashboardCronBanner(cron: d["cron"])
                }
                DashboardQueuesCard(d: d, notifier: notifier)
                DashboardMetricsGrid(d: d)
                DashboardSalesCharts(days: DashboardDay.parse(d["sales_by_day"]))
                DashboardTopShopsCard(rows: d["top_shops"].array)
                DashboardCitiesCard(rows: d["by_city"].array)
            }
            .padding(16)
        }
        .background(Brand.bg)
        .refreshable {
            await loader.load()
            await notifier.refresh(force: true)
        }
    }
}

// MARK: - Крон

/// Плашка «Фоновые задачи не выполняются» — текст как на сайте.
struct DashboardCronBanner: View {
    let cron: JSON

    private var when: String {
        if cron["never"].boolValue { return "ни разу" }
        var s = "последний раз " + Fmt.date(cron["last_run"].string)
        if let m = cron["minutes_ago"].int { s += " (" + String(m) + " мин назад)" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Фоновые задачи не выполняются — " + when, systemImage: "exclamationmark.octagon.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.red)
            Text("Пока крон не работает: не списываются комиссии и сервисные сборы, не продлеваются подписки, не снимаются истёкшие объявления, не освобождаются даты отменённых броней. Проверьте задание в панели хостинга: оно должно запускать php /путь/cron/runner.php раз в минуту (обращение по адресу сайта не подходит — скрипт работает только из командной строки).")
                .font(.footnote)
                .foregroundColor(Brand.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Очереди

/// Одна очередь: подпись, число, куда вести.
struct DashboardQueue: Identifiable {
    let id: String
    let title: String
    let count: Int
    let symbol: String
    let destination: AnyView
}

/// «Ждут вас»: переходы в разделы с числом ожидающих.
struct DashboardQueuesCard: View {
    let d: JSON
    @ObservedObject var notifier: Notifier

    private var queues: [DashboardQueue] {
        let regs = AnyView(RegistrationsRootView(openId: nil, initialTab: .registrations))
        let publish = AnyView(RegistrationsRootView(openId: nil, initialTab: .publish))
        let docs = AnyView(RegistrationsRootView(openId: nil, initialTab: .documents))
        return [
            DashboardQueue(id: "regs", title: "Заявки на регистрацию", count: d["pending_regs"].intValue,
                           symbol: "doc.text.magnifyingglass", destination: regs),
            DashboardQueue(id: "publish", title: "Готовы к публикации", count: d["pending_publish"].intValue,
                           symbol: "checkmark.seal", destination: publish),
            DashboardQueue(id: "docs", title: "Лицензии на проверке", count: notifier.count(.documents),
                           symbol: "doc.richtext", destination: docs),
            DashboardQueue(id: "topups", title: "Пополнения к подтверждению", count: d["pending_topups"].intValue,
                           symbol: AdminSection.wallets.symbol, destination: AdminSection.wallets.makeRoot()),
            DashboardQueue(id: "reviews", title: "Отзывы на модерации", count: d["pending_reviews"].intValue,
                           symbol: AdminSection.reviews.symbol, destination: AdminSection.reviews.makeRoot()),
            DashboardQueue(id: "complaints", title: "Открытые жалобы", count: d["open_complaints"].intValue,
                           symbol: AdminSection.complaints.symbol, destination: AdminSection.complaints.makeRoot()),
            DashboardQueue(id: "returns", title: "Возвраты без ответа > 72 ч", count: d["stale_returns"].intValue,
                           symbol: AdminSection.returns.symbol,
                           destination: AnyView(ReturnsRootView(openId: nil, escalated: true))),
            DashboardQueue(id: "support", title: "Обращения в поддержку", count: notifier.count(.support),
                           symbol: AdminSection.support.symbol, destination: AdminSection.support.makeRoot()),
            DashboardQueue(id: "ads", title: "Жалобы на объявления", count: notifier.count(.adReports),
                           symbol: AdminSection.ads.symbol, destination: AdminSection.ads.makeRoot()),
            // «Курьеры Yumurta»: счётчики из /api/admin/pool/summary (опрос Notifier).
            DashboardQueue(id: "couriers", title: "Заявки курьеров", count: notifier.count(.couriers),
                           symbol: AdminSection.couriers.symbol, destination: AdminSection.couriers.makeRoot()),
            DashboardQueue(id: "courierProblems", title: "Проблемы с доставкой курьеров",
                           count: notifier.count(.courierProblems), symbol: "exclamationmark.bubble",
                           destination: AdminSection.couriers.makeRoot(subtab: "problems")),
            DashboardQueue(id: "courierComplaints", title: "Жалобы по доставкам курьеров",
                           count: notifier.count(.courierComplaints), symbol: "hand.raised",
                           destination: AdminSection.couriers.makeRoot(subtab: "complaints")),
        ]
    }

    /// П-29.7: оборвавшиеся онлайн-оплаты продавцов — теперь не входят в
    /// pending_topups (подтвердить их руками нельзя), сервер отдаёт их отдельно.
    /// Нет поля (старый сервер) или 0 — строки нет.
    private var onlineAbandoned: Int { d["pending_topups_online"].int ?? 0 }

    var body: some View {
        let list = queues
        let waiting = list.filter { $0.count > 0 }
        let online = onlineAbandoned
        SectionCard("Ждут вас") {
            if waiting.isEmpty {
                Label("Всё разобрано", systemImage: "checkmark.seal")
                    .font(.subheadline)
                    .foregroundColor(Brand.green)
            } else {
                ForEach(waiting) { q in
                    DashboardQueueRow(queue: q)
                }
            }
            if online > 0 {
                DashboardOnlineTopupsLine(count: online)
            }
        }
    }
}

/// Небольшая строка «Онлайн-оплаты оборвались: N» → «Кошельки» (П-29.7).
struct DashboardOnlineTopupsLine: View {
    let count: Int

    init(count: Int) {
        self.count = count
    }

    var body: some View {
        NavigationLink(destination: AdminSection.wallets.makeRoot()) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                Text("Онлайн-оплаты продавцов оборвались: " + String(count) + " — подтверждать не нужно")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

/// Строка очереди со стрелкой.
struct DashboardQueueRow: View {
    let queue: DashboardQueue

    var body: some View {
        NavigationLink(destination: queue.destination) {
            HStack(spacing: 10) {
                Image(systemName: queue.symbol)
                    .frame(width: 24)
                    .foregroundColor(Brand.accent)
                Text(queue.title)
                    .foregroundColor(Brand.text)
                Spacer()
                Text(String(queue.count))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .foregroundColor(.white)
                    .background(Brand.accent)
                    .clipShape(Capsule())
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Показатели

/// Сетка показателей — те же 13, что на сайте.
struct DashboardMetricsGrid: View {
    let d: JSON

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    private var refundRate: String {
        Fmt.number(d["refund_rate"]) + " %"
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            // Group — не больше 10 элементов в одном блоке ViewBuilder.
            Group {
                DashboardMetric("GMV за период", Fmt.money(d["period_gmv"]),
                                sub: Fmt.plural(d["period_orders"].intValue, "заказ", "заказа", "заказов"))
                DashboardMetric("Доход с комиссий", Fmt.money(d["period_commission"]))
                DashboardMetric("Средний чек", Fmt.money(d["avg_check"]))
                DashboardMetric("Активные магазины", Fmt.number(d["active_shops"]))
                DashboardMetric("Новые пользователи", Fmt.number(d["new_users"]))
                DashboardMetric("Доля возвратов", refundRate, sub: Fmt.number(d["refunds"]) + " шт.")
                DashboardMetric("Заявки на модерации", Fmt.number(d["pending_regs"]))
                DashboardMetric("Готовы к публикации", Fmt.number(d["pending_publish"]))
                DashboardMetric("Пополнения к подтверждению", Fmt.number(d["pending_topups"]))
            }
            Group {
                DashboardMetric("GMV за всё время", Fmt.money(d["gmv"]))
                DashboardMetric("Магазины", Fmt.number(d["shops_total"]), sub: "+" + Fmt.number(d["shops_today"]) + " сегодня")
                DashboardMetric("Пользователи", Fmt.number(d["users_total"]), sub: "+" + Fmt.number(d["users_today"]) + " сегодня")
                DashboardMetric("Комиссии всего", Fmt.money(d["commission"]))
            }
        }
    }
}

/// Плитка показателя.
struct DashboardMetric: View {
    let title: String
    let value: String
    let sub: String?

    init(_ title: String, _ value: String, sub: String? = nil) {
        self.title = title
        self.value = value
        self.sub = sub
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(Brand.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let s = sub {
                Text(s)
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(12)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Графики

/// День из sales_by_day: d (Y-m-d), r (выручка), c (заказов).
struct DashboardDay: Identifiable {
    let id: String
    let date: Date
    let revenue: Double
    let orders: Int

    /// Разобрать массив sales_by_day (строки без даты пропускаются).
    static func parse(_ j: JSON) -> [DashboardDay] {
        var out: [DashboardDay] = []
        for row in j.array {
            guard let day = row["d"].string, let date = Fmt.parseDate(day) else { continue }
            out.append(DashboardDay(id: day, date: date, revenue: row["r"].double ?? 0, orders: row["c"].intValue))
        }
        return out
    }
}

/// «Выручка по дням» (линия с заливкой) и «Заказы по дням» (столбцы).
struct DashboardSalesCharts: View {
    let days: [DashboardDay]

    var body: some View {
        SectionCard("Выручка по дням") {
            if days.isEmpty {
                DashboardNoData()
            } else {
                revenueChart
            }
        }
        SectionCard("Заказы по дням") {
            if days.isEmpty {
                DashboardNoData()
            } else {
                ordersChart
            }
        }
    }

    private var revenueChart: some View {
        Chart(days) { day in
            AreaMark(x: .value("День", day.date, unit: .day), y: .value("Выручка", day.revenue))
                .foregroundStyle(Brand.accent.opacity(0.15))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("День", day.date, unit: .day), y: .value("Выручка", day.revenue))
                .foregroundStyle(Brand.accent)
                .interpolationMethod(.catmullRom)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(DashboardSalesCharts.short(v))
                    }
                }
            }
        }
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .frame(height: 180)
    }

    private var ordersChart: some View {
        Chart(days) { day in
            BarMark(x: .value("День", day.date, unit: .day), y: .value("Заказы", day.orders))
                .foregroundStyle(Brand.blue.opacity(0.6))
        }
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .frame(height: 160)
    }

    /// Подпись оси: «12 тыс.», «1,2 млн».
    static func short(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1_000_000 { return Fmt.number(Decimal((v / 100_000).rounded() / 10)) + " млн" }
        if a >= 1_000 { return Fmt.number(Decimal((v / 1_000).rounded())) + " тыс." }
        return Fmt.number(Decimal(v.rounded()))
    }
}

/// «Нет данных».
struct DashboardNoData: View {
    var body: some View {
        Text("Нет данных")
            .font(.subheadline)
            .foregroundColor(Brand.muted)
    }
}

// MARK: - Списки

/// «Топ магазинов» за период: название и выручка.
struct DashboardTopShopsCard: View {
    let rows: [JSON]

    var body: some View {
        SectionCard("Топ магазинов") {
            if rows.isEmpty {
                DashboardNoData()
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                    DashboardListLine(title: pair.element["name"].nonEmptyString ?? "—",
                                      value: Fmt.money(pair.element["rev"]),
                                      rank: pair.offset + 1)
                }
            }
        }
    }
}

/// «По городам»: сколько организаций в городе (за всё время).
struct DashboardCitiesCard: View {
    let rows: [JSON]

    var body: some View {
        SectionCard("По городам") {
            if rows.isEmpty {
                DashboardNoData()
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                    DashboardListLine(title: pair.element["city"].nonEmptyString ?? "—",
                                      value: Fmt.number(pair.element["cnt"]),
                                      rank: nil)
                }
            }
        }
    }
}

/// Строка «название — значение» с разделителем.
struct DashboardListLine: View {
    let title: String
    let value: String
    let rank: Int?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                if let r = rank {
                    Text(String(r) + ".")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(Brand.muted)
                        .frame(width: 26, alignment: .leading)
                }
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }
            Divider()
        }
    }
}
