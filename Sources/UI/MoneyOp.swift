import SwiftUI

/// Денежная операция с ключом повтора: ручное зачисление/списание кошелька магазина
/// (shops/{id}/topup), корректировка кошелька клиента (user-wallets/{id}/correct),
/// запись выплаты (payouts), поправка расчёта курьера (pool/couriers/{id}/adjust).
///
/// Сервер с П-62 (А316; core/helpers.php apiIdemReplay/apiIdemClaim) принимает ключ —
/// заголовок `Idempotency-Key` или поле тела `idempotency_key` (перед отпечатком тела
/// вырезается): повтор с тем же ключом и тем же телом отдаёт сохранённый ответ (24 ч).
/// Пока первая копия идёт — ждёт до 3 с, затем 409 `idempotency_in_progress`; отметка без
/// ответа старше 120 с — 409 `idempotency_unknown_outcome`; тот же ключ с другим телом —
/// 422 `idempotency_key_reused`. НО приложение не знает, залит ли у сайта этот код, и
/// сервер молча игнорирует ключ, если не готовы его таблицы; до А316 у adjust защиты нет
/// вовсе, у остальных — окно 20–30 с. Поэтому повтор «сразу» не предлагаем.
///
/// С А618 (П-64 №1) сервер сам говорит, учтёт ли он ключ: поле `idem` (1/0) в data историй
/// (wallet / payouts / audit / user-wallets). Форма запоминает его из ПОСЛЕДНЕГО чтения
/// истории (ошибка чтения, нет поля, 0 — false). Только при `idem == true` и неизвестном
/// исходе она сама повторяет запрос тем же ключом и тем же телом: до 2 повторов с паузами
/// 2 с и 5 с (5xx, обрыв, таймаут, 409 `idempotency_in_progress`); повторный запрос ждёт
/// ответа 60 с, а не 200 с, под формой видно «Повторяем (1/2)…». `idempotency_unknown_outcome`,
/// 422 `idempotency_key_reused` и исчерпанные попытки — прежний путь «Проверить» по истории.
/// Ответ с `Idempotency-Replayed: true` — успех.
/// 503 `idempotency_unavailable` (строгий режим) на ПЕРВОЙ отправке = операция НЕ проведена:
/// форма свободна, ключ остаётся, автоповтора нет. Если 503 пришёл уже после неизвестного
/// исхода (в том числе после автоповторов), прошлая попытка могла пройти — «Проверить».
///
/// Форма:
///  * перед отправкой запоминает наибольший id истории, ждёт ответа долго (200 с,
///    `slowSession`) и шлёт ключ (один на окно) в заголовке и в теле;
///  * при неизвестном исходе (нет связи, обрыв, непонятный ответ, 5xx, 409 «уже
///    выполняется» / «не удалось узнать результат» / «только что прошло», 422 «ключ уже
///    использован») замирает: правка формы заблокирована, «Проверить» — по истории;
///    «Провести ещё раз» — только если операции в истории нет, не раньше 30 с после
///    отправки (2 мин при «не удалось узнать результат») и с подтверждением, тем же телом
///    и ТЕМ ЖЕ ключом (на новом сервере дубля не будет, на старом — не хуже прежнего);
///  * после неизвестного исхода любой отказ, кроме явного по существу (недостаточно
///    средств / в минус / 422 проверки данных), оставляет форму замороженной с тем же ключом;
///  * окончательный ответ первой отправки (успех или 4xx) или успех повтора — блокировка
///    снята, ключ забыт;
///  * «Закрыть» доступна всегда, кроме времени, пока идёт запрос.
enum MoneyOp {
    /// Ожидание ответа денежной ручки, с.
    static let timeout: TimeInterval = 200

    /// Паузы перед автоповторами (только при `idem == true`): 1-й повтор через 2 с, 2-й через 5 с.
    static let autoRetryPauses: [TimeInterval] = [2, 5]

    /// Ожидание ответа повторного запроса, с: короче первого (200 с), чтобы цепочка из трёх
    /// отправок не висела минутами.
    static let retryTimeout: TimeInterval = 60

    /// Текст при 503 `idempotency_unavailable`: операция не проведена.
    static let unavailableText = "Защита от повтора сейчас недоступна — операция не проведена. Повторите через минуту."

    /// Новый ключ повтора (на окно / действие): латиница, цифры и «-» — сервер их сохраняет как есть.
    static func newKey() -> String { "adm-" + UUID().uuidString.lowercased() }

    /// 503 `code: "idempotency_unavailable"` (строгий режим А618, а также «не удалось принять запрос»
    /// после трёх попыток захвата ключа): сервер не смог учесть ключ и операцию НЕ проводил.
    /// Другие 503 (страница хостинга) сюда не относятся — это обычный неизвестный исход.
    static func isIdemUnavailable(_ e: APIError) -> Bool {
        guard e.status == 503 else { return false }
        return e.details["code"].string == "idempotency_unavailable" || e.message.contains("Не удалось принять запрос")
    }

