import UIKit
import UserNotifications

/// Уведомления и фоновые задачи.
///
/// * Локальные уведомления Notifier (рост очередей) показываются и при открытом
///   приложении; тап открывает раздел (userInfo["section"]).
/// * Токен APNs запрашивается, если уведомления разрешены, и хранится локально.
///   На сервер он уходит ТОЛЬКО когда `AdminPush.serverSupportsAdminPlatform == true`
///   (сегодня сервер не знает платформу ios_admin — см. AdminPush.swift).
/// * Фоновая проверка очередей — BGAppRefreshTask (регистрируется здесь, до конца запуска).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerBackgroundTask()
        Task { @MainActor in
            await Notifier.shared.refreshAuthorization()
            await AdminPush.registerForRemoteIfAuthorized()
        }
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task { @MainActor in AppRouter.shared.handleNotification(userInfo: remote) }
        }
        return true
    }

    /// Токен APNs получен: сохраняем; на сервер — только если он знает ios_admin.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AdminPush.setDeviceToken(deviceToken)
        Task { @MainActor in await AdminPush.registerIfPossible() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Без токена работают локальные уведомления по опросу — ничего не делаем.
    }

    /// Уведомление при открытом приложении: показываем, если категория не выключена.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        let raw = info["category"] as? String
        let type = info["type"] as? String
        let shopRaw = info["shop_id"]
        let shopId: Int? = (shopRaw as? Int) ?? (shopRaw as? String).flatMap { Int($0) }
        // Категория: у локального — ключ category, у серверного push — по type.
        // Выключенная в настройках категория не показывает баннер при открытом приложении.
        let category = raw.flatMap { NotifyCategory(rawValue: $0) } ?? NotifyCategory.forPushType(type ?? "")
        Task { @MainActor in
            if let cat = category, !Notifier.shared.isEnabled(cat) {
                completionHandler([])
                return
            }
            // Сообщение организации, чей чат сейчас на экране: баннер не нужен —
            // просим чат подтянуть новое сразу, не дожидаясь опроса раз в 15 с.
            if type == "shop_support", let sid = shopId, sid == ShopSupportLive.visibleShopId {
                NotificationCenter.default.post(name: ShopSupportLive.poke, object: nil)
                completionHandler([])
                return
            }
            completionHandler([.banner, .list, .sound])
        }
    }

    /// Тап по уведомлению → раздел.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            AppRouter.shared.handleNotification(userInfo: info)
            completionHandler()
        }
    }

    /// Тихий push (когда сервер начнёт их слать): обновить счётчики.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await Notifier.shared.refresh(force: true)
            completionHandler(.newData)
        }
    }
}
