import SwiftUI

/// Раздел «Сбои касс» (как /admin/station-crashes.php на сайте, admin-station-crashes.js):
/// последние сбои всех касс и Android-станций. Только чтение.
///
/// GET /api/admin/station-crashes?version=&page= →
///   data { items:[{id, shop_id, shop_name, station_name, at, received_at, app, app_version, arch, os,
///                  kind, message, stack, count}], versions:[{version, reports, total_count, last_at}],
///          total, page, pages } (30 на страницу).
/// Экран НЕ содержит NavigationStack (его даёт «Ещё»). `openId` не используется.
struct StationCrashesRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/station-crashes", searchParam: nil)

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Сбои касс", model: model, searchPrompt: nil, filters: filters,
                        emptyText: "Сбоев нет",
                        row: { item in StationCrashRow(item: item) },
                        destination: { item in StationCrashDetailView(item: item) })
    }

    /// Версии из ответа сервера: «1.33.0 — записей: 4, падений: 9». Версия «неизвестна» (пустая)
    /// фильтром не выбирается: пустое значение фильтра равно «без фильтра».
    private var filters: [ListFilter] {
        let options: [PickerOption] = model.lastData["versions"].array.compactMap { v in
            guard let ver = v["version"].nonEmptyString else { return nil }
            let label = ver + " — записей: " + Fmt.number(v["reports"].intValue)
                + ", падений: " + Fmt.number(v["total_count"].intValue)
            return PickerOption(value: ver, label: label)
        }
        return [ListFilter(key: "version", title: "Версия", options: options, allLabel: "Все версии")]
    }
}

/// Подписи типов сбоя (как на сайте).
enum StationCrashLabels {
    static func kind(_ k: String?) -> String {
        switch k ?? "" {
        case "ui_unhandled": return "ошибка окна"
        case "task_unobserved": return "фоновая задача"
        case "fatal": return "фатальный сбой"
        case "anr": return "зависание"
        case "": return "сбой"
        default: return k ?? "сбой"
        }
    }

    static func color(_ k: String?) -> Color {
        switch k ?? "" {
        case "fatal": return Brand.red
        case "anr": return Brand.amber
        default: return Brand.muted
        }
    }

    /// «Организация · касса».
    static func place(_ item: JSON) -> String {
        let shop = item["shop_name"].nonEmptyString ?? ("#" + String(item["shop_id"].intValue))
        if let st = item["station_name"].nonEmptyString { return shop + " · " + st }
        return shop
    }

    /// «Yumurta Касса · x64 · Windows 11».
    static func environment(_ item: JSON) -> String {
        let parts = [item["app"].nonEmptyString, item["arch"].nonEmptyString, item["os"].nonEmptyString]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// Строка списка: когда, где, версия, тип и текст сбоя.
struct StationCrashRow: View {
    let item: JSON

    private var versionLine: String {
        var s = "Версия " + (item["app_version"].nonEmptyString ?? "—")
        let n = item["count"].intValue
        if n > 1 { s += " · раз: " + Fmt.number(n) }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.date(item["at"]))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                StatusBadge(StationCrashLabels.kind(item["kind"].string), color: StationCrashLabels.color(item["kind"].string))
            }
            Text(StationCrashLabels.place(item))
                .font(.subheadline)
            Text(versionLine)
                .font(.caption)
                .foregroundColor(Brand.muted)
            Text(item["message"].stringValue)
                .font(.footnote)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}

/// Подробности сбоя: окружение, сообщение, стек.
struct StationCrashDetailView: View {
    let item: JSON

    var body: some View {
        List {
            Section {
                KVRow("Когда", Fmt.date(item["at"]))
                KVRow("Получен", Fmt.date(item["received_at"]))
                KVRow("Организация", item["shop_name"].nonEmptyString ?? ("#" + String(item["shop_id"].intValue)))
                KVRow("Касса / станция", item["station_name"].string)
                KVRow("Версия", item["app_version"].string)
                KVRow("Приложение", StationCrashLabels.environment(item))
                KVRow("Тип сбоя", StationCrashLabels.kind(item["kind"].string))
                KVRow("Раз", Fmt.number(item["count"].intValue))
            }
            Section("Сообщение") {
                Text(item["message"].nonEmptyString ?? "—")
                    .font(.footnote)
                    .textSelection(.enabled)
            }
            if let stack = item["stack"].nonEmptyString {
                Section("Стек") {
                    Text(stack)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Сбой")
        .navigationBarTitleDisplayMode(.inline)
    }
}
