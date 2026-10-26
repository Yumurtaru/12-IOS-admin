import SwiftUI

/// 29 разделов админки — в порядке меню сайта (admin/partials/layout.php).
///
/// `rawValue` — ключ раздела сайта (`$adminSection`), он же используется в
/// deep link `yumurta-admin://section/<rawValue>/<id>` и в уведомлениях.
/// `makeRoot(openId:)` — корневой экран раздела (`<Section>RootView`, параметр openId).
enum AdminSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard, registrations, shops, users, orders, returns, wallets, payouts, referrals
    case products, reviews, complaints, ads, cities, plans, banners, pages, templates
    // «Розыгрыши» (как /admin/giveaways.php на сайте, ручки /api/admin/giveaways*, волна А104):
    // участники, проведение розыгрыша, история. Номера телефонов по умолчанию скрыты.
    case campaigns, giveaways, support
    // Переписка организаций с поддержкой площадки (как /admin/shop-support.php на сайте).
    // Ключ с дефисом — как у страницы сайта; в ссылке: yumurta-admin://section/shop-support/<shop_id>.
    case shopSupport = "shop-support"
    // «Курьеры Yumurta» (как /admin/couriers.php на сайте, ручки /api/admin/pool/*):
    // заявки курьеров с фото и правами, курьеры, проблемы с доставкой, жалобы.
    // В ссылке: yumurta-admin://section/couriers/<user_id курьера>; вкладка — ?tab=problems|complaints,
    // с id и вкладкой problems/complaints id — проблема или жалоба (её карточка, волна А92).
    case couriers
    case reports, audit, staff, settings, database, parser

    var id: String { rawValue }

    /// Название как в меню сайта.
    var title: String {
        switch self {
        case .dashboard: return "Дашборд"
        case .registrations: return "Заявки магазинов"
        case .shops: return "Магазины"
        case .users: return "Пользователи"
        case .orders: return "Заказы"
        case .returns: return "Возвраты"
        case .wallets: return "Кошельки"
        case .payouts: return "Выплаты"
        case .referrals: return "Рефералы"
        case .products: return "Товары"
        case .reviews: return "Отзывы"
        case .complaints: return "Жалобы"
        case .ads: return "Объявления"
        case .cities: return "Города"
        case .plans: return "Тарифы"
        case .banners: return "Баннеры"
        case .pages: return "Страницы"
        case .templates: return "Шаблоны"
        case .campaigns: return "Рассылки"
        case .giveaways: return "Розыгрыши"
        case .support: return "Поддержка"
        case .shopSupport: return "Сообщения продавцам"
        case .couriers: return "Курьеры"
        case .reports: return "Отчёты"
        case .audit: return "Журнал"
        case .staff: return "Администраторы"
        case .settings: return "Настройки"
        case .database: return "База данных"
        case .parser: return "Парсинг"
        }
    }

    /// Значок SF Symbols (только символы, доступные в iOS 16).
    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .registrations: return "doc.text.magnifyingglass"
        case .shops: return "building.2"
        case .users: return "person.2"
        case .orders: return "list.bullet.rectangle"
        case .returns: return "arrow.uturn.left"
        case .wallets: return "wallet.pass"
        case .payouts: return "banknote"
        case .referrals: return "gift"
        case .products: return "shippingbox"
        case .reviews: return "star"
        case .complaints: return "exclamationmark.triangle"
        case .ads: return "megaphone"
        case .cities: return "mappin.and.ellipse"
        case .plans: return "crown"
        case .banners: return "photo.on.rectangle"
        case .pages: return "doc.text"
        case .templates: return "bell"
        case .campaigns: return "paperplane"
        case .giveaways: return "rosette"
        case .support: return "headphones"
        case .shopSupport: return "bubble.left.and.bubble.right"
        case .couriers: return "car"
        case .reports: return "chart.pie"
        case .audit: return "clock.arrow.circlepath"
        case .staff: return "checkmark.shield"
        case .settings: return "gearshape"
        case .database: return "cylinder.split.1x2"
        case .parser: return "square.and.arrow.down"
        }
    }

    /// Корневой экран раздела. AnyView — чтобы 29 веток не перегружали проверку типов.
    /// Экран НЕ содержит NavigationStack: его даёт вкладка или меню «Ещё».
    /// `subtab` — rawValue вкладки внутри раздела (NotifyCategory.subtab); сейчас его
    /// понимают «Заявки магазинов» (registrations/publish/documents), «Сообщения
    /// продавцам» ("unread" — фильтр непрочитанных) и «Курьеры» (couriers/problems/
    /// complaints), остальные разделы
    /// открываются на своей вкладке по умолчанию.
    func makeRoot(openId: Int? = nil, subtab: String? = nil) -> AnyView {
        switch self {
        case .dashboard: return AnyView(DashboardRootView(openId: openId))
        case .registrations:
            let tab = RegistrationsTab(rawValue: subtab ?? "") ?? .registrations
            return AnyView(RegistrationsRootView(openId: openId, initialTab: tab))
        case .shops: return AnyView(ShopsRootView(openId: openId))
        case .users: return AnyView(UsersRootView(openId: openId))
        case .orders: return AnyView(OrdersRootView(openId: openId))
        case .returns: return AnyView(ReturnsRootView(openId: openId))
        case .wallets:
            let tab = WalletsTab(rawValue: subtab ?? "") ?? .sellers
            return AnyView(WalletsRootView(openId: openId, initialTab: tab))
        case .payouts: return AnyView(PayoutsRootView(openId: openId))
        case .referrals: return AnyView(ReferralsRootView(openId: openId))
        case .products: return AnyView(ProductsRootView(openId: openId))
        case .reviews: return AnyView(ReviewsRootView(openId: openId))
        case .complaints: return AnyView(ComplaintsRootView(openId: openId))
        case .ads:
            // "reports" — вкладка «Жалобы» (push ad_report).
            let tab: AdsTab? = subtab == "reports" ? .reports : nil
            return AnyView(AdsRootView(openId: openId, initialTab: tab))
        case .cities: return AnyView(CitiesRootView(openId: openId))
        case .plans: return AnyView(PlansRootView(openId: openId))
        case .banners: return AnyView(BannersRootView(openId: openId))
        case .pages: return AnyView(PagesRootView(openId: openId))
        case .templates: return AnyView(TemplatesRootView(openId: openId))
        case .campaigns: return AnyView(CampaignsRootView(openId: openId))
        // openId — id розыгрыша (его карточка открывается сразу); subtab "history" — вкладка «История».
        case .giveaways: return AnyView(GiveawaysRootView(openId: openId, subtab: subtab))
        case .support: return AnyView(SupportRootView(openId: openId))
        // openId — id организации (её чат открывается сразу), subtab "unread" — фильтр «Непрочитанные».
        case .shopSupport: return AnyView(ShopSupportRootView(openId: openId, subtab: subtab))
        // openId — user_id курьера (его карточка открывается сразу), subtab — вкладка раздела.
        case .couriers: return AnyView(CouriersRootView(openId: openId, subtab: subtab))
        case .reports: return AnyView(ReportsRootView(openId: openId))
        case .audit: return AnyView(AuditRootView(openId: openId))
        case .staff: return AnyView(StaffRootView(openId: openId))
        case .settings: return AnyView(SettingsRootView(openId: openId))
        case .database: return AnyView(DatabaseRootView(openId: openId))
        case .parser: return AnyView(ParserRootView(openId: openId))
        }
    }
}
