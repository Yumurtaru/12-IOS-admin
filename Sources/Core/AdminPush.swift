import Foundation
import UIKit
import UserNotifications

/// Серверные push для приложения администратора.
///
/// ВКЛЮЧЕНО (волна А72, ответ сервера на П-29.1): /api/v1/push/register принимает
/// платформу 'ios_admin', push администратору уходят в APNs с топиком
/// ru.marketplace.admin. Типы и данные push — AppRouter.sectionForPushType.
///
/// История (как было до А72): /api/v1/push/register принимает платформы только
/// web / android / ios / ios_seller, а любое другое значение молча записывает
/// как 'android' (FCM) — токен APNs ушёл бы не туда, и push не дошёл бы.
/// Платформа 'ios' тоже не годится: у неё apns-topic клиентского приложения
/// (ru.marketplace.client.premium), а у админа свой — ru.marketplace.admin.
///
/// Что было нужно на сервере (заявка П-29, сделано в А72):
///   1. 'ios_admin' в списке $allowed в /api/v1/push/register (routes/api_v1.php);
///   2. в core/Push.php::toUser — ветка для 'ios_admin': APNs с
///      apns-topic = ru.marketplace.admin (как сделано для ios_seller через
///      topicSeller()); значение enum push_tokens.platform сервер расширит сам
///      (Push::ensurePlatform), миграция не обязательна;
///   3. (по желанию) больше событий для админов через notifyAdmins(): новая
///      заявка магазина, обращение в поддержку, жалоба, возврат и т.д.
/// Локальные уведомления по опросу очередей (Notifier) работают и дальше —
/// они же подстраховывают, если push не дошёл.
enum AdminPush {
    /// Поддерживает ли сервер платформу ios_admin. Сервер её принимает с волны А72 (П-29.1),
    /// поэтому токен регистрируется — строго с platform = "ios_admin" (см. registerIfPossible).
    static let serverSupportsAdminPlatform = true

    /// Значение поля platform для /api/v1/push/register.
    static let platform = "ios_admin"

    private static let tokenKey = "admin.push.deviceToken"
    private static let registeredKey = "admin.push.registered"

    /// Сервер подтвердил токен ЭТОГО телефона (ответ /push/register: registered = true).
    /// Тогда о категориях, которые сервер присылает push'ем (NotifyCategory.serverPushed),
    /// Notifier не показывает свои локальные баннеры — иначе одно событие пришло бы дважды.
    static var serverPushRegistered: Bool {
        UserDefaults.standard.bool(forKey: registeredKey)
    }

    /// Забыть подтверждение (выход, истёкшая сессия, новый токен).
    static func forgetRegistration() {
        UserDefaults.standard.removeObject(forKey: registeredKey)
    }

    /// Последний device-токен APNs (hex) или nil.
    static var deviceToken: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    /// Сохранить токен из didRegisterForRemoteNotificationsWithDeviceToken.
    static func setDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // Новый токен сервер ещё не подтвердил — до ответа /push/register локальные баннеры нужны.
        if hex != deviceToken { forgetRegistration() }
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
    /// POST /api/v1/push/register {token, platform: "ios_admin", app_version?, app_build?,
    /// device_id?, device_model?, os_version?} — поля установки (волна А105,
    /// AppInstalls::fromPush) как у других приложений: без них приложение администратора
    /// в «Приложениях» сайта видно без версии и модели. Старый сервер их игнорирует.
    @MainActor
    static func registerIfPossible() async {
        guard serverSupportsAdminPlatform else { return }
        guard Session.shared.isLoggedIn, let token = deviceToken else { return }
        var body: [String: Any?] = ["token": token, "platform": platform]
        // Новый id установки — только когда файлы телефона открыты (после первой разблокировки).
        let extra = InstallInfo.pushFields(canCreate: UIApplication.shared.isProtectedDataAvailable)
        for (k, v) in extra { body[k] = v }
        // Ответ: {registered: bool, reassigned: bool} (routes/api_v1.php). Ошибка сети —
        // прежнее значение не трогаем: при следующем запуске регистрация повторится.
        guard let d = try? await API.shared.post("/api/v1/push/register", body: body) else { return }
        let ok = d["registered"].bool ?? true
        UserDefaults.standard.set(ok, forKey: registeredKey)
    }
}
