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

    /// Новый ключ повтора (на окно / действие): латиница, цифры и «-» — сервер их сохраняет как есть.
    static func newKey() -> String { "adm-" + UUID().uuidString.lowercased() }

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
        Fmt.time(Fmt.serverDateTime(Date()))
    }
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

    init(rows: [JSON], more: Bool) {
        self.rows = rows
        self.more = more
    }

    /// Ответ списка {items, pages}: строки из `key`, следующая страница — если pages > page.
    static func paged(_ d: JSON, page: Int, key: String = "items") -> MoneyOpPage {
        let rows = d[key].array
        let pages = d["pages"].int ?? page
        return MoneyOpPage(rows: rows, more: !rows.isEmpty && pages > page)
    }
}

/// Состояние денежной формы: ключ повтора, тело последней отправки, неизвестный исход
/// и проверка по истории. Историю читает `history(page)`
/// (страницы с 1, новые сверху).
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
    /// Тело последней отправки — при «Провести ещё раз» уходит оно же.
    private(set) var lastBody: [String: Any?]?
    private var lastPath: String?
    /// Наибольший id истории перед первой отправкой (nil — не удалось прочитать).
    private var baseline: Int?
    /// Первая отправка (для сверки по времени, если отметки нет).
    private var sentAt: Date?
    /// Последняя отправка (первая или повтор).
    private var lastSentAt: Date?
    /// Сколько ждать после последней отправки, прежде чем проверка может сказать «нет».
    private var resendWait: TimeInterval = MoneyOpGuard.resendDelay
    private let history: (Int) async throws -> MoneyOpPage

    /// - Parameter history: страница истории операций (с 1, новые сверху).
    init(history: @escaping (Int) async throws -> MoneyOpPage) {
        self.history = history
    }

    /// Форма заморожена: идёт запрос/проверка или исход неизвестен.
    var locked: Bool { busy || checking || unknown }

    /// Отправить операцию (POST с ключом и долгим ожиданием). Отметка истории берётся
    /// прямо перед отправкой: так в неё не попадёт ничего, что появилось позже.
    func send(_ path: String, body: [String: Any?]) async -> MoneyOpOutcome {
        guard !busy, !checking, !unknown else { return .ignored }
        busy = true
        // Тело не собирается (ошибка кодирования) — до сервера ничего не ушло.
        if (try? JSONBody.data(body)) == nil {
            busy = false
            return .failed(APIError.badResponse("Не удалось подготовить данные для отправки"))
        }
        if let first = try? await history(1) {
            baseline = MoneyOp.maxId(first.rows) ?? 0
        } else {
            baseline = nil
        }
        sentAt = Date()
        lastBody = body
        lastPath = path
        return await post(path, body: body, afterUnknown: false)
    }

    /// «Провести ещё раз» после проверки и подтверждения: то же тело, ТОТ ЖЕ ключ,
    /// прежняя отметка истории.
    func resend() async -> MoneyOpOutcome {
        guard unknown, checkedMissing, resendAllowed, !busy, !checking,
              let path = lastPath, let body = lastBody else { return .ignored }
        busy = true
        return await post(path, body: body, afterUnknown: true)
    }

    private func post(_ path: String, body: [String: Any?], afterUnknown: Bool) async -> MoneyOpOutcome {
        lastSentAt = Date()
        shouldAutoCheck = false
        // Ключ — и в теле: если хостинг срежет заголовок, сервер возьмёт его отсюда
        // (apiIdemKey), а перед отпечатком тела поле вырезает (apiIdemReplay).
        var sendBody = body
        sendBody["idempotency_key"] = key
        do {
            let r = try await API.shared.postKeyed(path, body: sendBody, key: key, timeout: MoneyOp.timeout)
            busy = false
            finish()
            return .done(r)
        } catch {
            busy = false
            let e = API.mapTransport(error)
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
    }

    private func freeze(_ text: String, wait: TimeInterval, allowed: Bool, autoCheck: Bool) {
        unknown = true
        checkedMissing = false
        resendAllowed = allowed
        resendWait = wait
        shouldAutoCheck = autoCheck
        note = text
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
                let p = try await history(page)
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
                note = checked + "в первых " + String(MoneyOpGuard.maxPages) + " страницах истории операции нет, а дальше смотреть долго. Проверьте историю вручную — повторить отсюда нельзя."
                return nil
            }
            let elapsed = Date().timeIntervalSince(lastSentAt ?? .distantPast)
            if elapsed < resendWait {
                checkedMissing = false
                let wait = Int((resendWait - elapsed).rounded(.up))
                note = checked + "в истории операции пока нет, но сервер мог ещё не закончить. Проверьте ещё раз через " + String(wait) + " с."
                return nil
            }
            guard resendAllowed else {
                checkedMissing = false
                note = checked + "в истории этой операции нет, но сервер уже хранит ответ под этим ключом. Повторить отсюда нельзя: закройте форму, проверьте историю ещё раз и, если операции нет, проведите её заново."
                return nil
            }
            checkedMissing = true
            note = checked + "в истории этой операции нет. Если сервер ещё не закончил, она появится через минуту — проверьте ещё раз. Уверены, что не прошла, — «Провести ещё раз»."
            return nil
        } catch {
            note = "Проверить не удалось: " + APIError.describe(error)
                + "\nОперация могла пройти — повторно отправить можно только после проверки."
            return nil
        }
    }

    /// Окончательный ответ: ключ забыт, форма разморожена.
    private func finish() {
        unknown = false
        checkedMissing = false
        resendAllowed = true
        resendWait = MoneyOpGuard.resendDelay
        shouldAutoCheck = false
        note = nil
        lastBody = nil
        lastPath = nil
        sentAt = nil
        lastSentAt = nil
        baseline = nil
        key = MoneyOp.newKey()
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
            } header: {
                Text("Операция могла пройти")
            } footer: {
                Text("Форма заблокирована, чтобы операция не прошла дважды. «Закрыть» — можно: операция могла уйти — проверьте список, он обновится.")
            }
        }
    }
}

extension View {
    /// Подтверждение «Операции нет в истории — провести ещё раз?» для MoneyOpGuard.
    /// Вешать на внешний вид листа (у Form может быть свой диалог).
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
    }
}
