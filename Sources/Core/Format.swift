import Foundation
import UIKit

/// Форматирование для показа: деньги, даты (по Москве), телефоны, числа, статусы.
///
/// ```
/// Fmt.money(row["total"])          // «1 234,50 ₽», «—» для null
/// Fmt.date(row["created_at"].string) // «14 окт, 12:05» (другой год — «14 окт 2025, 12:05»)
/// Fmt.phone("79381121191")         // «+7 (938) 112-11-91»
/// Fmt.plural(5, "заказ", "заказа", "заказов") // «5 заказов»
/// ```
enum Fmt {
    /// Часовой пояс площадки: сервер пишет время по Москве, админ работает по Москве.
    static let moscow: TimeZone = TimeZone(identifier: "Europe/Moscow") ?? TimeZone.current

    // MARK: - Деньги и числа

    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ru_RU")
        f.groupingSeparator = "\u{00A0}"
        f.decimalSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ru_RU")
        f.groupingSeparator = "\u{00A0}"
        f.decimalSeparator = ","
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    /// «1 234,50 ₽»; целые суммы — без копеек: «1 234 ₽». nil → «—».
    static func money(_ v: Decimal?) -> String {
        guard let value = v else { return "—" }
        let whole = value == value.rounded0
        let f = whole ? intFormatter : moneyFormatter
        let s = f.string(from: NSDecimalNumber(decimal: value)) ?? "0"
        return s + "\u{00A0}₽"
    }

    /// Деньги из поля JSON (число или строка "12.50"). null → «—».
    static func money(_ j: JSON) -> String { money(j.decimal) }

    /// Со знаком: «+1 000 ₽» / «−250 ₽».
    static func moneySigned(_ v: Decimal?) -> String {
        guard let value = v else { return "—" }
        if value < 0 { return "−" + money(-value) }
        return "+" + money(value)
    }

    /// Число с разделителем тысяч: «12 345», «12,5».
    static func number(_ v: Decimal?) -> String {
        guard let value = v else { return "—" }
        return intFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "0"
    }

    /// Целое с разделителем тысяч.
    static func number(_ v: Int) -> String { number(Decimal(v)) }

    /// Число из поля JSON.
    static func number(_ j: JSON) -> String { number(j.decimal) }

    /// Строгий разбор числа из поля ввода: «1 500,5» → 1500.5; мусор → nil.
    /// Пробелы убираются, запятая = точка, не больше `maxFraction` знаков после неё.
    static func parseDecimal(_ s: String, maxFraction: Int = 2) -> Decimal? {
        let t = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        var body = Substring(t)
        if body.hasPrefix("-") { body = body.dropFirst() }
        func digits(_ part: Substring) -> Bool {
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !body.isEmpty, parts.count <= 2, digits(parts[0]) else { return nil }
        if parts.count == 2 {
            guard digits(parts[1]), parts[1].count <= maxFraction else { return nil }
        }
        return Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Decimal → текст для поля ввода: «12,5» (без разделителя тысяч).
    static func decimalInput(_ v: Decimal?) -> String {
        guard let value = v else { return "" }
        let s = NSDecimalNumber(decimal: value).stringValue
        return s.replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Даты

    private static func formatter(_ format: String, _ locale: String = "ru_RU") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.timeZone = moscow
        f.dateFormat = format
        return f
    }

    private static let serverDateTime = formatter("yyyy-MM-dd HH:mm:ss", "en_US_POSIX")
    private static let serverDateTimeShort = formatter("yyyy-MM-dd HH:mm", "en_US_POSIX")
    private static let serverDate = formatter("yyyy-MM-dd", "en_US_POSIX")
    private static let iso = ISO8601DateFormatter()
    private static let timeOut = formatter("HH:mm", "en_US_POSIX")
    /// Свои сокращения месяцев: системные дают «окт.» с точкой и разные на разных версиях iOS.
    private static let months = ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]

    private static var moscowCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = moscow
        return cal
    }

    /// «14 окт» или «14 окт 2025».
    private static func dayText(_ d: Date, withYear: Bool) -> String {
        let c = moscowCalendar.dateComponents([.day, .month, .year], from: d)
        let m = months[max(0, min(11, (c.month ?? 1) - 1))]
        let base = String(c.day ?? 1) + " " + m
        return withYear ? base + " " + String(c.year ?? 0) : base
    }

