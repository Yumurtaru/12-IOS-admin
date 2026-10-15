import Foundation
import Security

/// Хранение секретов в Keychain (не в UserDefaults): токены админа — ключи от всей площадки.
enum Keychain {
    /// Ключи записей.
    enum Key: String {
        case accessToken = "ru.marketplace.admin.access_token"
        case refreshToken = "ru.marketplace.admin.refresh_token"
    }

    /// Записать строку (старое значение заменяется). true — успех.
    @discardableResult
    static func set(_ value: String, for key: Key) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        // «После первой разблокировки, только это устройство»: фоновая проверка
        // очередей (BGAppRefreshTask) читает токен при заблокированном экране,
        // а в резервную копию на другой телефон токен не попадает.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Прочитать строку или nil.
    static func get(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Удалить запись.
    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Стереть все токены.
    static func clearAll() {
        delete(.accessToken)
        delete(.refreshToken)
    }
}

/// Потокобезопасный доступ к токенам: API читает их с любого потока,
/// Session пишет с главного. Значения кэшируются в памяти, источник — Keychain.
final class TokenStore {
    /// Единственный экземпляр.
    static let shared = TokenStore()

    private let lock = NSLock()
    private var access: String?
    private var refresh: String?
    private var loaded = false

    private init() {}

    private func loadIfNeeded() {
        if loaded { return }
        access = Keychain.get(.accessToken)
        refresh = Keychain.get(.refreshToken)
        loaded = true
    }

    /// Текущий access-токен (JWT) или nil.
    var accessToken: String? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return access
    }

    /// Текущий refresh-токен или nil.
    var refreshToken: String? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return refresh
    }

    /// Сохранить пару токенов. refresh = nil — оставить прежний.
    func save(access newAccess: String, refresh newRefresh: String?) {
        lock.lock(); defer { lock.unlock() }
        loaded = true
        access = newAccess
        Keychain.set(newAccess, for: .accessToken)
        if let r = newRefresh, !r.isEmpty {
            refresh = r
            Keychain.set(r, for: .refreshToken)
        }
    }

    /// Стереть токены (выход).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        loaded = true
        access = nil
        refresh = nil
        Keychain.clearAll()
    }
}
