import SwiftUI

/// Вкладка «Установки» раздела «Приложения» (как «Установки» в admin-app-installs.js):
///   GET /api/admin/app-installs/summary?days=  — по приложениям и платформам, версии;
///   GET /api/admin/app-installs?app=&platform=&version=&q=&days=&page= — «у кого что установлено».
/// Только чтение. Активность по умолчанию — за 90 дней, как на сайте.
struct AppsInstallsView: View {
    @ObservedObject var list: PagedListModel
    @ObservedObject var summary: ObjectLoader

    init(list: PagedListModel, summary: ObjectLoader) {
        self.list = list
        self.summary = summary
    }

    /// Модель списка с фильтром по умолчанию.
    static func makeList() -> PagedListModel {
        PagedListModel(path: "/api/admin/app-installs", filters: ["days": "90"])
    }

    /// Загрузчик сводки (то же окно активности, что и у списка).
    static func makeSummary() -> ObjectLoader {
        ObjectLoader(path: "/api/admin/app-installs/summary", query: ["days": "90"])
    }

    private var groups: [JSON] { summary.data["groups"].array }

    var body: some View {
        AdminListScreen("Приложения", model: list, searchPrompt: "Имя, телефон, почта, модель",
                        filters: filters, emptyText: "Ничего не найдено",
                        header: AnyView(AppsInstallsSummary(loader: summary)),
                        row: { item in AppsInstallRow(item: item) })
            .task { await summary.loadIfNeeded() }
            .onChange(of: list.filter("days") ?? "") { days in
                Task { await reloadSummary(days: days) }
            }
            .onChange(of: list.filter("app") ?? "") { _ in resetVersion() }
            .onChange(of: list.filter("platform") ?? "") { _ in resetVersion() }
    }

    private func reloadSummary(days: String) async {
        summary.query = ["days": days.isEmpty ? nil : days]
        await summary.load()
    }

    private func resetVersion() {
        if list.filter("version") != nil { list.setFilter("version", nil) }
    }

    // MARK: - Фильтры

    private var filters: [ListFilter] {
        [
            ListFilter(key: "days", title: "Активность", options: Self.daysOptions, allLabel: "За всё время"),
            ListFilter(key: "app", title: "Приложение", options: appOptions, allLabel: "Все приложения"),
            ListFilter(key: "platform", title: "Платформа", options: Self.platformOptions, allLabel: "Все платформы"),
            ListFilter(key: "version", title: "Версия", options: versionOptions, allLabel: "Все версии"),
        ]
    }

    private static let daysOptions: [PickerOption] = [
        PickerOption(value: "30", label: "за 30 дней"),
        PickerOption(value: "90", label: "за 90 дней"),
        PickerOption(value: "365", label: "за год"),
    ]

    private static let platformOptions: [PickerOption] = [
        PickerOption(value: "android", label: "Android"),
        PickerOption(value: "ios", label: "iPhone"),
        PickerOption(value: "web", label: "Сайт (web-push)"),
    ]

    /// Приложения — те, что есть в сводке.
    private var appOptions: [PickerOption] {
        var seen = Set<String>()
        var out: [PickerOption] = []
        for g in groups {
            guard let app = g["app"].nonEmptyString, !seen.contains(app) else { continue }
            seen.insert(app)
            out.append(PickerOption(value: app, label: g["app_title"].nonEmptyString ?? AppsFmt.appTitle(app)))
        }
        if out.isEmpty {
            return [PickerOption(value: "client", label: "Покупатель"),
                    PickerOption(value: "seller", label: "Продавец"),
                    PickerOption(value: "courier", label: "Курьер")]
        }
        return out
    }

    /// Версии выбранного приложения и платформы (с числом установок). «Неизвестная» версия
    /// фильтром списка не выбирается: пустое значение фильтра равно «без фильтра».
    private var versionOptions: [PickerOption] {
        let app = list.filter("app") ?? ""
        let platform = list.filter("platform") ?? ""
        var counts: [String: Int] = [:]
        for g in groups {
            if !app.isEmpty && g["app"].string != app { continue }
            if !platform.isEmpty && g["platform"].string != platform { continue }
            for v in g["versions"].array {
                guard let ver = v["version"].nonEmptyString else { continue }
                counts[ver, default: 0] += v["installs"].intValue
            }
        }
        let sorted = counts.keys.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return sorted.map { PickerOption(value: $0, label: $0 + " — " + Fmt.number(counts[$0] ?? 0)) }
    }
}

/// Сводка над списком: всего установок и людей, по приложению и платформе — версии и их состояние.
struct AppsInstallsSummary: View {
    @ObservedObject var loader: ObjectLoader