    /// Разобрать дату сервера: «Y-m-d H:i:s», «Y-m-d H:i», «Y-m-d» (по Москве) или ISO 8601.
    static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = serverDateTime.date(from: s) { return d }
        if let d = serverDateTimeShort.date(from: s) { return d }
        if let d = serverDate.date(from: s) { return d }
        return iso.date(from: s)
    }

    private static func isThisYear(_ date: Date) -> Bool {
        let cal = moscowCalendar
        return cal.component(.year, from: date) == cal.component(.year, from: Date())
    }

    /// «14 окт, 12:05» по Москве; другой год — «14 окт 2025, 12:05». Не дата — как есть, nil → «—».
    static func date(_ s: String?) -> String {
        guard let d = parseDate(s) else { return s?.isEmpty == false ? (s ?? "—") : "—" }
        return dayText(d, withYear: !isThisYear(d)) + ", " + timeOut.string(from: d)
    }

    /// Дата из поля JSON.
    static func date(_ j: JSON) -> String { date(j.string) }

    /// «14 окт» (другой год — «14 окт 2025») — для дат без времени.
    static func day(_ s: String?) -> String {
        guard let d = parseDate(s) else { return s?.isEmpty == false ? (s ?? "—") : "—" }
        return dayText(d, withYear: !isThisYear(d))
    }

    /// «12:05» по Москве.
    static func time(_ s: String?) -> String {
        guard let d = parseDate(s) else { return s ?? "—" }
        return timeOut.string(from: d)
    }

    /// Date → «yyyy-MM-dd HH:mm:ss» по Москве (для отправки на сервер).
    static func serverDateTime(_ d: Date) -> String { serverDateTime.string(from: d) }

    /// Date → «yyyy-MM-dd» по Москве (фильтры from/to).
    static func ymd(_ d: Date) -> String { serverDate.string(from: d) }

    // MARK: - Телефон и прочее

    /// «79381121191» / «89381121191» → «+7 (938) 112-11-91». Иначе — как есть.
    static func phone(_ s: String?) -> String {
        guard let raw = s, !raw.isEmpty else { return "—" }
        var digits = raw.filter { $0.isNumber }
        if digits.count == 11, digits.hasPrefix("8") { digits = "7" + digits.dropFirst() }
        if digits.count == 10 { digits = "7" + digits }
        guard digits.count == 11, digits.hasPrefix("7") else { return raw }
        let a = Array(digits)
        let code = String(a[1...3]), p1 = String(a[4...6]), p2 = String(a[7...8]), p3 = String(a[9...10])
        return "+7 (" + code + ") " + p1 + "-" + p2 + "-" + p3
    }

    /// URL для звонка (tel:) или nil.
    static func phoneURL(_ s: String?) -> URL? {
        guard let raw = s else { return nil }
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 6 else { return nil }
        return URL(string: "tel:" + digits)
    }

    /// «5 заказов» — число и слово в нужной форме.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        number(n) + " " + RuPlural.form(n, one, few, many)
    }

    /// «да» / «нет» / «—».
    static func yesNo(_ b: Bool?) -> String {
        guard let b = b else { return "—" }
        return b ? "да" : "нет"
    }

    /// Русская подпись частого статуса (pending → «Ожидает» …). Незнакомый — как есть.
    static func statusLabel(_ status: String?) -> String {
        guard let s = status, !s.isEmpty else { return "—" }
        return statusLabels[s] ?? s
    }

    private static let statusLabels: [String: String] = [
        "pending": "Ожидает", "approved": "Одобрено", "rejected": "Отклонено",
        "more_info_needed": "Нужны данные", "active": "Активен", "blocked": "Заблокирован",
        "review": "На проверке", "draft": "Черновик", "hidden": "Скрыт", "inactive": "Неактивен",
        "open": "Открыта", "reviewing": "На рассмотрении", "resolved": "Решена", "closed": "Закрыта",
        "answered": "Отвечено", "new": "Новый", "accepted": "Принят", "preparing": "Готовится",
        "ready": "Готов", "in_delivery": "В пути", "done": "Выполнен", "cancelled": "Отменён",
        "paid": "Выплачено", "confirmed": "Подтверждено", "charged": "Списано", "refunded": "Возвращено",
        "suspended": "Приостановлен", "expired": "Истёк", "published": "Опубликовано",
    ]
}

/// Русские формы слова по числу: 1 заказ, 2 заказа, 5 заказов.
enum RuPlural {
    /// Форма для n: `RuPlural.form(n, "заявка", "заявки", "заявок")`.
    static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let a = abs(n) % 100
        let b = a % 10
        if a >= 11 && a <= 14 { return many }
        if b == 1 { return one }
        if b >= 2 && b <= 4 { return few }
        return many
    }
}

/// Тактильный отклик.
enum Haptics {
    /// Успешное действие.
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// Ошибка.
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    /// Предупреждение (опасное действие).
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    /// Лёгкий щелчок (выбор, переключение).
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

extension Decimal {
    /// Целая часть (округление к нулю).
    var rounded0: Decimal {
        var src = self
        var out = Decimal()
        NSDecimalRound(&out, &src, 0, self < 0 ? .up : .down)
        return out
    }
}
