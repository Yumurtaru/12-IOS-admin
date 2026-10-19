import SwiftUI

/// Подписи и цвета раздела «Магазины» (общие для Shops и Registrations).
/// Значения — как на сервере (core/helpers.php shopStatusLabel, admin.js).
enum ShopsLabels {
    /// Статус организации (shops.status) по-русски.
    static func status(_ s: String?) -> String {
        switch s ?? "" {
        case "pending": return "Заявка на рассмотрении"
        // Подписи — дословно shopStatusLabel() сайта (волна А75: новые организации
        // сразу в draft, админка показывает «Не опубликована — заполняется»).
        case "draft": return "Не опубликована — заполняется"
        case "review": return "На проверке у администратора"
        case "active": return "Опубликована"
        case "paused": return "На паузе"
        case "blocked": return "Заблокирована"
        case "": return "—"
        default: return s ?? "—"
        }
    }

    /// Цвет статуса организации.
    static func statusColor(_ s: String?) -> Color {
        switch s ?? "" {
        case "active": return Brand.green
        case "review", "pending": return Brand.amber
        case "draft": return Brand.blue
        case "blocked": return Brand.red
        default: return Brand.muted
        }
    }

    /// Варианты фильтра «Статус» как на сайте (admin/shops.php).
    static let statusFilter: [PickerOption] = [
        PickerOption(value: "active", label: "Опубликованы"),
        PickerOption(value: "draft", label: "Не опубликованы"),
        PickerOption(value: "review", label: "Ждут публикации"),
        PickerOption(value: "pending", label: "Модерация заявки"),
        PickerOption(value: "blocked", label: "Заблокированы"),
        PickerOption(value: "paused", label: "Пауза"),
    ]

    /// Статусы, которые можно выставить в карточке (PUT /api/admin/shops/{id}).
    static let editableStatuses: [String] = ["active", "pending", "blocked", "paused"]

    /// Режим работы (shops.mode).
    static func mode(_ m: String?) -> String {
        switch m ?? "" {
        case "storefront": return "Витрина"
        case "shop": return "Магазин"
        case "restaurant": return "Ресторан"
        case "": return "—"
        default: return m ?? "—"
        }
    }

    /// Тип каталога (shops.type).
    static func type(_ t: String?) -> String {
        switch t ?? "" {
        case "shop": return "Магазины"
        case "cafe": return "Рестораны и кафе"
        case "service": return "Услуги"
        case "lodging": return "Жильё"
        case "": return "—"
        default: return t ?? "—"
        }
    }

    /// Форма организации.
    static func orgType(_ o: String?) -> String {
        switch o ?? "" {
        case "ip": return "ИП"
        case "ooo": return "ООО"
        case "self_employed": return "Самозанятый"
        case "": return "—"
        default: return o ?? "—"
        }
    }

    /// Тип заявки на регистрацию (shop_registrations.shop_type).
    static func registrationType(_ t: String?) -> String {
        switch t ?? "" {
        case "seller": return "Магазин"
        case "service": return "Услуги"
        case "kafe": return "Кафе / ресторан"
        case "lodging": return "Жильё"
        case "": return "—"
        default: return t ?? "—"
        }
    }

    /// Статус заявки на регистрацию.
    static func registrationStatus(_ s: String?) -> String {
        switch s ?? "" {
        case "pending": return "На рассмотрении"
        case "approved": return "Одобрено"
        case "rejected": return "Отклонено"
        case "more_info_needed": return "Нужны данные"
        case "": return "—"
        default: return s ?? "—"
        }
    }

    /// Заявка одобрена самой площадкой при регистрации (волна А75: auto_approved = 1).
    static func registrationAutoApproved(_ reg: JSON) -> Bool {
        reg["status"].string == "approved" && reg["auto_approved"].boolValue
    }

    /// Подпись статуса заявки с пометкой «автоматически», как в списке заявок на сайте.
    static func registrationStatusLabel(_ reg: JSON) -> String {
        let base = registrationStatus(reg["status"].string)
        return registrationAutoApproved(reg) ? base + " · автоматически" : base
    }

    /// Тип движения по кошельку магазина (как в admin.js WTX).
    static func walletType(_ t: String?) -> String {
        switch t ?? "" {
        case "topup": return "Пополнение"
        case "commission": return "Комиссия"
        case "service_fee_received": return "Сервисный сбор"
        case "service_fee_shop_pays": return "Сервисный сбор (магазин)"
        case "subscription": return "Подписка"
        case "refund_commission": return "Возврат комиссии"
        case "": return "—"
        default: return t ?? "—"
        }
    }

    /// «10 %» или «19 ₽».
    static func rate(_ value: JSON, type: String?) -> String {
        let v = Fmt.number(value)
        return type == "fixed" ? v + " ₽" : v + " %"
    }

    /// Адрес витрины организации на сайте.
    static func storefrontURL(slug: String?) -> URL? {
        guard let s = slug, !s.isEmpty else { return nil }
        let enc = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
        return URL(string: "https://yumurta.ru/shop/" + enc)
    }

    /// Веб-админка (вход в панель организации работает только там — см. ShopDetailView).
    static let webAdminShopsURL = URL(string: "https://yumurta.ru/admin/shops.php")

    /// Скопировать JSON-объект, заменив поля.
    static func patched(_ j: JSON, _ changes: [String: JSON]) -> JSON {
        var o = j.object
        for (k, v) in changes { o[k] = v }
        return .object(o)
    }
}

/// Строка «название — значение» с цифрой, для сетки показателей.
struct ShopsMetricTile: View {
    let title: String
    let value: String
    let sub: String?
    let tint: Color?

    init(_ title: String, _ value: String, sub: String? = nil, tint: Color? = nil) {
        self.title = title
        self.value = value
        self.sub = sub
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(2)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundColor(tint ?? Brand.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let s = sub {
                Text(s)
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Brand.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