    /// Ошибка с понятным текстом для 503 `idempotency_unavailable` (статус и детали прежние).
    static func unavailableError(_ e: APIError) -> APIError {
        APIError.server(status: 503, message: unavailableText, details: e.details)
    }

    /// Можно ли при `idem == true` молча повторить запрос тем же ключом и телом:
    /// обрыв, таймаут, непонятный ответ, 5xx (кроме 503 `idempotency_unavailable`) и 409
    /// `idempotency_in_progress`. Отмена, `idempotency_unknown_outcome`, 422 `idempotency_key_reused`
    /// и любой 4xx — нет.
    static func isAutoRetryable(_ e: APIError) -> Bool {
        if isIdemUnavailable(e) { return false }
        if let reply = idemReply(e) { return reply == .inProgress }
        switch e {
        case .cancelled: return false
        case .offline, .badResponse: return true
        default: return e.status >= 500
        }
    }

    /// Приписка к итогу: ответ пришёл с `Idempotency-Replayed: true` — операция уже была проведена
    /// первой попыткой, второй раз сервер её не выполнял.
    static func replayPrefix(_ r: APIResult) -> String {
        r.replayed ? "Операция уже была проведена. " : ""
    }

    /// Исход неизвестен: запрос мог дойти и выполниться. 4xx — окончательный отказ
    /// (сервер отвечает им до записи), 5xx и всё сетевое — неизвестно.
    static func isUnknown(_ e: APIError) -> Bool {
        switch e {
        case .offline, .cancelled, .badResponse: return true
        default: return e.status == 0 || e.status >= 500
        }
    }

    /// Ответ сервера о ключе повтора (core/helpers.php): код из `code`, если он дошёл в
    /// деталях, иначе — по тексту (клиент хранит только текст и `errors`).
    enum IdemReply {
        /// 409: первая копия ещё выполняется.
        case inProgress
        /// 409: отметка без ответа — исход знает только история.
        case unknownOutcome
        /// 422: ключ уже использован для другого запроса.
        case keyReused
    }

    static func idemReply(_ e: APIError) -> IdemReply? {
        let code = e.details["code"].string ?? ""
        let m = e.message
        if e.status == 409 {
            if code == "idempotency_in_progress" || m.contains("Запрос уже выполняется") { return .inProgress }
            if code == "idempotency_unknown_outcome" || m.contains("Не удалось узнать результат прошлого запроса") {
                return .unknownOutcome
            }
        }
        if e.status == 422, e.fieldErrors.isEmpty,
           code == "idempotency_key_reused" || m.contains("Ключ повтора уже использован") {
            return .keyReused
        }
        return nil
    }

    /// Текст под формой при неизвестном исходе.
    static func unknownText(_ e: APIError) -> String {
        let head: String
        switch e {
        case .offline: head = "Ответ сервера не пришёл (нет связи или долгое ожидание)."
        case .cancelled: head = "Запрос прервался."
        default: head = e.message
        }
        return head + "\nОперация могла пройти — проверьте баланс и историю. Нажмите «Проверить»: повторно отправить можно только после проверки."
    }

    /// Наибольший id в строках истории (nil — строк нет или id не числа).
    static func maxId(_ rows: [JSON]) -> Int? {
        rows.compactMap { $0.id }.max()
    }

    /// Строка новой операции: подходит по `match` и появилась после отправки —
    /// id больше запомненного до отправки, а если его нет — не раньше чем за
    /// 10 мин до отправки (часы телефона и сервера могут расходиться).
    static func findNew(_ rows: [JSON], baseline: Int?, sentAt: Date?, match: (JSON) -> Bool) -> JSON? {
        for r in rows where match(r) {
            if let b = baseline {
                if let id = r.id, id > b { return r }
                continue
            }
            guard let sent = sentAt else { continue }
            if let d = Fmt.parseDate(r["created_at"].string), d >= sent.addingTimeInterval(-600) { return r }
        }
        return nil
    }

    /// Совпадает ли сумма строки с суммой операции (до копейки).
    static func sameAmount(_ j: JSON, _ value: Decimal) -> Bool {
        guard let d = j.decimal else { return false }
        return rounded(d) == rounded(value)
    }

    private static func rounded(_ v: Decimal) -> Decimal {
        var src = v
        var out = Decimal()
        NSDecimalRound(&out, &src, 2, .plain)
        return out
    }

    /// «12:31» по Москве — когда проверяли.
    static func nowText() -> String {
        timeText(Date())
    }

