import Foundation

/// Ответ сервера после снятия конверта.
///
/// Сервер отвечает двумя конвертами (core/Response.php и routes/api_v1.php):
///   `{"ok":true,"data":…,"error":null,"meta":{…}}` и
///   `{"success":true,"data":…,"meta":…,"error":null}`.
/// `data` — содержимое поля data, `meta` — поле meta (или .null),
/// `raw` — весь ответ целиком (если нужно что-то вне data).
struct APIResult {
    /// Поле `data` конверта (или весь ответ, если конверта нет).
    let data: JSON
    /// Поле `meta` конверта (или .null).
    let meta: JSON
    /// Весь разобранный ответ.
    let raw: JSON
    /// HTTP-код ответа.
    let status: Int
}

/// Ошибка запроса с русским текстом для показа человеку.
///
/// `error.message` — готовый текст: сообщение сервера (поле error / error.message /
/// message, плюс тексты полей errors при 422) либо понятная фраза про сеть.
/// `APIError.describe(anyError)` — то же для любой ошибки Swift.
enum APIError: Error, LocalizedError, Equatable {
    /// Нет связи с сервером (нет интернета, таймаут, DNS).
    case offline
    /// Запрос отменён (экран закрыли) — показывать не нужно.
    case cancelled
    /// 401: сессия истекла и обновить её не удалось (Session уже разлогинил).
    case unauthorized(String)
    /// 403: нет прав или нужен код 2FA/пароль — details содержит, например, `{"need":"2fa"}`.
    case forbidden(String, details: JSON)
    /// 404: объект не найден.
    case notFound(String)
    /// 422: ошибки полей формы (поле → текст).
    case validation(String, fields: [String: String])
    /// Любой другой отказ сервера (409, 429, 500 …) с текстом и деталями.
    case server(status: Int, message: String, details: JSON)
    /// Ответ не разобрался или данные не подготовились.
    case badResponse(String)

    /// Текст для человека.
    var message: String {
        switch self {
        case .offline: return "Нет связи с сервером. Проверьте интернет и повторите."
        case .cancelled: return "Запрос отменён"
        case .unauthorized(let m): return m
        case .forbidden(let m, _): return m
        case .notFound(let m): return m
        case .validation(let m, let fields):
            let parts = fields.keys.sorted().compactMap { fields[$0] }
            if parts.isEmpty { return m }
            let joined = parts.joined(separator: "\n")
            if m.isEmpty || m == "Проверьте правильность заполнения" { return joined }
            return m + "\n" + joined
        case .server(_, let m, _): return m
        case .badResponse(let m): return m
        }
    }

    /// HTTP-код (0 для сетевых ошибок).
    var status: Int {
        switch self {
        case .offline, .cancelled, .badResponse: return 0
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .validation: return 422
        case .server(let s, _, _): return s
        }
    }

    /// Дополнительные данные сервера (поле errors / error.details), иначе .null.
    var details: JSON {
        switch self {
        case .forbidden(_, let d): return d
        case .server(_, _, let d): return d
        default: return .null
        }
    }

    /// Ошибки полей (только для 422), иначе пусто.
    var fieldErrors: [String: String] {
        if case .validation(_, let f) = self { return f }
        return [:]
    }

    /// true, если сервер просит код двухфакторной аутентификации (`errors.need == "2fa"`).
    var needs2FA: Bool { details["need"].string == "2fa" }

    var errorDescription: String? { message }

    /// Русский текст для любой ошибки (APIError, URLError, прочее).
    static func describe(_ error: Error) -> String {
        if let e = error as? APIError { return e.message }
        if let u = error as? URLError { return API.map(u).message }
        if error is CancellationError { return APIError.cancelled.message }
        return error.localizedDescription
    }

    /// true для отмены (её не показывают пользователю).
    static func isCancellation(_ error: Error) -> Bool {
        if let e = error as? APIError, e == .cancelled { return true }
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        return false
    }
}

/// HTTP-клиент админки. Все пути — от корня сайта: `"/api/admin/shops"`.
///
/// ```
/// let data = try await API.shared.get("/api/admin/shops", query: ["q": text, "page": "1"])
/// let res  = try await API.shared.post("/api/admin/shops/5/publish")
/// try await API.shared.put("/api/admin/cities/3", body: ["name": name, "is_active": 1])
/// ```
/// Возвращает уже распакованное поле `data`. Нужен `meta` или весь ответ —
/// `request(...)` / `getResult(...)` дают `APIResult`.
/// 401 → одна попытка обновить токен (POST /api/v1/auth/refresh) и повтор;
/// не вышло → Session разлогинивает с пометкой «сессия истекла».
final class API {
    /// Единственный экземпляр.
    static let shared = API()

