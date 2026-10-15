import Foundation
import UIKit
import UserNotifications

/// Серверные push для приложения администратора.
///
/// СЕГОДНЯ ВЫКЛЮЧЕНО. /api/v1/push/register принимает платформы только
/// web / android / ios / ios_seller, а любое другое значение молча записывает
/// как 'android' (FCM) — токен APNs ушёл бы не туда, и push не дошёл бы.
/// Платформа 'ios' тоже не годится: у неё apns-topic клиентского приложения
/// (ru.marketplace.client.premium), а у админа свой — ru.marketplace.admin.
///
/// Что нужно на сервере (заявка владельцу), после чего здесь поменять флаг на true:
///   1. 'ios_admin' в списке $allowed в /api/v1/push/register (routes/api_v1.php);
///   2. в core/Push.php::toUser — ветка для 'ios_admin': APNs с
///      apns-topic = ru.marketplace.admin (как сделано для ios_seller через
///      topicSeller()); значение enum push_tokens.platform сервер расширит сам
///      (Push::ensurePlatform), миграция не обязательна;
///   3. (по желанию) больше событий для админов через notifyAdmins(): новая
///      заявка магазина, обращение в поддержку, жалоба, возврат и т.д. —
///      сегодня админу уходит только shop_publish_request.
/// До этого приложение уведомляет локально — по опросу очередей (Notifier).
enum AdminPush {
    /// Поддерживает ли сервер платформу ios_admin. Менять на true только после правки сервера.
    static let serverSupportsAdminPlatform = false

    /// Значение поля platform для /api/v1/push/register.
    static let platform = "ios_admin"

    private static let tokenKey = "admin.push.deviceToken"

    /// Последний device-токен APNs (hex) или nil.
    static var deviceToken: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    /// Сохранить токен из didRegisterForRemoteNotificationsWithDeviceToken.
    static func setDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: tokenKey)
    }

    /// Попросить у iOS токен APNs, если уведомления разрешены (токен нужен на будущее).
    @MainActor
    static func registerForRemoteIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if ok { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Отправить токен на сервер — ТОЛЬКО если сервер знает платформу ios_admin.
    /// POST /api/v1/push/register {token, platform: "ios_admin"}.
    @MainActor
    static func registerIfPossible() async {
        guard serverSupportsAdminPlatform else { return }
        guard Session.shared.isLoggedIn, let token = deviceToken else { return }
        let body: [String: Any?] = ["token": token, "platform": platform]
        _ = try? await API.shared.post("/api/v1/push/register", body: body)
    }
}
