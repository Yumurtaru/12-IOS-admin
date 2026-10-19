import SwiftUI
import UIKit

/// Запись журнала целиком: кто, когда, что, с какого IP и что записано в new_json.
///
/// П-29.5: при правке магазина, промокода, категории, города, жалобы, страницы и
/// модерации отзыва сервер пишет и прежние значения (old_json) — тогда экран
/// показывает «Было» / «Стало» по каждому полю. У старых записей old_json = null.
struct AuditEntryView: View {
    let entry: JSON

    init(entry: JSON) {
        self.entry = entry
    }

    private var entryId: Int { entry["id"].intValue }
    private var action: String { entry["action"].stringValue }
    private var entityType: String { entry["entity_type"].stringValue }
    private var entityId: Int { entry["entity_id"].intValue }

    /// new_json приходит строкой из базы — разбираем; объект — берём как есть.
    private var details: JSON? {
        let v = entry["new_json"]
        if v.isObject || v.isArray { return v }
        guard let s = v.nonEmptyString, let data = s.data(using: .utf8) else { return nil }
        return JSON.parse(data)
    }

    private var detailsText: String? { entry["new_json"].nonEmptyString }

    /// old_json (П-29.5) — так же: строка из базы или объект; null у старых записей.
    private var oldDetails: JSON? {
        let v = entry["old_json"]
        if v.isObject || v.isArray { return v }
        guard let s = v.nonEmptyString, let data = s.data(using: .utf8) else { return nil }
        return JSON.parse(data)
    }

    private var whoText: String {
        let name = entry["name"].nonEmptyString ?? "Система"
        guard let uid = entry["user_id"].int, uid > 0 else { return name }
        return name + " (#" + String(uid) + ")"
    }

    private var actionText: String {
        let label = AuditLabels.action(action)
        return label == action ? action : label + " · " + action
    }

    private var objectText: String {
        let label = AuditLabels.entity(entityType)
        let base = label == entityType ? entityType : label + " · " + entityType
        return entityId > 0 ? base + " #" + String(entityId) : base
    }

    var body: some View {
        List {
            Section("Запись") {
                KVRow("Номер", "#" + String(entryId), copyable: true)
                KVRow("Когда", Fmt.date(entry["created_at"]))
                KVRow("Точное время", entry["created_at"].string, copyable: true)
                KVRow("Кто", whoText)
                KVRow("Действие", actionText)
                KVRow("Объект", objectText, copyable: true)
                KVRow("IP", entry["ip"].string, copyable: true)
            }
            linkSection
            diffSection
            detailsSection
            Section {
                JSONInspectorView(entry)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Запись #" + String(entryId))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Переход к объекту записи, если для него есть экран.
    @ViewBuilder
    private var linkSection: some View {
        if entityId > 0, let target = AuditLabels.linkTarget(entityType) {
            Section {
                NavigationLink {
                    AuditObjectDestination(target: target, id: entityId)
                } label: {
                    Label(target.title + " #" + String(entityId), systemImage: target.symbol)
                }
            }
        }
    }

    /// «Было» / «Стало» по полям (П-29.5). Нет old_json — секции нет.
    @ViewBuilder
    private var diffSection: some View {
        if let old = oldDetails {
            let new = details ?? .null
            if old.isObject && (new.isObject || new.isNull) {
                Section {
                    ForEach(AuditEntryView.diffKeys(old: old, new: new), id: \.self) { key in
                        AuditDiffRow(key: key, old: old.object[key], new: new.object[key])
                    }
                } header: {
                    Text("Что изменилось")
                }
            } else {
                Section {
                    JSONInspectorView(old, title: "Было", expanded: true)
                } header: {
                    Text("Прежние значения")
                }
            }
        }
    }

    /// Поля для сравнения: сначала из «Стало», затем те, что есть только в «Было».
    static func diffKeys(old: JSON, new: JSON) -> [String] {
        var keys = JSONNodeList.orderedKeys(new.object)
        for k in JSONNodeList.orderedKeys(old.object) where !keys.contains(k) {
            keys.append(k)
        }
        return keys
    }

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            if let d = details, d.isObject || d.isArray {
                // Есть «Было» — сравнение уже выше, полный список новых значений свёрнут.
                JSONInspectorView(d, title: "Новые значения", expanded: oldDetails == nil)
            } else if let t = detailsText {
                Text(t)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("Подробностей нет")
                    .foregroundColor(Brand.muted)
            }
            if let t = detailsText {
                Button {
                    UIPasteboard.general.string = t
                    Haptics.tap()
                } label: {
                    Label("Скопировать подробности", systemImage: "doc.on.doc")
                }
            }
        } header: {
            Text("Что записано")
        } footer: {
            Text("Прежние значения сервер записывает при правке магазина, промокода, категории, города, жалобы, страницы и модерации отзыва; у остальных и у старых записей — только новые.")
        }
    }
}

/// Одно поле записи: «Было» → «Стало» (П-29.5). Нет значения — «—».
struct AuditDiffRow: View {
    let key: String
    let old: JSON?
    let new: JSON?

