import SwiftUI

/// Раздел «Кошельки» — как страница /admin/wallets сайта, плюс «Финансы».
///
/// Вкладки:
///  * «Продавцы» — GET /api/admin/wallets: сверка, ручные заявки на пополнение
///    (подтвердить/отклонить), оборвавшиеся и зависшие онлайн-заявки (проверить
///    платёж в ЮKassa, зачислить фактически оплаченное, отклонить), низкий баланс;
///  * «Клиенты» — GET /api/admin/user-wallets (+ карточка кошелька, корректировка);
///  * «Пополнения» — GET /api/admin/user-topups (проверить в ЮKassa / закрыть);
///  * «Финансы» — GET /api/admin/finance за период (+ досписание сборов).
///
/// `openId` — номер заявки на пополнение МАГАЗИНА (wallet_topups.id): она
/// показывается первой на вкладке «Продавцы».
struct WalletsRootView: View {
    let openId: Int?

    @State private var tab: WalletsTab = .sellers
    // Модели живут здесь, чтобы при переключении вкладок данные не терялись.
    @StateObject private var sellers = ObjectLoader(path: "/api/admin/wallets")
    @StateObject private var clients = PagedListModel(path: "/api/admin/user-wallets", searchParam: "q")
    @StateObject private var topups = PagedListModel(path: "/api/admin/user-topups", searchParam: nil,
                                                     filters: ["status": "pending"])
    @StateObject private var finance = ObjectLoader(path: "/api/admin/finance",
                                                    query: WalletsRootView.defaultFinanceQuery())
    @State private var financeFrom: Date = WalletsRootView.monthStart()
    @State private var financeTo: Date = Date()

    init(openId: Int? = nil, initialTab: WalletsTab = .sellers) {
        self.openId = openId
        // Уведомление «пополнения клиентов висят» открывает сразу вкладку «Пополнения».
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Вкладка", selection: $tab) {
                ForEach(WalletsTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            content
        }
        .background(Brand.bg)
        .navigationTitle("Кошельки")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .sellers:
            WalletsSellersView(loader: sellers, focusId: openId)
        case .clients:
            WalletsClientsView(model: clients)
        case .topups:
            WalletsUserTopupsView(model: topups)
        case .finance:
            WalletsFinanceView(loader: finance, from: $financeFrom, to: $financeTo)
        }
    }

    /// Первое число текущего месяца по Москве (как date('Y-m-01') на сервере).
    nonisolated static func monthStart() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Fmt.moscow
        let comps = cal.dateComponents([.year, .month], from: Date())
        return cal.date(from: comps) ?? Date()
    }

    nonisolated static func defaultFinanceQuery() -> [String: String?] {
        ["from": Fmt.ymd(monthStart()), "to": Fmt.ymd(Date())]
    }
}

/// Вкладки раздела «Кошельки».
enum WalletsTab: String, CaseIterable, Identifiable {
    case sellers, clients, topups, finance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sellers: return "Продавцы"
        case .clients: return "Клиенты"
        case .topups: return "Пополнения"
        case .finance: return "Финансы"
        }
    }
}

/// Подписи и мелкие помощники раздела «Кошельки».
enum WalletsLabels {
    /// Способ пополнения (wallet_topups.method / user_wallet_topups.method).
    static func method(_ code: String?) -> String {
        switch code ?? "" {
        case "bank_transfer": return "Перевод по реквизитам"
        case "cash_manual": return "Наличные"
        case "card_online": return "Карта онлайн"
        case "sbp": return "СБП"
        case "card": return "Карта"
        case "": return "—"
        default: return code ?? "—"
        }
    }

    /// Статус пополнения клиента (как UW_TOPUP_ST на сайте).
    static func userTopupStatus(_ code: String?) -> String {
        switch code ?? "" {
        case "pending": return "Ожидает оплаты"
        case "confirmed": return "Зачислено"
        case "rejected": return "Не оплачено"
        default: return Fmt.statusLabel(code)
        }
    }

    /// Состояние платежа ЮKassa.
    static func yooStatus(_ code: String?) -> String {
        switch code ?? "" {
        case "succeeded": return "оплачен"
        case "pending": return "ожидает оплаты"
        case "waiting_for_capture": return "ждёт подтверждения"
        case "canceled": return "отменён"
        case "": return "—"
        default: return code ?? "—"
        }
    }

    /// Ошибка проверки на стороне приложения (показывается как ошибка сервера).
    static func invalid(_ text: String) -> APIError {
        APIError.validation(text, fields: [:])
    }

    /// Обновить счётчики «Заявок» после действия, которое что-то разобрало.
    static func refreshInbox() {
        Task { await Notifier.shared.refresh(force: true) }
    }
}

/// Строка-сводка «подпись — крупное значение — пояснение».
struct WalletsMetric: View {
    let title: String
    let value: String
    let note: String?

    init(_ title: String, value: String, note: String? = nil) {
        self.title = title
        self.value = value
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(Brand.muted)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            if let n = note {
                Text(n)
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