    /// «12:31» по Москве для любого момента.
    static func timeText(_ d: Date) -> String {
        Fmt.time(Fmt.serverDateTime(d))
    }
}

/// Незавершённая денежная операция на телефоне (правило №5 ОШИБКИ-ПРИЛОЖЕНИЙ): пишется ДО
/// каждого POST, чтобы выгрузка приложения во время запроса или паузы автоповтора не
/// потеряла ключ. Форма того же объекта при открытии поднимает её как «исход неизвестен».
struct MoneyOpPending: Codable {
    /// Ручка (POST).
    var path: String
    /// Ключ повтора.
    var key: String
    /// Тело — ровно те байты, что ушли на сервер (с полем `idempotency_key`).
    /// У создания организации пароль из тела вырезан: на телефоне он не хранится.
    var body: Data
    /// Наибольший id истории перед первой отправкой (nil — прочитать не удалось).
    var baseline: Int?
    /// Первая отправка: с неё сервер 24 ч хранит ответ под ключом.
    var sentAt: Date
    /// Последняя отправка (первая или повтор).
    var lastSentAt: Date
    /// «Провести ещё раз» возможно (нет — при 422 «ключ уже использован»).
    var resendAllowed: Bool
    /// Сколько ждать после последней отправки, прежде чем проверка скажет «операции нет», с.
    var resendWait: Double
    /// Что ещё нужно форме для поиска и показа (например, название магазина выплаты).
    var extra: [String: String]
}

/// Записи `MoneyOpPending` в UserDefaults: один словарь {объект: запись}. Объект — тип
/// операции и id (магазин, клиент, курьер); у выплаты магазин выбирают в самой форме,
/// поэтому запись одна на тип. Записи старше суток (столько сервер помнит ключ) выбрасываются.
enum MoneyOpStore {
    static let defaultsKey = "admin_pending_money_ops"
    static let maxAge: TimeInterval = 24 * 60 * 60

    /// Зачисление/списание кошелька магазина (shops/{id}/topup).
    static func shopTopup(_ shopId: Int) -> String { "shop_topup_" + String(shopId) }
    /// Корректировка кошелька клиента (user-wallets/{id}/correct).
    static func userWallet(_ userId: Int) -> String { "user_wallet_" + String(userId) }
    /// Поправка расчёта курьера (pool/couriers/{id}/adjust).
    static func courierAdjust(_ courierId: Int) -> String { "courier_adjust_" + String(courierId) }
    /// Выплата (payouts): магазин выбирается в форме.
    static let payout = "payout"
    /// Создание организации (shops/create).
    static let shopCreate = "shop_create"

    static func save(_ op: MoneyOpPending, scope: String) {
        guard let data = try? JSONEncoder().encode(op) else { return }
        var all = readAll()
        all[scope] = data
        write(all)
    }

    /// Запись объекта, если есть и не старше суток (заодно выбрасывает все устаревшие).
    static func load(_ scope: String) -> MoneyOpPending? {
        guard let data = purge()[scope] else { return nil }
        return try? JSONDecoder().decode(MoneyOpPending.self, from: data)
    }

    static func remove(_ scope: String) {
        var all = readAll()
        guard all.removeValue(forKey: scope) != nil else { return }
        write(all)
    }

    /// Выбросить записи старше суток (и с датой из будущего больше чем на сутки — часы
    /// перевели) и нечитаемые. Возвращает оставшиеся.
    @discardableResult
    static func purge(now: Date = Date()) -> [String: Data] {
        let all = readAll()
        var kept: [String: Data] = [:]
        for (scope, data) in all {
            guard let op = try? JSONDecoder().decode(MoneyOpPending.self, from: data) else { continue }
            let age = now.timeIntervalSince(op.sentAt)
            if age < maxAge && age > -maxAge { kept[scope] = data }
        }
        if kept.count != all.count { write(kept) }
        return kept
    }

    private static func readAll() -> [String: Data] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
    }

    private static func write(_ all: [String: Data]) {
        if all.isEmpty {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(all, forKey: defaultsKey)
        }
    }
}

/// Что форма получает из записи при открытии: тело последней отправки и `extra`.
struct MoneyOpRestored {
    let body: JSON
    let extra: [String: String]
}

/// Итог отправки денежной формы.
enum MoneyOpOutcome {
    /// Сервер ответил успехом (в том числе сохранённым ответом на повтор).
    case done(APIResult)
    /// Окончательный отказ — операция не проведена, форму можно поправить.
    case failed(APIError)
    /// Исход неизвестен — форма заморожена до проверки. Если
    /// `MoneyOpGuard.shouldAutoCheck` — форма сама сразу запускает проверку истории.
    case unknown(APIError)
    /// Запрос уже идёт (двойной тап) — ничего не делать.
    case ignored
}

