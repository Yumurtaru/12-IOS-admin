import SwiftUI
import Charts

// MARK: - Разбор ответа (толерантный: нет поля — пусто/0, число-строка читается)

/// Точка графика «активность за день».
struct AppsSeriesPoint: Identifiable {
    let id: Int
    let date: Date
    let active: Int
    let newInstalls: Int

    static func parse(_ j: JSON) -> [AppsSeriesPoint] {
        var out: [AppsSeriesPoint] = []
        for (i, r) in j.array.enumerated() {
            guard let d = AppsFmt.dayDate(r["day"].stringValue) else { continue }
            out.append(AppsSeriesPoint(id: i, date: d, active: r["active"].intValue,
                                       newInstalls: r["new_installs"].intValue))
        }
        return out
    }
}

/// Приложение на платформе (строка `apps`).
struct AppsGroup: Identifiable {
    let app: String
    let platform: String
    let title: String
    let installs: Int
    let people: Int
    let active30: Int
    let latestVersion: String?
    let minVersion: String?
    let latest: Int
    let old: Int
    let belowMin: Int
    let unknown: Int

    var id: String { app + "|" + platform }
    var outdated: Int { old + belowMin }

    static func parse(_ j: JSON) -> [AppsGroup] {
        var out: [AppsGroup] = []
        for r in j.array {
            let app = r["app"].stringValue
            let platform = r["platform"].stringValue
            if app.isEmpty && platform.isEmpty { continue }
            let title = r["title"].nonEmptyString ?? AppsFmt.appTitle(app)
            out.append(AppsGroup(app: app, platform: platform, title: title,
                                 installs: r["installs"].intValue, people: r["people"].intValue,
                                 active30: r["active_30d"].intValue,
                                 latestVersion: r["latest_version"].nonEmptyString,
                                 minVersion: r["min_version"].nonEmptyString,
                                 latest: r["latest"].intValue, old: r["old"].intValue,
                                 belowMin: r["below_min"].intValue, unknown: r["unknown"].intValue))
        }
        return out
    }
}

/// Версия приложения (строка `versions`).
struct AppsVersionRow: Identifiable {
    let id: Int
    let app: String
    let platform: String
    let version: String?
    let installs: Int
    let share: String?
    let state: String

    var label: String { version ?? "не определена" }
    var groupKey: String { app + "|" + platform }

    static func parse(_ j: JSON) -> [AppsVersionRow] {
        var out: [AppsVersionRow] = []
        for (i, r) in j.array.enumerated() {
            out.append(AppsVersionRow(id: i, app: r["app"].stringValue, platform: r["platform"].stringValue,
                                      version: r["version"].nonEmptyString, installs: r["installs"].intValue,
                                      share: r["share_pct"].nonEmptyString,
                                      state: r["state"].nonEmptyString ?? "unknown"))
        }
        return out
    }
}

/// Строка «название — число» (ОС, модели).
struct AppsCountRow: Identifiable {
    let id: Int
    let platform: String
    let label: String
    let count: Int
}

struct AppsBarItem: Identifiable {
    let id: String
    let category: String
    let kind: String
    let value: Int
    let color: Color
}

// MARK: - Модель

/// Загрузка GET /api/admin/app-clients/summary.
@MainActor
final class AppsOverviewModel: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var data: JSON = .null
    @Published private(set) var refreshError: String?

    private var generation = 0

    func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    /// Загрузить (или обновить «потянув»): старые данные остаются на экране до ответа.
    func load() async {
        generation += 1
        let gen = generation
        if data.isNull { state = .loading }
        do {
            let d = try await API.shared.get("/api/admin/app-clients/summary")
            guard gen == generation else { return }
            data = d
            refreshError = nil
            state = .loaded
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            let msg = AppsFmt.errorText(error)
            if data.isNull {
                state = .failed(msg)
            } else {
                refreshError = msg
                state = .loaded
            }
        }
    }
}

// MARK: - Экран

/// Вкладка «Обзор».
struct AppsOverviewView: View {
    @ObservedObject var model: AppsOverviewModel