    /// Адрес сайта.
    static let baseURL: URL = URL(string: "https://yumurta.ru") ?? URL(fileURLWithPath: "/")

    /// Сессия с общим хранилищем cookie: PHP-сессия входа (шаг TOTP) и
    /// refresh_token приходят cookie и должны переживать запросы.
    let session: URLSession

    private let refresher = TokenRefresher()

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    // MARK: - Короткие методы (возвращают data)

    /// GET → поле data.
    func get(_ path: String, query: [String: String?] = [:]) async throws -> JSON {
        try await request("GET", path, query: query).data
    }

    /// GET → весь APIResult (data + meta + raw).
    func getResult(_ path: String, query: [String: String?] = [:]) async throws -> APIResult {
        try await request("GET", path, query: query)
    }

    /// POST с JSON-телом → поле data.
    @discardableResult
    func post(_ path: String, body: [String: Any?] = [:], query: [String: String?] = [:]) async throws -> JSON {
        try await request("POST", path, query: query, body: body).data
    }

    /// PUT с JSON-телом → поле data.
    @discardableResult
    func put(_ path: String, body: [String: Any?] = [:], query: [String: String?] = [:]) async throws -> JSON {
        try await request("PUT", path, query: query, body: body).data
    }

    /// DELETE (тело необязательно — часть ручек его читает) → поле data.
    @discardableResult
    func delete(_ path: String, body: [String: Any?]? = nil, query: [String: String?] = [:]) async throws -> JSON {
        try await request("DELETE", path, query: query, body: body).data
    }

    // MARK: - Общий запрос

    /// Любой запрос. `auth: false` — без токена и без попытки обновить его (вход).
    func request(_ method: String, _ path: String, query: [String: String?] = [:],
                 body: [String: Any?]? = nil, auth: Bool = true) async throws -> APIResult {
        let bodyData: Data? = try body.map { try JSONBody.data($0) }
        let build: () throws -> URLRequest = {
            try self.makeRequest(method, path, query: query, auth: auth, contentType: bodyData == nil ? nil : "application/json")
        }
        return try await perform(auth: auth) {
            var req = try build()
            req.httpBody = bodyData
            return try await self.session.data(for: req)
        }
    }

    /// Загрузка файла multipart/form-data (поле файла по умолчанию `file`).
    /// ```
    /// let jpeg = ImageDownscaler.jpeg(image) ?? Data()
    /// let r = try await API.shared.upload("/api/admin/upload", fileData: jpeg, fileName: "banner.jpg",
    ///                                     mime: "image/jpeg", query: ["dir": "banners"])
    /// let path = r["path"].stringValue
    /// ```
    func upload(_ path: String, fileData: Data, fileName: String, mime: String,
                fileField: String = "file", fields: [String: String] = [:],
                query: [String: String?] = [:]) async throws -> JSON {
        let boundary = "Boundary-" + UUID().uuidString
        let body = API.multipartBody(boundary: boundary, fileData: fileData, fileName: fileName,
                                     mime: mime, fileField: fileField, fields: fields)
        let res = try await perform(auth: true) {
            var req = try self.makeRequest("POST", path, query: query, auth: true,
                                           contentType: "multipart/form-data; boundary=" + boundary)
            req.timeoutInterval = 120
            return try await self.session.upload(for: req, from: body)
        }
        return res.data
    }

