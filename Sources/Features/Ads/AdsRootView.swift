import SwiftUI

/// Раздел «Объявления» — доска объявлений (routes/admin_ads.php):
/// сводка, объявления (заблокировать / разблокировать / удалить), жалобы на
/// объявления (закрыть), категории с ценами размещения.
///
/// Ручки: GET /api/admin/ads/stats; GET /api/admin/ads (status, q, category_id, user_id, page);
/// POST /api/admin/ads/{id}/block {reason}; POST /api/admin/ads/{id}/unblock;
/// DELETE /api/admin/ads/{id}; GET /api/admin/ads/reports (page);
/// POST /api/admin/ads/reports/{id}/close; GET/POST/PUT/DELETE /api/admin/ads/categories…
///
/// Если доска не установлена на сервере, ручки отвечают 503 с объяснением —
/// оно показывается вместо списка.
///
/// `openId` — id объявления: его карточка откроется, если оно есть на первой
/// странице списка (ручки «объявление по id» в админке нет).
struct AdsRootView: View {
    let openId: Int?

    @StateObject private var ads = PagedListModel(path: "/api/admin/ads")
    @StateObject private var reports = PagedListModel(path: "/api/admin/ads/reports", searchParam: nil)
    @StateObject private var categories = ObjectLoader(path: "/api/admin/ads/categories")
    @StateObject private var stats = ObjectLoader(path: "/api/admin/ads/stats")
    @State private var tab: AdsTab = .list
    @State private var didInit = false
    @State private var deepLinkPending: Bool
    @State private var deepLinkItem: JSON?
    @State private var deepLinkActive = false

    init(openId: Int? = nil) {
        self.openId = openId
        _deepLinkPending = State(initialValue: openId != nil)
    }

    var body: some View {
        Group {
            switch tab {
            case .list:
                AdsListScreen(model: ads, categories: categories, stats: stats)
            case .reports:
                AdsReportsScreen(model: reports, stats: stats, ads: ads)
            case .categories:
                AdsCategoriesScreen(loader: categories)
            }
        }
        .safeAreaInset(edge: .top) { tabPicker }
        .onAppear(perform: initialTab)
        .onReceive(ads.$items) { items in findDeepLink(items) }
        .navigationDestination(isPresented: $deepLinkActive) { deepLinkDestination }
    }

    @ViewBuilder
    private var deepLinkDestination: some View {
        if let item = deepLinkItem {
            AdsAdDetailView(ad: item, model: ads, stats: stats)
        } else {
            EmptyView()
        }
    }

    private var tabPicker: some View {
        Picker("Раздел", selection: $tab) {
            Text("Объявления").tag(AdsTab.list)
            Text(reportsTitle).tag(AdsTab.reports)
            Text("Категории").tag(AdsTab.categories)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Brand.bg)
    }

    private var reportsTitle: String {
        let n = stats.data["reports_new"].intValue
        return n > 0 ? "Жалобы (" + String(n) + ")" : "Жалобы"
    }

    /// Есть неразобранные жалобы (по счётчику «Заявок») — открываем их сразу.
    private func initialTab() {
        guard !didInit else { return }
        didInit = true
        if openId == nil && Notifier.shared.count(.adReports) > 0 {
            tab = .reports
        }
        Task { await stats.loadIfNeeded() }
    }

    private func findDeepLink(_ items: [JSON]) {
        guard deepLinkPending, let id = openId, !items.isEmpty else { return }
        deepLinkPending = false
        if let found = items.first(where: { $0.id == id }) {
            deepLinkItem = found
            deepLinkActive = true
        }
    }
}

/// Вкладки раздела «Объявления».
enum AdsTab: Hashable {
    case list, reports, categories
}

/// Подписи и общие действия раздела «Объявления».
enum AdsFormat {
    static func statusLabel(_ s: String?) -> String {
        switch s ?? "" {
        case "draft": return "Черновик"
        case "active": return "Активно"
        case "expired": return "Истекло"
        case "archived": return "Снято"
        case "blocked": return "Блокировка"
        default: return Fmt.statusLabel(s)
        }
    }