/// Страница истории операций: строки (новые сверху) и есть ли следующая.
struct MoneyOpPage {
    let rows: [JSON]
    let more: Bool
    /// Поле `idem` (А618) из data истории: сервер учтёт ключ повтора. Нет поля / 0 — false.
    let idem: Bool

    init(rows: [JSON], more: Bool, idem: Bool = false) {
        self.rows = rows
        self.more = more
        self.idem = idem
    }

    /// Ответ списка {items, pages}: строки из `key`, следующая страница — если pages > page.
    static func paged(_ d: JSON, page: Int, key: String = "items") -> MoneyOpPage {
        let rows = d[key].array
        let pages = d["pages"].int ?? page
        return MoneyOpPage(rows: rows, more: !rows.isEmpty && pages > page, idem: d["idem"].boolValue)
    }
}

/// Состояние денежной формы: ключ повтора, тело последней отправки, неизвестный исход
/// и проверка по истории. Историю читает `history(page)`
/// (страницы с 1, новые сверху).
///
/// Ключ, тело, отметка истории и время отправки пишутся в `MoneyOpStore` до каждого POST
/// и при каждой заморозке; запись снимается окончательным ответом (`finish`) и 503
/// «защита недоступна» на первой отправке. Форма того же объекта при открытии поднимает
/// запись: заморожена, сразу «Проверить» по истории, «Провести ещё раз» — тем же ключом и
/// теми же байтами. Если проверка не нашла операцию — «Забыть операцию» (с подтверждением)
/// освобождает форму под новую операцию с новым ключом.
@MainActor
final class MoneyOpGuard: ObservableObject {
    /// Идёт запрос: окно не закрыть, кнопки недоступны.
    @Published private(set) var busy = false
    /// Идёт проверка истории.
    @Published private(set) var checking = false
    /// Исход последней отправки неизвестен: форма заморожена.
    @Published private(set) var unknown = false
    /// Проверка не нашла операцию в истории — можно провести ещё раз (после подтверждения).
    @Published private(set) var checkedMissing = false
    /// «Провести ещё раз» в принципе возможно (нет — при 422 «ключ уже использован»:
    /// под ключом лежит чужой ответ, повтор вернёт то же).
    @Published private(set) var resendAllowed = true
    /// Текст под формой (неизвестный исход, итог проверки).
    @Published private(set) var note: String?
    /// Показать подтверждение «Операции нет в истории — провести ещё раз?».
    @Published var askResend = false
    /// «Повторяем (1/2)…» — идёт пауза или повторный запрос после неизвестного исхода (А618).
    @Published private(set) var retryNote: String?
    /// Проверка дошла до конца и операции не нашла — можно «Забыть операцию».
    @Published private(set) var canDiscard = false
    /// Показать подтверждение «Забыть эту операцию?».
    @Published var askDiscard = false
    /// Последний неизвестный исход просит сразу проверить историю.
    private(set) var shouldAutoCheck = false

    /// Сколько страниц истории листать при проверке (до отметки «до отправки»).
    static let maxPages = 10
    /// «Провести ещё раз» — не раньше, чем через столько секунд после отправки: сервер мог
    /// ещё дорабатывать запрос, и ранняя проверка дала бы ложное «нет».
    static let resendDelay: TimeInterval = 30
    /// То же после 409 «не удалось узнать результат прошлого запроса»: первая копия могла
    /// ещё идти (сервер так отвечает на отметку старше 120 с) — ждём 2 мин.
    static let staleResendDelay: TimeInterval = 120

    /// Ключ повтора этого окна (заголовок Idempotency-Key и поле idempotency_key).
    private(set) var key = MoneyOp.newKey()
    /// Байты последней отправки (с полем `idempotency_key`) — при повторе уходят они же.
    private var lastData: Data?
    /// Те же байты без ключа (для сверки после 503 «защита недоступна»).
    private var lastPlain: Data?
    /// `idem` из последнего чтения истории (А618): true — сервер учтёт ключ, можно повторять
    /// самому. Каждое чтение обновляет; ошибка чтения, нет поля, 0 — false.
    private(set) var idemSupported = false
    /// Тело (JSON-байты) отправки, закончившейся 503 `idempotency_unavailable`: операции не было,
    /// ключ остаётся; если человек изменил форму — ключ новый.
    private var unsentBody: Data?
    private var lastPath: String?
    /// Объект записи в `MoneyOpStore`.
    private let scope: String
    /// Что ещё форма просила сохранить вместе с отправкой.
    private var extra: [String: String] = [:]
    /// Поднятая при открытии запись — форма забирает её один раз (`takeRestored`).
    private var restored: MoneyOpRestored?
    /// Наибольший id истории перед первой отправкой (nil — не удалось прочитать).
    private var baseline: Int?
    /// Первая отправка (для сверки по времени, если отметки нет).
    private var sentAt: Date?
    /// Последняя отправка (первая или повтор).
    private var lastSentAt: Date?
    /// Сколько ждать после последней отправки, прежде чем проверка может сказать «нет».
    private var resendWait: TimeInterval = MoneyOpGuard.resendDelay
    private let history: (Int) async throws -> MoneyOpPage

