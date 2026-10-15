import Foundation
import LocalAuthentication
import SwiftUI

/// Сессия администратора: вход (пароль → при необходимости код TOTP), токены, выход.
///
/// Вход — POST /api/admin/login {email, password} (routes/auth_seller.php):
///   * `{token, user, …}` — вход выполнен (2FA на сервере выключена);
///   * `{stage:"2fa"}` — нужен код из приложения-аутентификатора;
///   * `{stage:"setup", secret, uri}` — первая привязка аутентификатора.
/// Код — POST /api/admin/login/totp {code}. Сервер помнит прошедший пароль в
/// PHP-сессии (cookie PHPSESSID), поэтому оба вызова идут через одно
/// хранилище cookie (API.shared.session). refresh_token сервер ставит cookie —
/// забираем его после входа и храним в Keychain вместе с access-токеном.
@MainActor
final class Session: ObservableObject {
    /// Единственный экземпляр.
    static let shared = Session()

    /// Этап входа.
    enum Stage: Equatable {
        case loggedOut
        case needTOTP
        case setupTOTP(secret: String, uri: String)
        case loggedIn
    }

    /// Текущий этап.
    @Published private(set) var state: Stage
    /// Профиль администратора из ответа входа (id, name, email, phone …).
    @Published private(set) var user: JSON
    /// Сообщение для экрана входа («Сессия истекла…»), nil — нет.
    @Published var notice: String?

    private let userKey = "admin.session.user"
    private let emailKey = "admin.session.lastEmail"

    /// true — вошли, токен есть.
    var isLoggedIn: Bool { state == .loggedIn }

    /// Имя для показа.
    var userName: String {
        user["name"].nonEmptyString ?? user["email"].nonEmptyString ?? "Администратор"
    }

    /// E-mail последнего входа — подставляется в форму.
    var lastEmail: String { UserDefaults.standard.string(forKey: emailKey) ?? "" }

    private init() {
        let hasToken = TokenStore.shared.accessToken != nil
        state = hasToken ? .loggedIn : .loggedOut
        if hasToken, let data = UserDefaults.standard.data(forKey: userKey), let u = JSON.parse(data) {
            user = u
        } else {
            user = .null
        }
    }

    /// Шаг 1: e-mail и пароль. Бросает APIError с текстом сервера.
    func login(email: String, password: String) async throws {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // Свежая PHP-сессия: старая cookie могла остаться от прерванного входа.
        API.clearCookies()
        let res = try await API.shared.request("POST", "/api/admin/login",
                                               body: ["email": mail, "password": password], auth: false)
        UserDefaults.standard.set(mail, forKey: emailKey)
        try applyLogin(res.data)
    }

    /// Шаг 2: шестизначный код из приложения-аутентификатора.
    func submitTOTP(_ code: String) async throws {
        let digits = code.filter { $0.isNumber }
        let res = try await API.shared.request("POST", "/api/admin/login/totp",
                                               body: ["code": digits], auth: false)
        try applyLogin(res.data)
    }

    /// Вернуться с шага кода к вводу пароля.
    func cancelTOTP() {
        state = .loggedOut
    }

    /// Выйти: POST /api/v1/auth/logout (с push_token, если он есть), затем стереть всё локально.
    func signOut() async {
        var body: [String: Any?] = [:]
        if let token = AdminPush.deviceToken { body["push_token"] = token }
        _ = try? await API.shared.request("POST", "/api/v1/auth/logout", body: body)
        wipe(notice: nil)
    }

    /// Вызывает API, когда refresh-токен отклонён: выходим с пометкой.
    func handleExpired() {
        guard state == .loggedIn else { return }
        wipe(notice: "Сессия истекла. Войдите снова.")
    }

    // MARK: - Внутреннее

    private func applyLogin(_ d: JSON) throws {
        if let token = d["token"].nonEmptyString {
            completeLogin(token: token, user: d["user"])
            return
        }
        switch d["stage"].string {
        case "2fa":
            state = .needTOTP
        case "setup":
            state = .setupTOTP(secret: d["secret"].stringValue, uri: d["uri"].stringValue)
        default:
            throw APIError.badResponse("Сервер не выдал доступ. Повторите вход.")
        }
    }

