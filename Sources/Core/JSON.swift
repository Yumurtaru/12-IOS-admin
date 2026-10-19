import Foundation

/// Динамическое JSON-значение — любой ответ сервера без отдельной модели.
///
/// Сервер (PHP/MySQL) отдаёт числа то числом, то строкой («12.50», «1»),
/// булевы — как true/1/"1"/"true". Поэтому все аксессоры снисходительные:
/// `j["price"].decimal` читает и 12.5, и "12.50"; `j["is_active"].bool` —
/// и true, и 1, и "1". Отсутствующий ключ или чужой тип дают `.null`/`nil`,
/// а не падение.
///
/// Примеры:
/// ```
/// let name = row["name"].stringValue           // "" если нет
/// let id = row["id"].int                       // Int? из 5 или "5"
/// let sum = row["total"].decimal               // Decimal? из 12.5 или "12.50"
/// for item in data["items"].array { ... }      // [] если не массив
/// ```
enum JSON: Decodable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: - Разбор

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSON].self) { self = .object(o); return }
        self = .null
    }

    /// Разобрать сырые байты ответа. nil — если это не JSON.
    static func parse(_ data: Data) -> JSON? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: data)
    }

    /// Из объекта JSONSerialization / словаря Swift (`[String: Any]`, `[Any]`, числа, строки).
    init(any value: Any?) {
        let v = JSONBody.unwrapOptional(value)
        switch v {
        case nil: self = .null
        case let j as JSON: self = j
        case is NSNull: self = .null
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .number(Double(i))
        case let d as Double: self = .number(d)
        case let dec as Decimal: self = .number(NSDecimalNumber(decimal: dec).doubleValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any?]: self = .array(a.map { JSON(any: $0) })
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any?]:
            var out: [String: JSON] = [:]
            for (k, x) in o { out[k] = JSON(any: x) }
            self = .object(out)
        case let o as [String: Any]:
            var out: [String: JSON] = [:]
            for (k, x) in o { out[k] = JSON(any: x) }
            self = .object(out)
        default: self = .string(String(describing: v as Any))
        }
    }

    // MARK: - Доступ

    /// Значение по ключу объекта; `.null`, если это не объект или ключа нет.
    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    /// Элемент массива; `.null`, если это не массив или индекс вне границ.
    subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    /// true для null и для отсутствующего ключа.
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Есть ли непустое значение (не null и не пустая строка).
    var exists: Bool {
        switch self {
        case .null: return false
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }

    /// Строка: строки как есть, числа без хвостового «.0», булевы — "1"/"0". Иначе nil.
    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return JSON.numberString(d)
        case .bool(let b): return b ? "1" : "0"
        default: return nil
        }
    }

    /// Строка или "" (удобно для Text).
    var stringValue: String { string ?? "" }

    /// Непустая строка или nil (пустая строка с сервера = «нет значения»).
    var nonEmptyString: String? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Double из числа, строки "12.50"/"12,50" или булева.
    var double: Double? {
        switch self {
        case .number(let d): return d.isFinite ? d : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            return Double(t)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Int из числа, строки "5"/"5.00" или булева. Дробная часть отбрасывается.
    var int: Int? {
        switch self {
        case .number(let d): return JSON.safeInt(d)
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            return double.flatMap { JSON.safeInt($0) }
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Int или 0.
    var intValue: Int { int ?? 0 }

    /// Decimal без потери копеек: строка "12.50" читается точно, число — через его запись.
    var decimal: Decimal? {
        switch self {
        case .number(let d):
            guard d.isFinite else { return nil }
            return Decimal(string: JSON.numberString(d), locale: Locale(identifier: "en_US_POSIX"))
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard !t.isEmpty, Double(t) != nil else { return nil }
            return Decimal(string: t, locale: Locale(identifier: "en_US_POSIX"))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// Bool из true/false, 1/0, "1"/"0", "true"/"false", "yes"/"on".
    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if ["1", "true", "yes", "on", "да"].contains(t) { return true }
            if ["0", "false", "no", "off", "нет", ""].contains(t) { return false }
            return nil
        default: return nil
        }
    }

    /// Bool или false.
    var boolValue: Bool { bool ?? false }

    /// Массив или [] (если это не массив).
    var array: [JSON] {
        if case .array(let a) = self { return a }
        return []
    }

    /// Словарь или [:] (если это не объект).
    var object: [String: JSON] {
        if case .object(let o) = self { return o }
        return [:]
    }

    /// true, если значение — объект.
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// true, если значение — массив.
    var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    /// `self["id"].int` — короткая запись.
    var id: Int? { self["id"].int }

    /// Ключ строки списка для ForEach: id, а если его нет — хэш содержимого.
    var stableID: String {
        if let s = self["id"].string { return s }
        return "h" + String(hashValue)
    }

    /// Человекочитаемое представление для показа «как есть» (инспектор, отладка):
    /// null → «—», булевы → «да»/«нет», массив/объект → компактный JSON.
    var raw: String {
        switch self {
        case .null: return "—"
        case .bool(let b): return b ? "да" : "нет"
        case .number(let d): return JSON.numberString(d)
        case .string(let s): return s
        case .array, .object: return compactText
        }
    }

    /// Компактная JSON-строка значения.
    var compactText: String {
        let any = toAny()
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return raw
    }

    /// Обратно в объект Foundation (для отправки на сервер).
    func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if let i = JSON.safeInt(d), Double(i) == d { return i }
            return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o):
            var out: [String: Any] = [:]
            for (k, v) in o { out[k] = v.toAny() }
            return out
        }
    }

    // MARK: - Внутреннее

    static func numberString(_ d: Double) -> String {
        if let i = safeInt(d), Double(i) == d { return String(i) }
        return String(d)
    }

    static func safeInt(_ d: Double) -> Int? {
        guard d.isFinite, abs(d) < 9e18 else { return nil }
        return Int(d)
    }
}