    /// - Parameters:
    ///   - scope: объект записи в `MoneyOpStore` (тип операции и id);
    ///   - history: страница истории операций (с 1, новые сверху).
    init(scope: String, history: @escaping (Int) async throws -> MoneyOpPage) {
        self.scope = scope
        self.history = history
        if let p = MoneyOpStore.load(scope) { restore(p) }
    }

    /// Форма заморожена: идёт запрос/проверка или исход неизвестен.
    var locked: Bool { busy || checking || unknown }

    /// Запись с прошлого открытия формы (приложение выгружено во время запроса, форму
    /// закрыли при неизвестном исходе): форма заморожена, проверка — по истории.
    private func restore(_ p: MoneyOpPending) {
        // Тело не читается — форме нечем искать операцию: такая запись только заперла бы форму.
        guard let body = JSON.parse(p.body), body.isObject else {
            MoneyOpStore.remove(scope)
            return
        }
        key = p.key
        lastData = p.body
        lastPlain = nil
        lastPath = p.path
        baseline = p.baseline
        sentAt = p.sentAt
        lastSentAt = p.lastSentAt
        extra = p.extra
        restored = MoneyOpRestored(body: body, extra: p.extra)
        // Приложение могло выгрузиться, пока запрос шёл: сервер мог дорабатывать его дольше
        // обычного — «нет в истории» не раньше чем через 2 мин после последней отправки.
        freeze("Прошлая операция (отправлена в " + MoneyOp.timeText(p.sentAt) + ") осталась без подтверждения — она могла пройти. Проверяем историю; повторно отправить можно только после проверки.",
               wait: max(p.resendWait, MoneyOpGuard.staleResendDelay), allowed: p.resendAllowed, autoCheck: true)
    }

    /// Тело и `extra` поднятой записи — один раз: форма заполняет поля и сразу проверяет историю.
    func takeRestored() -> MoneyOpRestored? {
        defer { restored = nil }
        return restored
    }

    /// Записать текущее состояние на телефон (до каждого POST и при заморозке).
    private func persist() {
        guard let path = lastPath, let data = lastData, let first = sentAt else { return }
        MoneyOpStore.save(MoneyOpPending(path: path, key: key, body: data, baseline: baseline,
                                         sentAt: first, lastSentAt: lastSentAt ?? first,
                                         resendAllowed: resendAllowed, resendWait: resendWait,
                                         extra: extra),
                          scope: scope)
    }

    /// Страница истории + запомнить `idem` (ошибка чтения — false).
    private func readHistory(_ page: Int) async throws -> MoneyOpPage {
        do {
            let p = try await history(page)
            idemSupported = p.idem
            return p
        } catch {
            idemSupported = false
            throw error
        }
    }

    /// Отправить операцию (POST с ключом и долгим ожиданием). Отметка истории берётся
    /// прямо перед отправкой: так в неё не попадёт ничего, что появилось позже.
    /// `extra` сохраняется на телефоне вместе с телом (форме — для поиска после перезапуска).
    func send(_ path: String, body: [String: Any?], extra: [String: String] = [:]) async -> MoneyOpOutcome {
        guard !busy, !checking, !unknown else { return .ignored }
        busy = true
        // Тело не собирается (ошибка кодирования) — до сервера ничего не ушло.
        guard let bodyData = try? JSONBody.data(body) else {
            busy = false
            return .failed(APIError.badResponse("Не удалось подготовить данные для отправки"))
        }
        // Прошлая отправка кончилась 503 «защита от повтора недоступна» (операции не было):
        // то же тело — тот же ключ, изменённое — новый (другая сумма под прежним ключом
        // выглядела бы для сервера подменой запроса).
        if let prev = unsentBody, prev != bodyData { key = MoneyOp.newKey() }
        unsentBody = nil
        // Ключ — и в теле: если хостинг срежет заголовок, сервер возьмёт его отсюда
        // (apiIdemKey), а перед отпечатком тела поле вырезает (apiIdemReplay).
        var keyed = body
        keyed["idempotency_key"] = key
        guard let keyedData = try? JSONBody.data(keyed) else {
            busy = false
            return .failed(APIError.badResponse("Не удалось подготовить данные для отправки"))
        }
        if let first = try? await readHistory(1) {
            baseline = MoneyOp.maxId(first.rows) ?? 0
        } else {
            baseline = nil
            idemSupported = false
        }
        sentAt = Date()
        lastData = keyedData
        lastPlain = bodyData
        lastPath = path
        self.extra = extra
        return await post(afterUnknown: false)
    }