    private func completeLogin(token: String, user u: JSON) {
        let refresh = API.cookieValue("refresh_token")
        TokenStore.shared.save(access: token, refresh: refresh)
        user = u
        persistUser(u)
        notice = nil
        AppLock.shared.didLogin()
        state = .loggedIn
    }

    private func persistUser(_ u: JSON) {
        let any = u.toAny()
        if JSONSerialization.isValidJSONObject(any), let data = try? JSONSerialization.data(withJSONObject: any) {
            UserDefaults.standard.set(data, forKey: userKey)
        }
    }

    private func wipe(notice text: String?) {
        TokenStore.shared.clear()
        API.clearCookies()
        UserDefaults.standard.removeObject(forKey: userKey)
        user = .null
        Notifier.shared.reset()
        notice = text
        state = .loggedOut
    }
}

/// Блокировка приложения Face ID / Touch ID / код-паролем телефона.
///
/// Включена по умолчанию. Запрашивается при запуске и после 5 минут в фоне.
/// Если на телефоне не задан код-пароль, блокировать нечем — экран не закрывается.
@MainActor
final class AppLock: ObservableObject {
    /// Единственный экземпляр.
    static let shared = AppLock()

    /// Сейчас закрыто экраном блокировки.
    @Published private(set) var isLocked: Bool
    /// Включена ли блокировка (настройка «Face ID»).
    @Published private(set) var isEnabled: Bool
    /// Последняя ошибка разблокировки (для экрана блокировки).
    @Published var lastError: String?

    /// Через сколько секунд в фоне снова спрашивать.
    static let relockAfter: TimeInterval = 300

    private let enabledKey = "admin.lock.enabled"
    private var backgroundedAt: Date?
    private var inProgress = false

    private init() {
        let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool
        let enabled = stored ?? true
        isEnabled = enabled
        isLocked = enabled && TokenStore.shared.accessToken != nil && AppLock.deviceCanAuthenticate()
    }

    /// Можно ли вообще проверить владельца (задан код-пароль).
    var isAvailable: Bool { AppLock.deviceCanAuthenticate() }

    /// Как называется способ: «Face ID», «Touch ID» или «код-пароль».
    var methodName: String {
        let ctx = LAContext()
        var err: NSError?
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "код-пароль"
        }
    }

    /// Включить/выключить. Выключение подтверждается владельцем телефона.
    func setEnabled(_ on: Bool) async {
        if !on {
            let ok = await authenticate(reason: "Подтвердите отключение блокировки")
            guard ok else { return }
        }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    /// Приложение ушло в фон.
    func appDidEnterBackground() {
        backgroundedAt = Date()
    }

    /// Приложение снова активно: закрыть, если пробыло в фоне дольше 5 минут.
    func appDidBecomeActive() {
        defer { backgroundedAt = nil }
        guard let since = backgroundedAt else { return }
        guard isEnabled, Session.shared.isLoggedIn, isAvailable else { return }
        if Date().timeIntervalSince(since) >= AppLock.relockAfter {
            isLocked = true
        }
    }

    /// Только что вошли паролем — блокировка не нужна.
    func didLogin() {
        isLocked = false
        lastError = nil
    }

    /// Попросить Face ID / код и снять блокировку.
    func unlock() async {
        guard isLocked, !inProgress else { return }
        guard isAvailable else { isLocked = false; return }
        inProgress = true
        defer { inProgress = false }
        let ok = await authenticate(reason: "Откройте админ-панель Yumurta")
        if ok {
            isLocked = false
            lastError = nil
        }
    }

    private func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Отмена"
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            lastError = (error as? LAError)?.code == .userCancel ? nil : "Не удалось подтвердить. Попробуйте ещё раз."
            return false
        }
    }

    private static func deviceCanAuthenticate() -> Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }
}
