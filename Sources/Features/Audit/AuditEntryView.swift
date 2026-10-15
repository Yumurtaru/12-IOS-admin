import SwiftUI
import UIKit

/// Запись журнала целиком: кто, когда, что, с какого IP и что записано в new_json.
///
/// Сервер пишет в журнал только НОВЫЕ значения (колонка new_json); прежних
/// значений (old_json) в журнале площадки нет — экран так и говорит.
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

    @ViewBuilder
    private var detailsSection: some View {
        Section {
            if let d = details, d.isObject || d.isArray {
                JSONInspectorView(d, title: "Новые значения", expanded: true)
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
            Text("Журнал хранит только новые значения; прежние значения сервер не записывает.")
        }
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
        "enter_panel": "Вход в панель магазина", "grant_admin": "Выдача прав администратора",
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