    /// «Провести ещё раз» после проверки и подтверждения: те же байты, ТОТ ЖЕ ключ,
    /// прежняя отметка истории.
    func resend() async -> MoneyOpOutcome {
        guard unknown, checkedMissing, resendAllowed, !busy, !checking,
              lastPath != nil, lastData != nil else { return .ignored }
        busy = true
        return await post(afterUnknown: true)
    }

    private func post(afterUnknown: Bool) async -> MoneyOpOutcome {
        guard let path = lastPath, let sendData = lastData else {
            busy = false
            return .ignored
        }
        shouldAutoCheck = false
        defer { retryNote = nil }
        let sendKey = key
        // Автоповтор — только если сервер сказал `idem` в последнем чтении истории.
        let auto = idemSupported
        var retries = 0
        while true {
            lastSentAt = Date()
            // До каждого POST — на телефон: выгрузка приложения в запросе или в паузе
            // автоповтора не потеряет ключ (правило №5).
            persist()
            do {
                let wait = retries == 0 ? MoneyOp.timeout : MoneyOp.retryTimeout
                let r = try await API.shared.postKeyed(path, bodyData: sendData, key: sendKey, timeout: wait)
                busy = false
                finish()
                return .done(r)
            } catch {
                let e = API.mapTransport(error)
                if auto, retries < MoneyOp.autoRetryPauses.count, MoneyOp.isAutoRetryable(e), !Task.isCancelled {
                    // Исход неизвестен, а сервер учитывает ключ: тот же запрос с тем же ключом и телом
                    // безопасен — он либо выполнится впервые, либо вернёт сохранённый ответ.
                    let pause = MoneyOp.autoRetryPauses[retries]
                    retries += 1
                    retryNote = "Повторяем (" + String(retries) + "/" + String(MoneyOp.autoRetryPauses.count) + ")…"
                    do {
                        try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                    } catch {
                        busy = false
                        return fail(.cancelled, afterUnknown: true)
                    }
                    continue
                }
                busy = false
                // После автоповторов первая попытка тоже была «неизвестной».
                return fail(e, afterUnknown: afterUnknown || retries > 0)
            }
        }
    }

    /// Разбор отказа (`busy` уже снят): неизвестный исход — заморозка, иначе окончательный отказ.
    private func fail(_ e: APIError, afterUnknown: Bool) -> MoneyOpOutcome {
        if MoneyOp.isIdemUnavailable(e) {
            let shown = MoneyOp.unavailableError(e)
            if afterUnknown {
                // Эта отправка не выполнялась, но прошлая могла: проверка по истории, без автоповтора.
                freeze(MoneyOp.unavailableText + "\nПервая попытка могла пройти — проверьте историю; форма остаётся заблокированной.",
                       wait: MoneyOpGuard.resendDelay, allowed: true, autoCheck: false)
                return .unknown(shown)
            }
            // Операции не было: форма свободна, ключ прежний (пока форму не изменили),
            // на телефоне хранить нечего.
            unsentBody = lastPlain
            MoneyOpStore.remove(scope)
            return .failed(shown)
        }
        if MoneyOp.isUnknown(e) {
            freeze(MoneyOp.unknownText(e), wait: MoneyOpGuard.resendDelay, allowed: true, autoCheck: false)
            return .unknown(e)
        }
        switch MoneyOp.idemReply(e) {
        case .inProgress:
            freeze("Сервер ещё выполняет первую попытку («" + e.message + "»). Подождите минуту и проверьте историю.",
                   wait: MoneyOpGuard.resendDelay, allowed: true, autoCheck: false)
            return .unknown(e)
        case .unknownOutcome:
            freeze("Сервер не знает, чем закончилась прошлая попытка: «" + e.message + "». Проверяем историю; провести ещё раз можно не раньше чем через 2 минуты и только если операции в истории нет.",
                   wait: MoneyOpGuard.staleResendDelay, allowed: true, autoCheck: true)
            return .unknown(e)
        case .keyReused:
            // Под этим ключом сервер уже сохранил ответ — операция, скорее всего, прошла.
            freeze("Сервер ответил: «" + e.message + "». Под этим ключом уже сохранён ответ — операция, скорее всего, прошла. Проверяем историю.",
                   wait: MoneyOpGuard.resendDelay, allowed: false, autoCheck: true)
            return .unknown(e)
        case nil:
            break
        }
        let m = e.message.lowercased()
        let noMoney = e.status == 409 && (m.contains("недостаточно") || m.contains("в минус"))
        if e.status == 409 && m.contains("только что") {
            // «Такое же зачисление только что прошло» (adminRepeatGuard) — операция,
            // скорее всего, прошла: блок остаётся, форма сразу проверяет историю.
            freeze("Сервер ответил: «" + e.message + "». Похоже, операция уже прошла — проверяем историю.",
                   wait: MoneyOpGuard.resendDelay, allowed: true, autoCheck: true)
            return .unknown(e)
        }
        if afterUnknown && !noMoney && e.status != 422 {
            // Повтор после неизвестного исхода: отказ не по существу (429, 401, 403/CSRF,
            // 404, прочий 409) не говорит, прошла ли первая попытка, — форма остаётся
            // замороженной, ключ прежний.
            freeze("Повтор не прошёл: «" + e.message + "». Первая попытка могла пройти — проверьте историю; форма остаётся заблокированной.",
                   wait: MoneyOpGuard.resendDelay, allowed: true, autoCheck: false)
            return .unknown(e)
        }
        // Ответ сервера по существу (4xx первой отправки; после неизвестного исхода —
        // «недостаточно средств» / 422 проверки данных) — операция не проведена.
        finish()
        return .failed(e)
    }

