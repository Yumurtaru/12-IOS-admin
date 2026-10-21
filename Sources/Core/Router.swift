import SwiftUI

/// Куда вести внутри вкладки «Ещё».
enum MoreRoute: Hashable {
    /// Раздел с необязательным id объекта (deep link) и вкладкой внутри раздела
    /// (`subtab` — rawValue вкладки, см. AdminSection.makeRoot; nil — по умолчанию).
    case section(AdminSection, openId: Int?, subtab: String? = nil)
    /// «Настройки приложения».
    case appSettings
}

/// Навигация приложения: выбранная вкладка и переходы по уведомлениям/ссылкам.
///
/// ```
/// @EnvironmentObject var router: AppRouter
/// router.open(section: .shops, id: 42)    // откроет вкладку «Магазины» и ShopsRootView(openId: 42)
/// router.open(section: .complaints)       // «Ещё» → «Жалобы»
/// router.open(section: .registrations, subtab: "publish")  // «Заявки магазинов» → «Публикация»
/// ```
/// Разделы «Сводка», «Магазины», «Заказы» живут на своих вкладках, остальные —
/// в стеке вкладки «Ещё». При переходе корневой экран раздела создаётся заново
/// с `openId`, а стек вкладки сбрасывается.
@MainActor
final class AppRouter: ObservableObject {
    /// Единственный экземпляр.
    static let shared = AppRouter()

    /// Вкладки нижней панели.
    enum Tab: Hashable {
        case dashboard, inbox, shops, orders, more
    }

    /// Выбранная вкладка.
    @Published var tab: Tab = .dashboard
    /// Стек вкладки «Ещё».
    @Published var morePath: [MoreRoute] = []
    /// Поколение корня вкладки: меняется при переходе — стек вкладки пересоздаётся.
    @Published private(set) var generation: [Tab: Int] = [:]
    /// id объекта, который нужно открыть на корне вкладки (deep link).
    @Published private(set) var openIds: [Tab: Int] = [:]

    private init() {}

    /// Вкладка, на которой живёт раздел (nil — раздел открывается в «Ещё»).
    static func tab(for section: AdminSection) -> Tab? {
        switch section {
        case .dashboard: return .dashboard
        case .shops: return .shops
        case .orders: return .orders
        default: return nil
        }
    }

    /// Открыть раздел (и объект в нём). `subtab` — вкладка внутри раздела
    /// (учитывается для разделов из «Ещё»; у «Сводки», «Магазинов», «Заказов» её нет).
    func open(section: AdminSection, id: Int? = nil, subtab: String? = nil) {
        if let t = AppRouter.tab(for: section) {
            if let id = id { openIds[t] = id } else { openIds[t] = nil }
            generation[t] = (generation[t] ?? 0) + 1
            tab = t
            return
        }
        let route = MoreRoute.section(section, openId: id, subtab: subtab)
        // Тот же переход ещё раз (второй push о той же организации) — путь не
        // меняется, и SwiftUI ничего бы не открыл. Новое поколение пересоздаёт
        // стек «Ещё» (MainTabView: .id), и раздел/чат открывается заново.
        if morePath == [route] { generation[.more] = (generation[.more] ?? 0) + 1 }
        morePath = [route]
        tab = .more
    }

    /// id для корня вкладки (передаётся корню вкладки как openId).
    func openId(for t: Tab) -> Int? { openIds[t] }

    /// Поколение корня вкладки (для `.id(...)` стека).
    func generationOf(_ t: Tab) -> Int { generation[t] ?? 0 }

    /// Ссылка `yumurta-admin://section/<ключ>/<id>?tab=<вкладка>` (id и tab необязательны).
    func handle(url: URL) {
        guard url.scheme == "yumurta-admin" else { return }
        var parts = url.pathComponents.filter { $0 != "/" }
        if let host = url.host, !host.isEmpty { parts.insert(host, at: 0) }
        guard parts.count >= 2, parts[0] == "section", let section = AdminSection(rawValue: parts[1]) else { return }
        let id = parts.count >= 3 ? Int(parts[2]) : nil
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let sub = items.first(where: { $0.name == "tab" })?.value
        open(section: section, id: id, subtab: sub)
    }

    /// Тап по уведомлению: локальному (userInfo["section"], ["id"], ["subtab"]) или серверному (["type"]).
    func handleNotification(userInfo: [AnyHashable: Any]) {
        let id = AppRouter.intValue(userInfo["id"])
        if let key = userInfo["section"] as? String, let section = AdminSection(rawValue: key) {
            open(section: section, id: id, subtab: userInfo["subtab"] as? String)
            return
        }
        let type = (userInfo["type"] as? String) ?? ""
        if let target = AppRouter.sectionForPushType(type) {
            // Ключ id у каждого типа свой (П-29.2): id, shop_id, ad_id. Нет ключа — раздел
            // без объекта (например, лицензии: id документа ≠ id заявки, раздел его не откроет).
            var objectId: Int? = nil
            if let key = target.idKey { objectId = AppRouter.intValue(userInfo[key]) }
            // Прежнее поведение shop_publish_request: shop_id, а если его нет — id.
            if objectId == nil && type == "shop_publish_request" { objectId = id }
            open(section: target.section, id: objectId, subtab: target.subtab)
            return
        }
        tab = .inbox
    }

    /// Серверные типы push → раздел, ключ id в payload (nil — без объекта) и вкладка раздела.
    /// Типы — ответ сервера на П-29.2: data {type, id} строками (+ shop_id / ad_id, где есть).
    /// Незнакомый тип открывает вкладку «Заявки».
    static func sectionForPushType(_ type: String) -> (section: AdminSection, idKey: String?, subtab: String?)? {
        switch type {
        case "shop_publish_request": return (.shops, "shop_id", nil)
        // Сообщение организации в «Сообщения продавцам» → сразу её чат.
        case "shop_support": return (.shopSupport, "shop_id", nil)
        case "shop_registration": return (.registrations, "id", nil)
        case "org_document": return (.registrations, nil, "documents")
        case "support_ticket": return (.support, "id", nil)
        case "complaint": return (.complaints, "id", nil)
        case "return_request": return (.returns, "id", nil)
        // id — заявка на пополнение магазина (wallet_topups.id), её показывает вкладка «Продавцы».
        case "topup_request": return (.wallets, "id", nil)
        // Вкладка «Жалобы» раздела «Объявления» (id жалобы объявлением не является).
        case "ad_report": return (.ads, nil, "reports")
        case "moderation_backlog": return (.reviews, nil, nil)
        // «Курьеры Yumurta» (core/CourierPool.php, notifyAdminsEvent):
        // pool_courier — новая заявка курьера, id = user_id курьера → сразу его карточка;
        // pool_problem — проблема с доставкой (id проблемы, есть shop_id) → вкладка «Проблемы»
        // и сразу карточка этой проблемы; pool_complaint — жалоба по вызову (id жалобы,
        // есть call_id) → вкладка «Жалобы» и карточка жалобы. Карточки по id —
        // GET /api/admin/pool/problems|complaints/{id} (волна А92, П-45 №2); 404 или старый
        // сервер без них — остаётся вкладка (CouriersRootView, CourierIssueDetailView).
        case "pool_courier": return (.couriers, "id", nil)
        case "pool_problem": return (.couriers, "id", "problems")
        case "pool_complaint": return (.couriers, "id", "complaints")
        default: return nil
        }
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