    init(key: String, old: JSON?, new: JSON?) {
        self.key = key
        self.old = old
        self.new = new
    }

    private var oldText: String { old?.raw ?? "—" }
    private var newText: String { new?.raw ?? "—" }
    /// old_json — снимок строки базы («1», «12.50»), new_json — типизированный (true, 12.5):
    /// сравниваем по смыслу, иначе одинаковые значения подсвечивались бы как изменённые.
    private var changed: Bool { !AuditDiffRow.sameValue(old, new) }

    static func sameValue(_ a: JSON?, _ b: JSON?) -> Bool {
        let x = a ?? .null
        let y = b ?? .null
        if x.isNull || y.isNull { return x.isNull && y.isNull }
        // true/false против "1"/"0" (и 1/0) — одно и то же.
        if case .bool(let bx) = x, let by = boolLike(y) { return bx == by }
        if case .bool(let by) = y, let bx = boolLike(x) { return bx == by }
        // Числа — численно («12.50» == 12.5).
        if let dx = numberLike(x), let dy = numberLike(y) { return dx == dy }
        return x.raw == y.raw
    }

    /// Значение как число: число или строка-число; иначе nil.
    private static func numberLike(_ j: JSON) -> Decimal? {
        switch j {
        case .number, .string: return j.decimal
        default: return nil
        }
    }