    private func freeze(_ text: String, wait: TimeInterval, allowed: Bool, autoCheck: Bool) {
        unknown = true
        checkedMissing = false
        canDiscard = false
        resendAllowed = allowed
        resendWait = wait
        shouldAutoCheck = autoCheck
        note = text
        persist()
    }

    /// «Проверить»: перечитать историю (страницы — до отметки «до отправки») и найти
    /// операцию. Нашлась — строка (форма размораживается, закрывайте как успешную);
    /// нет — nil и `checkedMissing` (если проверка не ранняя и история просмотрена до конца).
    func check(_ match: (JSON) -> Bool) async -> JSON? {
        guard unknown, !busy, !checking else { return nil }
        checking = true
        defer { checking = false }
        do {
            var page = 1
            var complete = false
            while page <= MoneyOpGuard.maxPages {
                let p = try await readHistory(page)
                if let row = MoneyOp.findNew(p.rows, baseline: baseline, sentAt: sentAt, match: match) {
                    finish()
                    return row
                }
                if !p.more || p.rows.isEmpty { complete = true; break }
                // Дальше — только операции старше отправки.
                if let b = baseline {
                    if let low = p.rows.compactMap({ $0.id }).min(), low <= b { complete = true; break }
                } else if let s = sentAt, let oldest = Fmt.parseDate(p.rows.last?["created_at"].string),
                          oldest < s.addingTimeInterval(-600) {
                    complete = true
                    break
                }
                page += 1
            }
            let checked = "Проверено в " + MoneyOp.nowText() + ": "
            guard complete else {
                checkedMissing = false
                canDiscard = true
                note = checked + "в первых " + String(MoneyOpGuard.maxPages) + " страницах истории операции нет, а дальше смотреть долго. Проверьте историю вручную — повторить отсюда нельзя. Операции там нет — «Забыть операцию» и проведите её заново."
                return nil
            }
            let elapsed = Date().timeIntervalSince(lastSentAt ?? .distantPast)
            // elapsed < 0 — часы телефона перевели назад: ждать по ним нечего (иначе «через N с» без конца).
            if elapsed >= 0 && elapsed < resendWait {
                checkedMissing = false
                let wait = Int((resendWait - elapsed).rounded(.up))
                note = checked + "в истории операции пока нет, но сервер мог ещё не закончить. Проверьте ещё раз через " + String(wait) + " с."
                return nil
            }
            guard resendAllowed else {
                checkedMissing = false
                canDiscard = true
                note = checked + "в истории этой операции нет, но сервер уже хранит ответ под этим ключом. Повторить отсюда нельзя: проверьте историю ещё раз и, если операции нет, нажмите «Забыть операцию» и проведите её заново."
                return nil
            }
            checkedMissing = true
            canDiscard = true
            note = checked + "в истории этой операции нет. Если сервер ещё не закончил, она появится через минуту — проверьте ещё раз. Уверены, что не прошла, — «Провести ещё раз»."
            return nil
        } catch {
            note = "Проверить не удалось: " + APIError.describe(error)
                + "\nОперация могла пройти — повторно отправить можно только после проверки."
            // Историю не прочитать (403/404, сбой сайта): запись с телефона иначе запирала бы
            // форму этого объекта на сутки. Выход — «Забыть операцию» после ручной сверки,
            // не раньше обычного ожидания после отправки.
            let elapsed = Date().timeIntervalSince(lastSentAt ?? .distantPast)
            if !APIError.isCancellation(error), elapsed < 0 || elapsed >= resendWait {
                canDiscard = true
                note = (note ?? "") + " Если проверить так и не удаётся — сверьте историю на сайте и, если операции нет, «Забыть операцию»."
            }
            return nil
        }
    }