    /// Скачать файл (CSV, резервная копия) во временную папку. Возвращает URL файла
    /// с именем из Content-Disposition (или `suggestedName`) — его можно отдать в ShareSheet.
    func download(_ path: String, query: [String: String?] = [:], suggestedName: String? = nil) async throws -> URL {
        var attempt = 0
        while true {
            attempt += 1
            let req = try makeRequest("GET", path, query: query, auth: true, contentType: nil)
            let pair: (URL, URLResponse)
            do {
                pair = try await session.download(for: req)
            } catch {
                throw API.mapTransport(error)
            }
            let tmp = pair.0
            let response = pair.1
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                let name = suggestedName ?? response.suggestedFilename ?? "file"
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(name)
                try FileManager.default.moveItem(at: tmp, to: dest)
                return dest
            }
            let data = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            if status == 401 && attempt == 1 {
                if try await refreshAfter401() { continue }
            }
            let parsed = API.unwrap(JSON.parse(data), status: status)
            throw API.error(status: status, message: parsed.message, details: parsed.details)
        }
    }

    // MARK: - Адреса

    /// Полный URL для пути сайта и параметров (nil-значения пропускаются).
    static func url(_ path: String, query: [String: String?] = [:]) -> URL? {
        let full = path.hasPrefix("http") ? path : baseURL.absoluteString + (path.hasPrefix("/") ? path : "/" + path)
        guard var comps = URLComponents(string: full) else { return nil }
        var items = comps.queryItems ?? []
        for key in query.keys.sorted() {
            if let value = query[key] ?? nil {
                items.append(URLQueryItem(name: key, value: value))
            }
        }
        comps.queryItems = items.isEmpty ? nil : items
        // «+» в значении URLComponents не кодирует, а PHP читает его как пробел.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    /// Абсолютный URL картинки/файла: "/uploads/x.webp" → https://yumurta.ru/uploads/x.webp.
    static func absoluteURL(_ pathOrURL: String?) -> URL? {
        guard let s = pathOrURL?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        let p = s.hasPrefix("/") ? s : "/" + s
        let encoded = p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
        return URL(string: baseURL.absoluteString + encoded)
    }

    // MARK: - Внутреннее

    private func makeRequest(_ method: String, _ path: String, query: [String: String?], auth: Bool,
                             contentType: String?) throws -> URLRequest {
        guard let url = API.url(path, query: query) else { throw APIError.badResponse("Неверный адрес запроса") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(API.userAgent, forHTTPHeaderField: "User-Agent")
        if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        if auth, let token = TokenStore.shared.accessToken {
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Выполнить запрос, разобрать конверт, при 401 — обновить токен и повторить один раз.
    private func perform(auth: Bool, _ send: () async throws -> (Data, URLResponse)) async throws -> APIResult {
        var attempt = 0
        while true {
            attempt += 1
            let pair: (Data, URLResponse)
            do {
                pair = try await send()
            } catch {
                throw API.mapTransport(error)
            }
            let data = pair.0
            let response = pair.1
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = JSON.parse(data)
            let env = API.unwrap(json, status: status)
            if env.ok && (200..<300).contains(status) {
                return APIResult(data: env.data, meta: env.meta, raw: json ?? .null, status: status)
            }
            if status == 401 && auth && attempt == 1 {
                if try await refreshAfter401() { continue }
                throw APIError.unauthorized("Сессия истекла. Войдите снова.")
            }
            if json == nil && (200..<300).contains(status) {
                throw APIError.badResponse("Сервер вернул непонятный ответ. Повторите позже.")
            }
            throw API.error(status: status, message: env.message, details: env.details)
        }
    }

    /// 401 при авторизованном запросе: true — токен обновлён, можно повторить;
    /// false — refresh отклонён (Session уже разлогинен). Сетевая ошибка — бросается.
    private func refreshAfter401() async throws -> Bool {
        let outcome = await refresher.refresh { await self.performRefresh() }
        switch outcome {
        case .refreshed:
            return true
        case .rejected:
            await MainActor.run { Session.shared.handleExpired() }
            return false
        case .failed(let err):
            throw err
        }
    }

    /// Сам вызов POST /api/v1/auth/refresh {refresh_token} → data.token.
    fileprivate func performRefresh() async -> RefreshOutcome {
        guard let rt = TokenStore.shared.refreshToken, !rt.isEmpty else { return .rejected }
        do {
            let res = try await request("POST", "/api/v1/auth/refresh", body: ["refresh_token": rt], auth: false)
            guard let token = res.data["token"].nonEmptyString else { return .rejected }
            TokenStore.shared.save(access: token, refresh: nil)
            API.syncAccessCookie(token)
            return .refreshed
        } catch let e as APIError {
            switch e {
            case .offline, .cancelled: return .failed(e)
            case .server(let s, _, _) where s >= 500 || s == 429: return .failed(e)
            default: return .rejected
            }
        } catch {
            return .failed(API.mapTransport(error))
        }
    }

    /// Обновить cookie access_token свежим токеном. Сервер читает токен из
    /// заголовка Authorization, а если хостинг его срезал — из этой cookie;
    /// без синхронизации там остался бы старый, уже просроченный токен.
    static func syncAccessCookie(_ token: String) {
        let storage = HTTPCookieStorage.shared
        for c in storage.cookies(for: baseURL) ?? [] where c.name == "access_token" {
            storage.deleteCookie(c)
        }
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: baseURL.host ?? "yumurta.ru",
            .path: "/",
            .name: "access_token",
            .value: token,
            .secure: "TRUE",
        ]
        if let cookie = HTTPCookie(properties: props) { storage.setCookie(cookie) }
    }

    /// Значение cookie сайта по имени (refresh_token после входа).
    static func cookieValue(_ name: String) -> String? {
        let all = HTTPCookieStorage.shared.cookies(for: baseURL) ?? []
        return all.first(where: { $0.name == name && !$0.value.isEmpty })?.value
    }

    /// Стереть все cookie сайта (выход).
    static func clearCookies() {
        let storage = HTTPCookieStorage.shared
        for c in storage.cookies(for: baseURL) ?? [] { storage.deleteCookie(c) }
    }

    private static let userAgent: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "YumurtaAdmin/" + v + " (iOS)"
    }()

    /// Снять конверт ответа.
    static func unwrap(_ json: JSON?, status: Int) -> (ok: Bool, data: JSON, meta: JSON, message: String?, details: JSON) {
        guard let j = json else { return ((200..<300).contains(status), .null, .null, nil, .null) }
        let hasEnvelope = j.isObject && (j.object["ok"] != nil || j.object["success"] != nil)
        if !hasEnvelope {
            let msg = j["error"].nonEmptyString ?? j["message"].nonEmptyString
            return ((200..<300).contains(status), j, .null, msg, j["errors"])
        }
        let okFlag = j.object["ok"] != nil ? j["ok"].boolValue : j["success"].boolValue
        var message = j["error"].nonEmptyString
        var details = j["errors"]
        if j["error"].isObject {
            message = j["error"]["message"].nonEmptyString
            if details.isNull { details = j["error"]["details"] }
        }
        if message == nil { message = j["message"].nonEmptyString }
        return (okFlag, j["data"], j["meta"], message, details)
    }

    /// Ошибка по HTTP-коду и тексту сервера.
    static func error(status: Int, message: String?, details: JSON) -> APIError {
        switch status {
        case 401: return .unauthorized(message ?? "Требуется вход")
        case 403: return .forbidden(message ?? "Доступ запрещён", details: details)
        case 404: return .notFound(message ?? "Не найдено")
        case 422: return .validation(message ?? "Проверьте правильность заполнения", fields: fieldErrors(details))
        case 429: return .server(status: 429, message: message ?? "Слишком много запросов. Подождите минуту.", details: details)
        default:
            let fallback = status >= 500 ? "Ошибка сервера (код \(status)). Повторите позже." : "Запрос не выполнен (код \(status))"
            return .server(status: status, message: message ?? fallback, details: details)
        }
    }

    /// errors {поле: "текст"} или {поле: ["текст", …]} → поле: текст.
    static func fieldErrors(_ details: JSON) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in details.object {
            if let s = value.nonEmptyString {
                out[key] = s
            } else {
                let texts = value.array.compactMap { $0.nonEmptyString }
                if !texts.isEmpty { out[key] = texts.joined(separator: " ") }
            }
        }
        return out
    }

    /// Ошибка транспорта → APIError.
    static func mapTransport(_ error: Error) -> APIError {
        if let e = error as? APIError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError { return map(u) }
        return .badResponse(error.localizedDescription)
    }

    /// URLError → APIError.
    static func map(_ u: URLError) -> APIError {
        switch u.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
             .secureConnectionFailed:
            return .offline
        default:
            return .badResponse("Ошибка сети: " + u.localizedDescription)
        }
    }

    private static func multipartBody(boundary: String, fileData: Data, fileName: String, mime: String,
                                      fileField: String, fields: [String: String]) -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        for key in fields.keys.sorted() {
            append("--" + boundary + crlf)
            append("Content-Disposition: form-data; name=\"" + key + "\"" + crlf + crlf)
            append((fields[key] ?? "") + crlf)
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "")
        append("--" + boundary + crlf)
        append("Content-Disposition: form-data; name=\"" + fileField + "\"; filename=\"" + safeName + "\"" + crlf)
        append("Content-Type: " + mime + crlf + crlf)
        body.append(fileData)
        append(crlf + "--" + boundary + "--" + crlf)
        return body
    }
}

/// Итог попытки обновить токен.
enum RefreshOutcome {
    case refreshed
    case rejected
    case failed(APIError)
}

/// Одно обновление токена на всех: десять запросов, получивших 401 разом,
/// ждут один и тот же вызов /api/v1/auth/refresh.
actor TokenRefresher {
    private var inFlight: Task<RefreshOutcome, Never>?

    /// Выполнить `work` или дождаться уже идущего обновления.
    func refresh(_ work: @escaping @Sendable () async -> RefreshOutcome) async -> RefreshOutcome {
        if let t = inFlight { return await t.value }
        let t = Task { await work() }
        inFlight = t
        let result = await t.value
        inFlight = nil
        return result
    }
}
