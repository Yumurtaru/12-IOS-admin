import SwiftUI

/// «Yumurta Admin» — админ-панель площадки yumurta.ru на телефоне.
@main
struct YumurtaAdminApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = Session.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var notifier = Notifier.shared
    @StateObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(router)
                .environmentObject(notifier)
                .environmentObject(lock)
                .tint(Brand.accent)
                .onOpenURL { url in router.handle(url: url) }
        }
        .onChange(of: scenePhase) { phase in
            handle(phase)
        }
    }

    @MainActor
    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            lock.appDidBecomeActive()
            Task { await notifier.refreshAuthorization() }
            if session.isLoggedIn { notifier.start() }
        case .background:
            lock.appDidEnterBackground()
            notifier.stop()
            if session.isLoggedIn { Notifier.scheduleBackgroundRefresh() }
        default:
            break
        }
    }
}