    /// «Забыть операцию» (после подтверждения): проверка операцию не нашла, человек сверил
    /// историю сам — форма свободна, следующая отправка уйдёт с новым ключом.
    func discard() {
        guard unknown, canDiscard, !busy, !checking else { return }
        finish()
    }

    /// Окончательный ответ: ключ забыт, форма разморожена, запись на телефоне снята.
    private func finish() {
        unknown = false
        checkedMissing = false
        canDiscard = false
        askDiscard = false
        resendAllowed = true
        resendWait = MoneyOpGuard.resendDelay
        shouldAutoCheck = false
        note = nil
        lastData = nil
        lastPlain = nil
        lastPath = nil
        unsentBody = nil
        sentAt = nil
        lastSentAt = nil
        baseline = nil
        extra = [:]
        restored = nil
        key = MoneyOp.newKey()
        MoneyOpStore.remove(scope)
    }
}

/// Блок формы при неизвестном исходе: предупреждение, «Проверить», «Провести ещё раз».
struct MoneyOpUnknownSection: View {
    @ObservedObject var guardian: MoneyOpGuard
    /// Что проверять, например «историю кошелька».
    let whereText: String
    let onCheck: () -> Void

    init(guardian: MoneyOpGuard, whereText: String, onCheck: @escaping () -> Void) {
        self.guardian = guardian
        self.whereText = whereText
        self.onCheck = onCheck
    }

    var body: some View {
        if let retry = guardian.retryNote {
            Section {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(retry).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if guardian.unknown {
            Section {
                InfoBanner(guardian.note ?? "Операция могла пройти — проверьте баланс и историю.",
                           systemImage: "exclamationmark.triangle.fill", color: Brand.amber)
                Button {
                    Haptics.tap()
                    onCheck()
                } label: {
                    HStack {
                        Spacer()
                        if guardian.checking {
                            ProgressView()
                            Text("Проверяем…")
                        } else {
                            Label("Проверить " + whereText, systemImage: "arrow.clockwise")
                                .font(.body.weight(.semibold))
                        }
                        Spacer()
                    }
                }
                .disabled(guardian.busy || guardian.checking)
                if guardian.checkedMissing && guardian.resendAllowed {
                    Button(role: .destructive) {
                        Haptics.warning()
                        guardian.askResend = true
                    } label: {
                        HStack {
                            Spacer()
                            if guardian.busy { ProgressView() } else { Text("Провести ещё раз") }
                            Spacer()
                        }
                    }
                    .disabled(guardian.busy || guardian.checking)
                }
                if guardian.canDiscard {
                    Button {
                        Haptics.warning()
                        guardian.askDiscard = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Забыть операцию")
                            Spacer()
                        }
                    }
                    .disabled(guardian.busy || guardian.checking)
                }
            } header: {
                Text("Операция могла пройти")
            } footer: {
                Text("Форма заблокирована, чтобы операция не прошла дважды. «Закрыть» — можно: операция могла уйти — проверьте список, он обновится. Форма откроется в том же состоянии, пока операция не найдётся или вы её не забудете.")
            }
        }
    }
}

extension View {
    /// Подтверждения «Операции нет в истории — провести ещё раз?» и «Забыть эту операцию?»
    /// для MoneyOpGuard. Вешать на внешний вид листа (у Form может быть свой диалог).
    func moneyOpResendDialog(_ guardian: MoneyOpGuard, onResend: @escaping () -> Void) -> some View {
        modifier(MoneyOpResendDialog(guardian: guardian, onResend: onResend))
    }
}

/// Реализация `.moneyOpResendDialog`.
struct MoneyOpResendDialog: ViewModifier {
    @ObservedObject var guardian: MoneyOpGuard
    let onResend: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Операции нет в истории — провести ещё раз?", isPresented: $guardian.askResend,
                                titleVisibility: .visible) {
                Button("Провести ещё раз", role: .destructive) { onResend() }
                Button("Не проводить", role: .cancel) {}
            } message: {
                Text("Уйдёт тот же запрос. Если первая попытка всё-таки прошла и просто не успела появиться в истории, операция может быть проведена второй раз.")
            }
            .alert("Забыть эту операцию?", isPresented: $guardian.askDiscard) {
                Button("Забыть", role: .destructive) { guardian.discard() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Форма освободится для новой операции с новым ключом. Если прежняя всё-таки прошла, новая проведёт деньги второй раз — сначала сверьте историю.")
            }
    }
}