    static func statusColor(_ s: String?) -> Color {
        switch s ?? "" {
        case "active": return Brand.green
        case "expired": return Brand.amber
        case "blocked": return Brand.red
        default: return Brand.muted
        }
    }

    static let statusFilter = ListFilter(key: "status", title: "Статус", options: [
        PickerOption(value: "active", label: "Активно"),
        PickerOption(value: "expired", label: "Истекло"),
        PickerOption(value: "draft", label: "Черновик"),
        PickerOption(value: "archived", label: "Снято"),
        PickerOption(value: "blocked", label: "Блокировка"),
    ], allLabel: "Все статусы")

    /// Причина жалобы по-русски (AD_REASONS на сайте).
    static func reportReason(_ r: String?) -> String {
        switch r ?? "" {
        case "spam": return "Спам"
        case "fraud": return "Мошенничество"
        case "wrong_category": return "Не та категория"
        case "prohibited": return "Запрещённый товар"
        case "sold": return "Уже продано"
        case "other": return "Другое"
        default: return r ?? "—"
        }
    }

    /// Готовые причины блокировки.
    static let blockReasons = ["Запрещённый товар", "Мошенничество", "Спам", "Не та категория", "Нарушение правил площадки"]

    static let blockMessage = "Объявление пропадёт из выдачи, автор получит уведомление. Неиспользованные дни размещения вернутся автору на кошелёк автоматически. Пустая причина — «Нарушение правил площадки»."

    /// POST /api/admin/ads/{id}/block → текст итога (с суммой возврата).
    static func block(id: Int, reason: String) async throws -> String {
        let r = try await API.shared.post("/api/admin/ads/\(id)/block", body: ["reason": reason])
        let refund = r["refund"].decimal ?? 0
        if refund > 0 { return "Заблокировано, автору возвращено " + Fmt.money(refund) }
        return "Заблокировано"
    }

    /// Строка с изменёнными полями.
    static func patched(_ row: JSON, _ fields: [String: JSON]) -> JSON {
        var o = row.object
        for (k, v) in fields { o[k] = v }
        return .object(o)
    }

    /// Плоский список категорий (корень, затем его дети) для фильтра и выбора.
    static func flatCategories(_ data: JSON) -> [JSON] {
        var out: [JSON] = []
        for root in data["categories"].array {
            out.append(root)
            out.append(contentsOf: root["children"].array)
        }
        return out
    }
}

/// Сводка доски: плитки как на сайте.
struct AdsStatsHeader: View {
    @ObservedObject var stats: ObjectLoader

    var body: some View {
        Group {
            switch stats.state {
            case .failed(let msg):
                ErrorBanner(message: msg, retry: { Task { await stats.load() } })
            case .loaded:
                tiles
            default:
                EmptyView()
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
    }

    private var d: JSON { stats.data }

    private var tiles: some View {
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        let active: String = Fmt.number(d["active"])
        let total: String = "всего " + Fmt.number(d["total"])
        let expired: String = Fmt.number(d["expired"])
        let drafts: String = Fmt.number(d["drafts"])
        let blocked: String = Fmt.number(d["blocked"])
        let draftsLine: String = "черновиков " + drafts + " · блок " + blocked
        let earned30: String = Fmt.money(d["earned_30d"])
        let earnedAll: String = "всего " + Fmt.money(d["earned_all"])
        let reportsNew: String = Fmt.number(d["reports_new"])
        let photos: String = "фотографий " + Fmt.number(d["photos"])
        return LazyVGrid(columns: cols, spacing: 8) {
            AdsStatTile(label: "Активных", value: active, extra: total)
            AdsStatTile(label: "Истекло", value: expired, extra: draftsLine)
            AdsStatTile(label: "Заработано за 30 дней", value: earned30, extra: earnedAll)
            AdsStatTile(label: "Жалоб", value: reportsNew, extra: photos)
        }
    }
}

/// Одна плитка сводки.
struct AdsStatTile: View {
    let label: String
    let value: String
    let extra: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(extra)
                .font(.caption2)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