    private var groups: [JSON] { loader.data["groups"].array }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
        case .failed(let msg):
            ErrorBanner(message: msg, retry: { Task { await loader.load() } })
        case .empty:
            EmptyView()
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if let err = loader.lastRefreshError {
            ErrorBanner(message: err, retry: { Task { await loader.load() } })
        }
        if groups.isEmpty {
            Text("Пока нет данных. Установки появятся, когда приложения запустятся и зарегистрируют уведомления.")
                .font(.footnote)
                .foregroundColor(Brand.muted)
        } else {
            Text(verbatim: "Всего установок: \(Fmt.number(loader.data["total_installs"].intValue)) · людей: \(Fmt.number(loader.data["total_users"].intValue))")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(groups.enumerated()), id: \.offset) { pair in
                AppsInstallGroupCard(group: pair.element)
            }
        }
        Text("Кто и какое приложение Yumurta установил и какой версии. Установка видна, когда приложение запускается и регистрирует уведомления; версию сообщают новые сборки — у старых она неизвестна.")
            .font(.caption)
            .foregroundColor(Brand.muted)
    }
}

/// Карточка «приложение · платформа».
struct AppsInstallGroupCard: View {
    let group: JSON

    private var installs: Int { group["installs"].intValue }
    private var versions: [JSON] { group["versions"].array }

    private var onLatest: Int {
        versions.filter { $0["state"].string == "latest" }.reduce(0) { $0 + $1["installs"].intValue }
    }

    private var caption: String {
        var s = (installs == 1 ? "установка" : "установок") + " · людей " + Fmt.number(group["users"].intValue)
        if let lv = group["latest_version"].nonEmptyString, installs > 0 {
            s += " · актуальная " + lv + " — у " + String(onLatest * 100 / installs) + "%"
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(group["app_title"].nonEmptyString ?? "Приложение")
                    .font(.body.weight(.semibold))
                Spacer(minLength: 6)
                Text(group["platform_title"].nonEmptyString ?? "")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(Fmt.number(installs))
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundColor(Brand.muted)
            if group["last_seen"].nonEmptyString != nil {
                Text("Последний запуск " + Fmt.date(group["last_seen"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            ForEach(Array(versions.prefix(6).enumerated()), id: \.offset) { pair in
                AppsInstallVersionLine(version: pair.element, total: installs)
            }
            if versions.count > 6 {
                Text("… ещё " + String(versions.count - 6))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Строка версии: «1.4.2 (57) [актуальная]  12 · 40%».
struct AppsInstallVersionLine: View {
    let version: JSON
    let total: Int

    private var ver: String? { version["version"].nonEmptyString }
    private var count: Int { version["installs"].intValue }

    private var stateBadge: (String, Color)? {
        guard ver != nil else { return nil }
        switch version["state"].string ?? "" {
        case "latest": return ("актуальная", Brand.green)
        case "old": return ("устарела", Brand.amber)
        case "below_min": return ("ниже минимальной", Brand.red)
        default: return nil
        }
    }

    private var title: String {
        guard let v = ver else { return "версия неизвестна" }
        if let b = version["build"].int, b > 0 { return v + " (" + String(b) + ")" }
        return v
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.footnote.weight(ver == nil ? .regular : .semibold))
                .foregroundColor(ver == nil ? Brand.muted : Brand.text)
            if let b = stateBadge {
                StatusBadge(b.0, color: b.1)
            }
            Spacer(minLength: 6)
            Text(verbatim: "\(Fmt.number(count)) · \(total > 0 ? count * 100 / total : 0)%")
                .font(.footnote)
                .monospacedDigit()
                .foregroundColor(Brand.muted)
        }
    }
}

/// Строка списка: кто, приложение, версия, устройство, даты.
struct AppsInstallRow: View {
    let item: JSON

    private var userId: Int? {
        if let id = item["user_id"].int, id > 0 { return id }
        return nil
    }

    private var who: String {
        guard let id = userId else { return "Без входа" }
        return item["user_name"].nonEmptyString ?? ("#" + String(id))
    }

    private var contacts: String? {
        guard let id = userId else { return nil }
        var parts: [String] = ["#" + String(id)]
        if let p = item["user_phone"].nonEmptyString { parts.append(p) }
        if let e = item["user_email"].nonEmptyString { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    private var versionText: String {
        guard let v = item["version"].nonEmptyString else { return "версия неизвестна" }
        if let b = item["build"].int, b > 0 { return v + " (" + String(b) + ")" }
        return v
    }

    private var device: String {
        var parts: [String] = []
        if let m = item["device_model"].nonEmptyString { parts.append(m) }
        if let o = item["os_version"].nonEmptyString { parts.append(o) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var appLine: String {
        (item["app_title"].nonEmptyString ?? "Приложение") + " · " + (item["platform_title"].nonEmptyString ?? "")
    }

    private var datesLine: String {
        "Последний запуск " + Fmt.date(item["last_seen"]) + " · впервые " + Fmt.day(item["first_seen"].string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(who)
                    .font(.body.weight(.semibold))
                    .foregroundColor(userId == nil ? Brand.muted : Brand.text)
                Spacer(minLength: 6)
                Text(versionText)
                    .font(.subheadline.weight(.semibold))
            }
            if let c = contacts {
                Text(c)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(appLine)
                .font(.subheadline)
            Text(device)
                .font(.caption)
                .foregroundColor(Brand.muted)
            Text(datesLine)
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