    /// Значение как логическое: bool, 1/0, «1»/«0», «true»/«false»; иначе nil.
    private static func boolLike(_ j: JSON) -> Bool? {
        switch j {
        case .bool(let b): return b
        case .number(let d):
            if d == 1 { return true }
            if d == 0 { return false }
            return nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t == "1" || t == "true" { return true }
            if t == "0" || t == "false" { return false }
            return nil
        default:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.caption.monospaced())
                .foregroundColor(Brand.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Было")
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
                    .frame(width: 40, alignment: .leading)
                Text(oldText)
                    .font(.footnote)
                    .foregroundColor(changed ? Brand.red : Brand.text)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Стало")
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
                    .frame(width: 40, alignment: .leading)
                Text(newText)
                    .font(.footnote)
                    .foregroundColor(changed ? Brand.green : Brand.text)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Экран объекта, на который ссылается запись журнала.
struct AuditObjectDestination: View {
    let target: AuditLinkTarget
    let id: Int

    init(target: AuditLinkTarget, id: Int) {
        self.target = target
        self.id = id
    }

    var body: some View {
        switch target {
        case .shop: ShopDetailView(id: id)
        case .user: UserDetailView(id: id)
        case .order: OrderDetailView(id: id)
        }
    }
}

/// Куда можно перейти из записи журнала.
enum AuditLinkTarget {
    case shop, user, order

    var title: String {
        switch self {
        case .shop: return "Открыть магазин"
        case .user: return "Открыть пользователя"
        case .order: return "Открыть заказ"
        }
    }

    var symbol: String {
        switch self {
        case .shop: return "building.2"
        case .user: return "person"
        case .order: return "list.bullet.rectangle"
        }
    }
}

/// Русские подписи кодов журнала. Незнакомый код показывается как есть.
enum AuditLabels {
    static func action(_ code: String) -> String {
        actions[code] ?? code
    }

    static func entity(_ code: String) -> String {
        if code.isEmpty { return "—" }
        return entities[code] ?? code
    }

    static func linkTarget(_ entity: String) -> AuditLinkTarget? {
        switch entity {
        case "shop": return .shop
        case "user": return .user
        case "order": return .order
        default: return nil
        }
    }

    private static let actions: [String: String] = [
        "create": "Создание", "update": "Изменение", "delete": "Удаление",
        "block": "Блокировка", "unblock": "Разблокировка", "moderate": "Модерация",
        "publish": "Публикация", "publish_reject": "Отказ в публикации", "import": "Импорт",
        "enter_panel": "Вход в панель магазина", "enter_ticket": "Ссылка входа в кабинет магазина", "grant_admin": "Выдача прав администратора",
        "revoke_admin": "Снятие прав администратора", "topup": "Пополнение",
        "confirm_topup": "Подтверждение пополнения", "reject_topup": "Отказ в пополнении",
        "topup_reject": "Отказ в пополнении", "topup_recheck": "Перепроверка пополнения",
        "resolve_topup_credit": "Зачисление пополнения", "resolve_topup_reject": "Отклонение пополнения",
        "wallet_correct": "Корректировка кошелька", "payout": "Выплата", "payout_paid": "Выплата проведена",
        "payout_cancel": "Отмена выплаты", "return_paid": "Возврат оплачен",
        "referral_debt_settle": "Погашение реферального долга", "referral_debt_unsettle": "Отмена погашения долга",
        "support_reply": "Ответ в поддержке", "support_close": "Закрытие обращения",
        "template_update": "Изменение шаблона", "page_create": "Создание страницы", "page_update": "Изменение страницы",
        "plan_create": "Создание тарифа", "plan_update": "Изменение тарифа", "banner_create": "Создание баннера",
        "campaign": "Рассылка", "backfill_charges": "Досписание сборов", "backfill_charges_start": "Начало досписания сборов",
        "danger_confirm_failed": "Неверное подтверждение опасной операции",
        "db_sql_write": "SQL-запрос с изменением", "db_row_insert": "Добавление строки в базу",
        "db_row_update": "Правка строки в базе", "db_row_delete": "Удаление строки из базы",
        "db_backup": "Копия базы", "site_backup": "Архив сайта", "db_backup_delete": "Удаление копии",
        "db_backup_ticket": "Разрешение на скачивание копии", "db_backup_download": "Скачивание копии",
        "db_restore": "Восстановление базы", "db_import": "Импорт в базу",
    ]

    private static let entities: [String: String] = [
        "shop": "Магазин", "user": "Пользователь", "order": "Заказ", "return": "Возврат",
        "review": "Отзыв", "review_reply": "Ответ на отзыв", "complaint": "Жалоба", "city": "Город",
        "category": "Категория", "promo": "Промокод", "banner": "Баннер", "page": "Страница", "plan": "Тариф",
        "settings": "Настройки", "ad": "Объявление", "ad_category": "Категория объявлений",
        "ad_report": "Жалоба на объявление", "wallet_topup": "Пополнение кошелька",
        "user_wallet_topup": "Пополнение кошелька клиента", "support_ticket": "Обращение в поддержку",
        "notification_template": "Шаблон уведомления", "org_document": "Документ организации",
        "marketing": "Маркетинг", "finance": "Финансы", "database": "База данных", "admin": "Администратор",
    ]
}
