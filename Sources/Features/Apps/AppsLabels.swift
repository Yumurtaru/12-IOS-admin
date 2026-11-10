import SwiftUI

/// Подписи, цвета и форматы раздела «Приложения» (статистика клиентов и приложений).
///
/// Даты сервера приходят строкой «Y-m-d H:i:s» по Москве (`Fmt.parseDate` читает их как момент
/// времени). Показываем их по часовому поясу и календарю УСТРОЙСТВА: «сегодня в 12:40»,
/// «вчера в 09:05», «3 дня назад», дальше — «14 окт 2026».
enum AppsFmt {
    // MARK: - Названия

    static func appTitle(_ app: String?) -> String {
        switch app ?? "" {
        case "client": return "Покупатель"
        case "seller": return "Продавец"
        case "courier": return "Курьер"
        case "": return "Приложение"
        default: return app ?? "Приложение"
        }
    }

    static func platformTitle(_ platform: String?) -> String {
        switch platform ?? "" {
        case "android": return "Android"
        case "ios": return "iOS"
        case "web": return "Web push (сайт)"
        case "site": return "Кабинет на сайте"
        case "all": return "Все платформы"
        case "": return "—"
        default: return platform ?? "—"
        }
    }

    static func stateTitle(_ state: String?) -> String {
        switch state ?? "" {
        case "latest": return "Последняя версия"
        case "old": return "Устарела"
        case "below_min": return "Ниже минимальной"
        default: return "Версия неизвестна"
        }
    }

    static func stateColor(_ state: String?) -> Color {
        switch state ?? "" {
        case "latest": return Brand.green
        case "old": return Brand.amber
        case "below_min": return Brand.red
        default: return Brand.muted
        }
    }

    /// true для версий, которые надо обновить.
    static func isOutdated(_ state: String?) -> Bool {
        state == "old" || state == "below_min"
    }

    static func activityTitle(_ activity: String?) -> String {
        switch activity ?? "" {
        case "active": return "Активен"
        case "sleeping": return "Спит"
        case "lost": return "Ушёл"
        default: return "Нет данных"
        }
    }

    static func activityColor(_ activity: String?) -> Color {
        switch activity ?? "" {
        case "active": return Brand.green
        case "sleeping": return Brand.amber
        case "lost": return Brand.red
        default: return Brand.muted
        }
    }

    static func stationTitle(_ kind: String?, title: String?) -> String {
        if let t = title, !t.isEmpty { return t }
        switch kind ?? "" {
        case "kassa": return "Касса"
        case "station": return "Станция"
        case "": return "Устройство"
        default: return kind ?? "Устройство"
        }
    }

    // MARK: - Даты (по устройству)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()

    /// Целых календарных дней между датой и «сейчас» (по календарю устройства), не меньше 0.
    static func daysAgo(_ date: Date, now: Date = Date()) -> Int {
        let cal = Calendar.current
        let from = cal.startOfDay(for: date)
        let to = cal.startOfDay(for: now)
        let n = cal.dateComponents([.day], from: from, to: to).day ?? 0
        return max(0, n)
    }

    /// «сегодня в 12:40», «вчера в 09:05», «3 дня назад», «14 окт 2026». Нет даты — «нет данных».
    static func when(_ s: String?, now: Date = Date()) -> String {
        guard let d = Fmt.parseDate(s) else { return "нет данных" }
        let time = timeFormatter.string(from: d)
        let days = daysAgo(d, now: now)
        if d > now || days == 0 { return "сегодня в " + time }
        if days == 1 { return "вчера в " + time }
        if days < 30 {
            let word = RuPlural.form(days, "день", "дня", "дней")
            return String(days) + " " + word + " назад"
        }
        return dateFormatter.string(from: d)
    }

    /// Точная дата и время по устройству: «14 окт 2026, 12:40».
    static func exact(_ s: String?) -> String {
        guard let d = Fmt.parseDate(s) else { return "—" }
        return dateTimeFormatter.string(from: d)
    }

    /// Дата с подсказкой: «сегодня в 12:40» или «3 дня назад (14 окт 2026, 12:40)».
    static func whenWithExact(_ s: String?) -> String {
        guard let d = Fmt.parseDate(s) else { return "нет данных" }
        let short = when(s)
        if daysAgo(d) <= 1 { return short }
        return short + " (" + dateTimeFormatter.string(from: d) + ")"
    }

    /// «был сегодня» / «был вчера» / «был 3 дня назад» / «нет данных о визитах».
    static func seen(daysSince: Int?, lastSeen: String?) -> String {
        var days = daysSince
        if days == nil, let d = Fmt.parseDate(lastSeen) { days = daysAgo(d) }
        guard let n = days else { return "нет данных о визитах" }
        if n <= 0 { return "был сегодня" }
        if n == 1 { return "был вчера" }
        let word = RuPlural.form(n, "день", "дня", "дней")
        return "был " + String(n) + " " + word + " назад"
    }

    /// День «2026-11-01» → полдень этого дня по календарю устройства (для оси графика).
    static func dayDate(_ s: String) -> Date? {
        let head = String(s.prefix(10))
        let parts = head.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = 12
        return Calendar.current.date(from: c)
    }

    // MARK: - Ошибки

    /// 404 — сервер без раздела (сайт ещё не обновлён); остальное — текст ошибки.
    static func errorText(_ error: Error) -> String {
        if let e = error as? APIError, e.status == 404 {
            return "Обновите сайт: на сервере ещё нет этой функции раздела «Приложения»."
        }
        return APIError.describe(error)
    }

    /// Целое с пробелом-разделителем.
    static func num(_ n: Int) -> String { Fmt.number(n) }
}

/// Плитка с числом и подписью.
struct AppsStatTile: View {
    let title: String
    let value: String
    var color: Color = Brand.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(title)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Brand.chip.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// Сетка плиток, подстраивающаяся под размер шрифта.
struct AppsTileGrid<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            content
        }
    }
}

/// Чип-меню фильтра для списка клиентов.
struct AppsFilterChip: View {
    let title: String
    let options: [PickerOption]
    let selected: String
    let allLabel: String?
    let onSelect: (String) -> Void

    private var selectedOption: PickerOption? {
        options.first { $0.value == selected }
    }

    var body: some View {
        Menu {
            if let all = allLabel {
                Button {
                    onSelect("")
                } label: {
                    if selectedOption == nil { Label(all, systemImage: "checkmark") } else { Text(all) }
                }
            }
            ForEach(options) { opt in
                Button {
                    Haptics.tap()
                    onSelect(opt.value)
                } label: {
                    if selected == opt.value { Label(opt.label, systemImage: "checkmark") } else { Text(opt.label) }
                }
            }
        } label: {
            chipLabel
        }
        .accessibilityLabel(selectedOption.map { title + ": " + $0.label } ?? title)
    }

    private var chipLabel: some View {
        let active = selectedOption != nil
        let text = selectedOption.map { title + ": " + $0.label } ?? title
        return HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(active ? Brand.accent.opacity(0.15) : Brand.chip)
        .foregroundColor(active ? Brand.accent : Brand.text)
        .clipShape(Capsule())
    }
}
