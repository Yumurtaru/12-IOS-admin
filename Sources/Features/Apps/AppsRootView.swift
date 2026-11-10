import SwiftUI

/// Вкладки раздела «Приложения».
enum AppsTab: String, CaseIterable, Identifiable {
    case overview, clients, notify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .clients: return "Клиенты"
        case .notify: return "Уведомить"
        }
    }
}

/// Раздел «Приложения»: у каких клиентов стоят приложения Yumurta, какие версии,
/// кто давно не заходил, и рассылка «обновите / установите приложение».
///
/// Ручки (только администратор площадки, конверт {ok,data}):
///   GET  /api/admin/app-clients/summary   — обзор;
///   GET  /api/admin/app-clients           — клиенты с приложениями (50 на страницу);
///   POST /api/admin/app-notify/preview    — предпросмотр рассылки;
///   POST /api/admin/app-notify/send       — отправка пачками по 100 (курсор `after`, `guard_key`).
/// Старый сервер без этих ручек (404) → «Обновите сайт», приложение не падает.
///
/// Модели лежат здесь, а не во вкладках: переключение сегмента не сбрасывает поиск, фильтры
/// и — главное — не прерывает идущую отправку. Экран НЕ содержит NavigationStack (его даёт «Ещё»).
/// `openId` не используется (у раздела нет объектов для ссылки).
struct AppsRootView: View {
    let openId: Int?

    @State private var tab: AppsTab = .overview
    @StateObject private var overview = AppsOverviewModel()
    @StateObject private var clients = AppClientsModel()
    @StateObject private var notify = AppsNotifyModel()

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Вкладка раздела", selection: $tab) {
                ForEach(AppsTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            tabContent
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Приложения")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview:
            AppsOverviewView(model: overview)
        case .clients:
            AppsClientsView(model: clients)
        case .notify:
            AppsNotifyView(model: notify)
        }
    }
}
