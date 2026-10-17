import SwiftUI

/// Нижние вкладки: Сводка · Заявки · Магазины · Заказы · Ещё.
///
/// «Сводка», «Магазины», «Заказы» — свой NavigationStack вокруг RootView
/// раздела; при переходе из уведомления стек пересоздаётся (`.id`), а RootView
/// получает `openId`. Экраны разделов сами NavigationStack не создают.
struct MainTabView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notifier: Notifier
    @State private var askPermission = false

    var body: some View {
        TabView(selection: $router.tab) {
            dashboardTab
            inboxTab
            shopsTab
            ordersTab
            MoreView()
                // Поколение меняет Router при повторном переходе в тот же раздел.
                .id(router.generationOf(.more))
                .tabItem { Label("Ещё", systemImage: "ellipsis.circle") }
                .tag(AppRouter.Tab.more)
        }
        .task {
            await notifier.refreshAuthorization()
            if !notifier.permissionAsked && notifier.authorization == .notDetermined {
                askPermission = true
            }
        }
        .alert("Уведомления о заявках", isPresented: $askPermission) {
            Button("Разрешить") { Task { await notifier.requestPermission() } }
            Button("Не сейчас", role: .cancel) {}
        } message: {
            Text("Приложение сообщит о новых заявках магазинов, возвратах, жалобах, обращениях в поддержку и пополнениях, которые ждут вас. Какие именно — можно выбрать в «Ещё → Настройки приложения».")
        }
    }

    private var dashboardTab: some View {
        NavigationStack {
            DashboardRootView(openId: router.openId(for: .dashboard))
        }
        .id(router.generationOf(.dashboard))
        .tabItem { Label("Сводка", systemImage: "square.grid.2x2") }
        .tag(AppRouter.Tab.dashboard)
    }

    private var inboxTab: some View {
        InboxView()
            .tabItem { Label("Заявки", systemImage: "tray.full") }
            .badge(notifier.total)
            .tag(AppRouter.Tab.inbox)
    }

    private var shopsTab: some View {
        NavigationStack {
            ShopsRootView(openId: router.openId(for: .shops))
        }
        .id(router.generationOf(.shops))
        .tabItem { Label("Магазины", systemImage: "building.2") }
        .tag(AppRouter.Tab.shops)
    }

    private var ordersTab: some View {
        NavigationStack {
            OrdersRootView(openId: router.openId(for: .orders))
        }
        .id(router.generationOf(.orders))
        .tabItem { Label("Заказы", systemImage: "list.bullet.rectangle") }
        .tag(AppRouter.Tab.orders)
    }
}