    var body: some View {
        AsyncContent(state: model.state, emptyText: "Данных пока нет", retry: { await model.load() }) {
            ScrollView {
                VStack(spacing: 12) {
                    if let e = model.refreshError {
                        ErrorBanner(message: e, retry: { Task { await model.load() } })
                    }
                    AppsOverviewBody(data: model.data)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .refreshable { await model.load() }
        }
        .task { await model.loadIfNeeded() }
    }
}

/// Все карточки обзора.
struct AppsOverviewBody: View {
    let data: JSON

    var body: some View {
        let groups = AppsGroup.parse(data["apps"])
        let versions = AppsVersionRow.parse(data["versions"])
        VStack(spacing: 12) {
            AppsTotalsCard(totals: data["totals"], source: data["by_source_30d"])
            AppsActivityCard(activity: data["activity"])
            AppsSeriesCards(points: AppsSeriesPoint.parse(data["series"]))
            AppsPlatformsCard(rows: data["platforms"].array)
            AppsVersionsCard(groups: groups, versions: versions)
            AppsOSCard(rows: data["os"].array)
            AppsDevicesCard(rows: data["devices"].array)
            AppsStationsCard(rows: data["stations"].array)
        }
    }
}

// MARK: - Карточки

struct AppsTotalsCard: View {
    let totals: JSON
    let source: JSON

    var body: some View {
        let clients = totals["clients"].intValue
        let withApp = totals["with_app"].intValue
        SectionCard("Клиенты и приложение") {
            AppsTileGrid {
                AppsStatTile(title: "Всего клиентов", value: AppsFmt.num(clients))
                AppsStatTile(title: "С приложением", value: AppsFmt.num(withApp), color: Brand.green)
                AppsStatTile(title: "Без приложения", value: AppsFmt.num(totals["without_app"].intValue))
                AppsStatTile(title: "Push включён", value: AppsFmt.num(totals["push_enabled"].intValue))
            }
            if clients > 0 {
                let pct = Int((Double(withApp) / Double(clients) * 100).rounded())
                Text("Приложение есть у " + String(pct) + "% клиентов. «Без приложения» значит «данных об установке нет».")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
            Text("Откуда заходили за 30 дней")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            AppsTileGrid {
                AppsStatTile(title: "Только сайт", value: AppsFmt.num(source["web"].intValue))
                AppsStatTile(title: "Только приложение", value: AppsFmt.num(source["app"].intValue))
                AppsStatTile(title: "И сайт, и приложение", value: AppsFmt.num(source["both"].intValue))
            }
        }
    }
}

struct AppsActivityCard: View {
    let activity: JSON

    var body: some View {
        let items = bars()
        SectionCard("Активность клиентов") {
            AppsTileGrid {
                AppsStatTile(title: "DAU (за день)", value: AppsFmt.num(activity["dau"].intValue))
                AppsStatTile(title: "WAU (за неделю)", value: AppsFmt.num(activity["wau"].intValue))
                AppsStatTile(title: "MAU (за 30 дней)", value: AppsFmt.num(activity["mau"].intValue))
            }
            AppsTileGrid {
                AppsStatTile(title: "Активные (до 30 дн.)", value: AppsFmt.num(activity["active"].intValue),
                             color: Brand.green)
                AppsStatTile(title: "Спящие (31–90 дн.)", value: AppsFmt.num(activity["sleeping"].intValue),
                             color: Brand.amber)
                AppsStatTile(title: "Ушедшие (90+ дн.)", value: AppsFmt.num(activity["lost"].intValue),
                             color: Brand.red)
                AppsStatTile(title: "Нет данных", value: AppsFmt.num(activity["never"].intValue))
            }
            Chart(items) { it in
                BarMark(x: .value("Состояние", it.category), y: .value("Клиенты", it.value))
                    .foregroundStyle(it.color)
            }
            .frame(height: 140)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Диаграмма: клиенты по активности")
            .accessibilityValue(items.map { $0.category + ": " + String($0.value) }.joined(separator: ", "))
        }
    }

    private func bars() -> [AppsBarItem] {
        [
            AppsBarItem(id: "active", category: "Активные", kind: "", value: activity["active"].intValue,
                        color: Brand.green),
            AppsBarItem(id: "sleeping", category: "Спящие", kind: "", value: activity["sleeping"].intValue,
                        color: Brand.amber),
            AppsBarItem(id: "lost", category: "Ушедшие", kind: "", value: activity["lost"].intValue,
                        color: Brand.red),
            AppsBarItem(id: "never", category: "Нет данных", kind: "", value: activity["never"].intValue,
                        color: Brand.muted),
        ]
    }
}

/// Графики «активные за день» и «новые установки» за 30 дней.
struct AppsSeriesCards: View {
    let points: [AppsSeriesPoint]

    var body: some View {
        SectionCard("Активность за 30 дней") {
            if points.isEmpty {
                DashboardNoData()
            } else {
                activeChart
            }
        }
        SectionCard("Новые установки за 30 дней") {
            if points.isEmpty {
                DashboardNoData()
            } else {
                installsChart
            }
        }
    }

    private var activeChart: some View {
        Chart(points) { p in
            AreaMark(x: .value("День", p.date, unit: .day), y: .value("Активные", p.active))
                .foregroundStyle(Brand.accent.opacity(0.15))
            LineMark(x: .value("День", p.date, unit: .day), y: .value("Активные", p.active))
                .foregroundStyle(Brand.accent)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .frame(height: 170)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("График: активные клиенты по дням за 30 дней")
        .accessibilityValue(activeSummary)
    }

    private var installsChart: some View {
        Chart(points) { p in
            BarMark(x: .value("День", p.date, unit: .day), y: .value("Установки", p.newInstalls))
                .foregroundStyle(Brand.blue.opacity(0.7))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("График: новые установки по дням за 30 дней")
        .accessibilityValue(installsSummary)
    }

    private var activeSummary: String {
        let values = points.map { $0.active }
        guard let last = values.last, let lo = values.min(), let hi = values.max() else { return "нет данных" }
        return "сегодня " + String(last) + ", минимум " + String(lo) + ", максимум " + String(hi)
    }

    private var installsSummary: String {
        let total = points.reduce(0) { $0 + $1.newInstalls }
        let last = points.last?.newInstalls ?? 0
        return "всего " + String(total) + ", сегодня " + String(last)
    }
}

/// Android и iOS: клиенты и установки.
struct AppsPlatformsCard: View {
    let rows: [JSON]

    var body: some View {
        let items = bars()
        SectionCard("Android и iOS") {
            if items.isEmpty {
                DashboardNoData()
            } else {
                Chart(items) { it in
                    BarMark(x: .value("Платформа", it.category), y: .value("Число", it.value))
                        .foregroundStyle(by: .value("Показатель", it.kind))
                        .position(by: .value("Показатель", it.kind))
                }
                .chartForegroundStyleScale(domain: ["Клиенты", "Установки"], range: [Brand.blue, Brand.accent])
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .frame(height: 170)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Диаграмма: клиенты и установки по платформам")
                .accessibilityValue(items.map { $0.category + ", " + $0.kind + ": " + String($0.value) }
                    .joined(separator: "; "))
            }
        }
    }

    private func bars() -> [AppsBarItem] {
        var out: [AppsBarItem] = []
        for r in rows {
            let p = r["platform"].stringValue
            if p.isEmpty { continue }
            let name = AppsFmt.platformTitle(p)
            out.append(AppsBarItem(id: p + "-c", category: name, kind: "Клиенты", value: r["clients"].intValue,
                                   color: Brand.blue))
            out.append(AppsBarItem(id: p + "-i", category: name, kind: "Установки", value: r["installs"].intValue,
                                   color: Brand.accent))
        }
        return out
    }
}

/// Версии по приложениям, устаревшие — с отметкой.
struct AppsVersionsCard: View {
    let groups: [AppsGroup]
    let versions: [AppsVersionRow]

    /// Группы из `apps`, а если там нет какой-то пары из `versions` — добавляем её без сводки.
    private var keys: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for g in groups where !seen.contains(g.id) {
            seen.insert(g.id)
            out.append(g.id)
        }
        for v in versions where !seen.contains(v.groupKey) {
            seen.insert(v.groupKey)
            out.append(v.groupKey)
        }
        return out
    }

    var body: some View {
        SectionCard("Версии приложений") {
            if keys.isEmpty {
                DashboardNoData()
            } else {
                legend
                ForEach(keys, id: \.self) { key in
                    AppsVersionGroupView(key: key,
                                         group: groups.first { $0.id == key },
                                         rows: versions.filter { $0.groupKey == key })
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(["latest", "old", "below_min", "unknown"], id: \.self) { s in
                HStack(spacing: 4) {
                    Circle().fill(AppsFmt.stateColor(s)).frame(width: 8, height: 8)
                    Text(AppsFmt.stateTitle(s)).font(.caption2).foregroundColor(Brand.muted)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Одно приложение на одной платформе: сводка и столбцы по версиям.
struct AppsVersionGroupView: View {
    let key: String
    let group: AppsGroup?
    let rows: [AppsVersionRow]

    private var top: [AppsVersionRow] {
        Array(rows.sorted { $0.installs > $1.installs }.prefix(12))
    }

    private var heading: String {
        if let g = group { return g.title + " · " + AppsFmt.platformTitle(g.platform) }
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        let app = parts.first.map(String.init) ?? ""
        let platform = parts.count > 1 ? String(parts[1]) : ""
        return AppsFmt.appTitle(app) + " · " + AppsFmt.platformTitle(platform)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(heading).font(.subheadline.weight(.semibold))
            if let g = group {
                summary(g)
            }
            if top.isEmpty {
                Text("Версий нет").font(.footnote).foregroundColor(Brand.muted)
            } else {
                chart
            }
        }
    }

    @ViewBuilder
    private func summary(_ g: AppsGroup) -> some View {
        let installsLine = "Установок: \(AppsFmt.num(g.installs)) · людей: \(AppsFmt.num(g.people)) · активных за 30 дн.: \(AppsFmt.num(g.active30))"
        Text(installsLine).font(.footnote).foregroundColor(Brand.muted)
        HStack(spacing: 6) {
            if let v = g.latestVersion {
                StatusBadge("Последняя " + v, color: Brand.green)
            }
            if let m = g.minVersion {
                StatusBadge("Минимум " + m, color: Brand.blue)
            }
            if g.outdated > 0 {
                StatusBadge("Устарели: " + AppsFmt.num(g.outdated), color: g.belowMin > 0 ? Brand.red : Brand.amber)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        Chart(top) { r in
            BarMark(x: .value("Установки", r.installs), y: .value("Версия", r.label))
                .foregroundStyle(AppsFmt.stateColor(r.state))
                .annotation(position: .trailing) {
                    Text(annotation(r))
                        .font(.caption2)
                        .foregroundColor(AppsFmt.isOutdated(r.state) ? AppsFmt.stateColor(r.state) : Brand.muted)
                }
        }
        .chartXAxis(.hidden)
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .frame(height: CGFloat(top.count) * 30 + 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Диаграмма: версии. " + heading)
        .accessibilityValue(top.map { $0.label + ": " + String($0.installs) + ", " + AppsFmt.stateTitle($0.state) }
            .joined(separator: "; "))
    }

    private func annotation(_ r: AppsVersionRow) -> String {
        var text = String(r.installs)
        if let s = r.share { text += " (" + s + "%)" }
        if AppsFmt.isOutdated(r.state) { text += " · устарела" }
        return text
    }
}

/// Версии ОС по платформам.
struct AppsOSCard: View {
    let rows: [JSON]

    private func items(_ platform: String) -> [AppsCountRow] {
        var out: [AppsCountRow] = []
        for (i, r) in rows.enumerated() where r["platform"].stringValue == platform {
            let v = r["os_version"].nonEmptyString ?? "не определена"
            out.append(AppsCountRow(id: i, platform: platform, label: v, count: r["installs"].intValue))
        }
        return Array(out.sorted { $0.count > $1.count }.prefix(8))
    }

    private var platforms: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in rows {
            let p = r["platform"].stringValue
            if !p.isEmpty && !seen.contains(p) {
                seen.insert(p)
                out.append(p)
            }
        }
        return out
    }

    var body: some View {
        SectionCard("Операционные системы") {
            if platforms.isEmpty {
                DashboardNoData()
            } else {
                ForEach(platforms, id: \.self) { p in
                    osChart(p)
                }
            }
        }
    }

    @ViewBuilder
    private func osChart(_ platform: String) -> some View {
        let data = items(platform)
        VStack(alignment: .leading, spacing: 4) {
            Text(AppsFmt.platformTitle(platform)).font(.subheadline.weight(.semibold))
            Chart(data) { r in
                BarMark(x: .value("Установки", r.count), y: .value("ОС", r.label))
                    .foregroundStyle(platform == "ios" ? Brand.blue : Brand.green)
                    .annotation(position: .trailing) {
                        Text(String(r.count)).font(.caption2).foregroundColor(Brand.muted)
                    }
            }
            .chartXAxis(.hidden)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .frame(height: CGFloat(data.count) * 28 + 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Диаграмма: версии ОС, " + AppsFmt.platformTitle(platform))
            .accessibilityValue(data.map { $0.label + ": " + String($0.count) }.joined(separator: "; "))
        }
    }
}

/// Топ моделей устройств.
struct AppsDevicesCard: View {
    let rows: [JSON]

    var body: some View {
        SectionCard("Модели устройств") {
            if rows.isEmpty {
                DashboardNoData()
            } else {
                ForEach(Array(rows.prefix(10).enumerated()), id: \.offset) { pair in
                    HStack {
                        Text(pair.element["device_model"].nonEmptyString ?? "не определена")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Text(AppsFmt.num(pair.element["installs"].intValue))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundColor(Brand.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Кассы и станции: версия, сколько, когда выходили на связь.
struct AppsStationsCard: View {
    let rows: [JSON]

    var body: some View {
        SectionCard("Кассы и станции") {
            if rows.isEmpty {
                DashboardNoData()
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                    row(pair.element)
                }
            }
        }
    }

    private func row(_ r: JSON) -> some View {
        let title = AppsFmt.stationTitle(r["kind"].string, title: r["title"].nonEmptyString)
        let version = r["version"].nonEmptyString.map { "версия " + $0 } ?? "версия не определена"
        let seen = "на связи: " + AppsFmt.when(r["last_seen"].string)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(AppsFmt.num(r["count"].intValue))
                    .font(.subheadline)
                    .monospacedDigit()
            }
            Text(version + " · " + seen)
                .font(.footnote)
                .foregroundColor(Brand.muted)
        }
        .accessibilityElement(children: .combine)
    }
}