/// Сборка тела запроса из обычного словаря Swift.
///
/// `[String: Any?]` → Data. nil и NSNull уходят как `null`, Decimal — числом,
/// JSON — как есть, вложенные словари и массивы — рекурсивно.
/// ```
/// let data = try JSONBody.data(["reason": text, "plan_id": planId, "note": nil])
/// ```
enum JSONBody {
    /// Сериализовать словарь в JSON-байты. Бросает APIError.badResponse, если значение не сериализуется.
    static func data(_ dict: [String: Any?]) throws -> Data {
        let obj = normalize(dict)
        guard JSONSerialization.isValidJSONObject(obj) else {
            throw APIError.badResponse("Не удалось подготовить данные для отправки")
        }
        // Ключи по алфавиту: сервер узнаёт повтор с тем же Idempotency-Key по
        // отпечатку тела, а словарь Swift при каждой сборке даёт свой порядок —
        // повтор после обрыва получал «ключ уже использован» вместо прежнего ответа.
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// Привести любое значение к виду, который понимает JSONSerialization.
    static func normalize(_ value: Any?) -> Any {
        let v = unwrapOptional(value)
        switch v {
        case nil: return NSNull()
        case let j as JSON: return j.toAny()
        case is NSNull: return NSNull()
        case let b as Bool: return b
        case let i as Int: return i
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as Float: return Double(f)
        case let dec as Decimal: return NSDecimalNumber(decimal: dec)
        case let n as NSNumber: return n
        case let s as String: return s
        case let s as Substring: return String(s)
        case let a as [Any?]: return a.map { normalize($0) }
        case let a as [Any]: return a.map { normalize($0) }
        case let o as [String: Any?]:
            var out: [String: Any] = [:]
            for (k, x) in o { out[k] = normalize(x) }
            return out
        case let o as [String: Any]:
            var out: [String: Any] = [:]
            for (k, x) in o { out[k] = normalize(x) }
            return out
        default: return String(describing: v as Any)
        }
    }

    /// `Any` может прятать внутри Optional (`Optional<Optional<Int>>`) — разворачиваем.
    static func unwrapOptional(_ value: Any?) -> Any? {
        guard let value = value else { return nil }
        let m = Mirror(reflecting: value)
        guard m.displayStyle == .optional else { return value }
        guard let child = m.children.first else { return nil }
        return unwrapOptional(child.value)
    }
}
