import BackgroundTasks
// ObservableObject и @Published живут в Combine: Foundation/UIKit их не дают,
// без этого импорта файл не соберётся («unknown attribute 'Published'»).
import Combine
import Foundation
import UIKit
import UserNotifications

/// Что ждёт администратора — категории вкладки «Заявки» и локальных уведомлений.
///
/// ОТКУДА БЕРЁТСЯ КАЖДЫЙ СЧЁТЧИК (проверено по routes/*.php):
///
/// | категория        | запрос                                           | поле / как считаем                                   |
/// |------------------|--------------------------------------------------|------------------------------------------------------|
/// | registrations    | GET /api/admin/dashboard?period=7                | data.pending_regs (shop_registrations.status=pending) |
/// | publish          | GET /api/admin/dashboard?period=7                | data.pending_publish (shops.status=review)            |
/// | documents        | GET /api/admin/inbox-counts (П-29.3)             | counts.documents; старый сервер — длина массива       |
/// |                  | (запасной: GET /api/admin/documents?status=pending) | data (сервер отдаёт не больше 200)                 |
/// | shopTopups       | GET /api/admin/wallets                           | длина data.pending (ручные: банк/наличные); если      |
/// |                  |                                                  | wallets не ответил — dashboard data.pending_topups    |
/// | onlinePayments   | GET /api/admin/wallets                           | длина data.orphan_online + длина data.stuck_online    |
/// | walletReconcile  | GET /api/admin/wallets                           | data.reconcile.bad (расхождения ночной сверки)        |
/// | userTopups       | GET /api/admin/user-topups?status=pending        | элементы data.items с stale == true (висят > суток;   |
/// |                  |                                                  | сервер отдаёт не больше 200 последних)                |
/// | returns          | inbox-counts (запасной: GET /api/admin/returns?status=pending) | counts.returns / data.total; подпись — dashboard data.stale_returns |
/// | reviews          | GET /api/admin/dashboard?period=7                | data.pending_reviews                                  |
/// | complaints       | GET /api/admin/dashboard?period=7                | data.open_complaints (status=open)                    |
/// | support          | inbox-counts (запасной: GET /api/admin/support/tickets?status=open) | counts.support_tickets / data.total |
/// | adReports        | inbox-counts (запасной: GET /api/admin/ads/reports) | counts.ad_reports / data.total (status=new)        |
/// | shopSupport      | GET /api/admin/shop-support/unread               | data.threads (переписки с непрочитанным от продавцов);|
/// |                  |                                                  | подпись — data.messages (сколько сообщений)           |
/// | couriers         | inbox-counts (А92; запасной: GET /api/admin/pool/summary) | counts.pool_couriers_pending / data.pending |
/// | courierProblems  | inbox-counts (А92; запасной: GET /api/admin/pool/summary) | counts.pool_problems_open / data.open_problems |
/// | courierComplaints| inbox-counts (А92; запасной: GET /api/admin/pool/summary) | counts.pool_complaints_open / data.open_complaints |
/// | cron             | GET /api/admin/dashboard?period=7                | data.cron.stale → 1, иначе 0                          |
///
/// «Курьеры Yumurta» (волна А92, ответ на П-45 №1): сервер отдаёт их счётчики в
/// inbox-counts (pool_couriers_pending, pool_problems_open, pool_complaints_open — те же
/// условия, что в /api/admin/pool/summary). Тогда сводку раздела раз в минуту НЕ опрашиваем.
/// counts.total сервер считает без них, counts.total_all — с ними; бейдж — сумма включённых
/// категорий (Notifier.total), поэтому курьерские счётчики входят в него ровно один раз —
/// из inbox-counts или (старый сервер) из сводки, но никогда из обоих.
/// Старый сервер (в inbox-counts этих полей нет) — как раньше, сводкой раздела. Сервер без
/// раздела (404) или с выключенным разделом (503) — не ошибка опроса: счётчиков этих
/// категорий нет (counts[c] == nil), и вкладка «Заявки» их строки не показывает
/// (NotifyCategory.hiddenWithoutCount) — иначе они висели бы в «Пусто» и вели в 404.
/// inbox-counts при отсутствии таблиц раздела отдаёт нули, поэтому, пока все три — 0,
/// один раз за запуск проверяем сводкой, есть ли раздел (Notifier.poolAvailable).
///
/// Чего нет и почему: «Выплаты» — выплаты создаёт сам админ (сразу «выплачено»),
/// заявок от продавцов на сервере нет; «Товары» — у товаров нет статуса «на
/// модерации» (только active/hidden). Поэтому этих категорий нет.
enum NotifyCategory: String, CaseIterable, Identifiable {
    case registrations, publish, documents, shopTopups, onlinePayments, walletReconcile
    case userTopups, returns, reviews, complaints, support, shopSupport, adReports
    // «Курьеры Yumurta»: заявки на проверке, проблемы с доставкой, жалобы по вызовам.
    case couriers, courierProblems, courierComplaints
    case cron

    var id: String { rawValue }

    /// Подпись строки во вкладке «Заявки» и в настройках.
    var title: String {
        switch self {
        case .registrations: return "Заявки на регистрацию магазинов"
        case .publish: return "Организации ждут публикации"
        case .documents: return "Лицензии на проверке"
        case .shopTopups: return "Пополнения продавцов к подтверждению"
        case .onlinePayments: return "Онлайн-оплаты без зачисления"
        case .walletReconcile: return "Расхождения сверки кошельков"
        case .userTopups: return "Пополнения клиентов висят больше суток"
        case .returns: return "Возвраты на рассмотрении"
        case .reviews: return "Отзывы на модерации"
        case .complaints: return "Новые жалобы"
        case .support: return "Открытые обращения в поддержку"
        case .shopSupport: return "Сообщения продавцам"
        case .adReports: return "Жалобы на объявления"
        case .couriers: return "Заявки курьеров"
        case .courierProblems: return "Проблемы с доставкой курьеров"
        case .courierComplaints: return "Жалобы по доставкам курьеров"
        case .cron: return "Фоновые задачи не запускаются"
        }
    }

    /// Заголовок локального уведомления.
    var notifyTitle: String {
        switch self {
        case .registrations: return "Новая заявка магазина"
        case .publish: return "Организация ждёт публикации"
        case .documents: return "Новая лицензия на проверку"
        case .shopTopups: return "Пополнение продавца ждёт подтверждения"
        case .onlinePayments: return "Онлайн-оплата не зачислена"
        case .walletReconcile: return "Сверка кошельков нашла расхождения"
        case .userTopups: return "Пополнение клиента висит больше суток"
        case .returns: return "Новый возврат"
        case .reviews: return "Отзыв ждёт модерации"
        case .complaints: return "Новая жалоба"
        case .support: return "Новое обращение в поддержку"
        case .shopSupport: return "Сообщение от организации"
        case .adReports: return "Жалоба на объявление"
        case .couriers: return "Новая заявка курьера"
        case .courierProblems: return "Проблема с доставкой"
        case .courierComplaints: return "Жалоба по доставке курьера"
        case .cron: return "Крон не работает"
        }
    }

    /// Раздел, который открывается по тапу.
    var section: AdminSection {
        switch self {
        case .registrations, .publish, .documents: return .registrations
        case .shopTopups, .onlinePayments, .walletReconcile, .userTopups: return .wallets
        case .returns: return .returns
        case .reviews: return .reviews
        case .complaints: return .complaints
        case .support: return .support
        case .shopSupport: return .shopSupport
        case .adReports: return .ads
        case .couriers, .courierProblems, .courierComplaints: return .couriers
        case .cron: return .dashboard
        }
    }

    /// Вкладка внутри раздела (rawValue вкладки раздела), nil — вкладка по умолчанию.
    /// Публикация и лицензии — сегменты «Заявок магазинов» (RegistrationsTab);
    /// «topups» — вкладка «Пополнения» кошельков (WalletsTab), её учтёт
    /// AdminSection.makeRoot, когда WalletsRootView научится принимать вкладку.
    var subtab: String? {
        switch self {
        case .publish: return "publish"
        case .documents: return "documents"
        case .userTopups: return "topups"
        // Раздел «Сообщения продавцам» откроется с фильтром «Непрочитанные».
        case .shopSupport: return "unread"
        // Вкладки раздела «Курьеры» (CouriersTab); заявки — вкладка по умолчанию.
        case .courierProblems: return "problems"
        case .courierComplaints: return "complaints"
        default: return nil
        }
    }

    /// Строку категории не показывать во вкладке «Заявки», пока у неё нет счётчика
    /// (counts[c] == nil): раздела нет на сервере или он выключен. Только «Курьеры» —
    /// у остальных категорий поведение прежнее.
    var hiddenWithoutCount: Bool {
        switch self {
        case .couriers, .courierProblems, .courierComplaints: return true
        default: return false
        }
    }

    /// Это сигнал-тревога (0/1), а не очередь штук.
    var isAlarm: Bool { self == .cron }

    /// О категории сервер присылает свой push (П-29.2). Пока токен телефона
    /// подтверждён (AdminPush.serverPushRegistered), локальный баннер о ней не
    /// нужен — счётчики, бейдж и «Заявки» обновляются как раньше.
    var serverPushed: Bool {
        switch self {
        case .registrations, .publish, .documents, .shopTopups, .returns:
            return true
        case .complaints, .support, .shopSupport, .adReports:
            return true
        // pool_courier / pool_problem / pool_complaint (core/CourierPool.php → notifyAdminsEvent).
        case .couriers, .courierProblems, .courierComplaints:
            return true
        case .onlinePayments, .walletReconcile, .userTopups, .reviews, .cron:
            return false
        }
    }

    /// Категория серверного push по его type (для переключателей в настройках).
    static func forPushType(_ type: String) -> NotifyCategory? {
        switch type {
        case "shop_registration": return .registrations
        case "shop_publish_request": return .publish
        case "org_document": return .documents
        case "topup_request": return .shopTopups
        case "return_request": return .returns
        case "complaint": return .complaints
        case "support_ticket": return .support
        case "shop_support": return .shopSupport
        case "ad_report": return .adReports
        case "moderation_backlog": return .reviews
        case "pool_courier": return .couriers
        case "pool_problem": return .courierProblems
        case "pool_complaint": return .courierComplaints
        default: return nil
        }
    }

    /// Текст уведомления: сколько добавилось и сколько всего ждёт.
    func notifyBody(added: Int, total: Int) -> String {
        if isAlarm {
            return "Комиссии, подписки и снятие объявлений не выполняются. Проверьте крон на хостинге."
        }
        if self == .walletReconcile {
            return "Расхождений: " + String(total) + ". Откройте «Кошельки»."
        }
        if self == .shopSupport {
            return "Переписок с непрочитанным: " + String(total)
        }
        let plus = added > 0 ? "+" + String(added) + " · " : ""
        return plus + "всего ждут: " + String(total)
    }
}

/// Опрос «что ждёт администратора» + локальные уведомления + бейдж.
///
/// Работает без сервера push: опрашивает счётчики (см. таблицу у NotifyCategory)
///   * при возврате в приложение и каждые 60 с, пока оно открыто;
///   * в фоне через BGAppRefreshTask `ru.marketplace.admin.refresh` (iOS решает
///     сама, когда: обычно раз в 15–60 минут, если приложением пользуются).
/// Если очередь выросла с прошлого раза — локальное уведомление этой категории
/// (если она включена в настройках). Бейдж иконки = сумма включённых категорий.
/// Первый опрос после входа только запоминает значения — без уведомлений.
@MainActor
final class Notifier: ObservableObject {
    /// Единственный экземпляр.
    static let shared = Notifier()

    /// Идентификатор фоновой задачи (BGTaskSchedulerPermittedIdentifiers в project.yml).
    nonisolated static let backgroundTaskId = "ru.marketplace.admin.refresh"

    /// Текущие значения счётчиков (нет ключа — ещё не получено).
    @Published private(set) var counts: [NotifyCategory: Int] = [:]
    /// Пояснения к строкам («из них 3 ждут больше 72 часов»).
    @Published private(set) var notes: [NotifyCategory: String] = [:]
    /// Когда счётчики последний раз обновились.
    @Published private(set) var lastUpdated: Date?
    /// Текст ошибки последнего опроса (nil — всё получено).
    @Published private(set) var lastError: String?
    /// Идёт опрос.
    @Published private(set) var isRefreshing = false
    /// Разрешение iOS на уведомления.
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Выключенные пользователем категории.
    @Published private(set) var disabled: Set<NotifyCategory> = []

    private let seenKey = "admin.notifier.lastSeen"
    private let disabledKey = "admin.notifier.disabled"
    private let askedKey = "admin.notifier.permissionAsked"
    private var timer: Timer?
    private var lastAttempt: Date?
    /// Есть ли на сервере раздел «Курьеры» (nil — ещё не знаем). Нужен, только когда
    /// счётчики приходят из inbox-counts и все три — 0: нули сервер отдаёт и без таблиц
    /// раздела, а строки «Курьеров» на таком сервере вели бы в 503. Один запрос сводки
    /// за запуск; любой ненулевой счётчик — раздел точно есть.
    private var poolAvailable: Bool?

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: disabledKey) ?? []
        disabled = Set(raw.compactMap { NotifyCategory(rawValue: $0) })
    }

    // MARK: - Настройки категорий

    /// Включена ли категория (уведомления и бейдж).
    func isEnabled(_ c: NotifyCategory) -> Bool { !disabled.contains(c) }

    /// Включить/выключить категорию.
    func setEnabled(_ c: NotifyCategory, _ on: Bool) {
        if on { disabled.remove(c) } else { disabled.insert(c) }
        UserDefaults.standard.set(disabled.map { $0.rawValue }, forKey: disabledKey)
        updateBadge()
    }

    /// Сумма включённых категорий (для бейджа вкладки «Заявки» и иконки).
    var total: Int {
        var sum = 0
        for (c, n) in counts where isEnabled(c) { sum += max(0, n) }
        return sum
    }

    /// Значение категории (0, если ещё не получено).
    func count(_ c: NotifyCategory) -> Int { counts[c] ?? 0 }

    /// Показывать ли строку категории во вкладке «Заявки» (см. hiddenWithoutCount).
    func isListed(_ c: NotifyCategory) -> Bool {
        !(c.hiddenWithoutCount && counts[c] == nil)
    }

    // MARK: - Разрешение

    /// Спрашивали ли уже разрешение после входа.
    var permissionAsked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    /// Запросить разрешение iOS на уведомления. true — разрешено.
    @discardableResult
    func requestPermission() async -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }

    /// Перечитать состояние разрешения (могли поменять в «Настройках» iOS).
    func refreshAuthorization() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        authorization = s.authorizationStatus
    }

    // MARK: - Опрос

    /// Начать опрос каждые 60 секунд (пока приложение на экране).
    func start() {
        stop()
        let t = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await Notifier.shared.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await refresh() }
    }

    /// Остановить опрос (ушли в фон, вышли).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Обновить счётчики. Без `force` не чаще раза в 20 секунд.
    func refresh(force: Bool = false) async {
        guard Session.shared.isLoggedIn, !isRefreshing else { return }
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < 20 { return }
        lastAttempt = Date()
        isRefreshing = true
        defer { isRefreshing = false }

        async let dashF = Notifier.fetch("/api/admin/dashboard", ["period": "7"])
        async let walletsF = Notifier.fetch("/api/admin/wallets", [:])
        // П-29.3: лицензии, возвраты, обращения и жалобы на объявления — одним
        // запросом (настоящие COUNT(*), у лицензий без обрезки на 200). Сводка,
        // кошельки, пополнения клиентов и переписка остаются: из них берутся крон,
        // онлайн-оплаты, сверка, «висят больше суток» и подписи.
        async let inboxF = Notifier.fetch("/api/admin/inbox-counts", [:])
        async let userTopF = Notifier.fetch("/api/admin/user-topups", ["status": "pending"])
        // Переписка с организациями (волна А66): дешёвый счётчик без DDL на сервере.
        async let shopSupF = Notifier.fetch("/api/admin/shop-support/unread", [:])
        let dash = await dashF
        let wallets = await walletsF
        let inbox = await inboxF
        let userTop = await userTopF
        let shopSup = await shopSupF
        let inboxCounts = Notifier.inboxCounts(inbox.json)
        // «Курьеры Yumurta»: счётчики из inbox-counts (А92). Их там нет (старый сервер) —
        // сводкой раздела, как раньше. Есть, но все нули и наличие раздела ещё не
        // проверяли — тоже сводкой, один раз (см. poolAvailable).
        let inboxPool = Notifier.poolCounts(inboxCounts)
        let poolFromSummary = inboxPool == nil
        let poolProbe = !poolFromSummary && poolAvailable == nil && !(inboxPool?.values.contains(where: { $0 > 0 }) ?? false)
        var pool = Fetched(json: nil, error: nil)
        if poolFromSummary || poolProbe {
            pool = await Notifier.fetch("/api/admin/pool/summary", [:])
        }
        // inbox-counts не ответил (старый сервер) — прежние запросы по спискам.
        var docs = Fetched(json: nil, error: nil)
        var rets = Fetched(json: nil, error: nil)
        var support = Fetched(json: nil, error: nil)
        var ads = Fetched(json: nil, error: nil)
        if inboxCounts == nil {
            async let docsF = Notifier.fetch("/api/admin/documents", ["status": "pending"])
            async let returnsF = Notifier.fetch("/api/admin/returns", ["status": "pending", "page": "1"])
            async let supportF = Notifier.fetch("/api/admin/support/tickets", ["status": "open", "page": "1"])
            async let adsF = Notifier.fetch("/api/admin/ads/reports", ["page": "1"])
            docs = await docsF
            rets = await returnsF
            support = await supportF
            ads = await adsF
        }
        guard Session.shared.isLoggedIn, !Task.isCancelled else { return }
        // Сколько запросов в опросе (все упали — показываем текст первой ошибки).
        // +1 — сводка курьеров, если счётчики берём из неё; её отсутствие на сервере
        // (404/503) ошибкой не считаем. Разовая проверка раздела (poolProbe) не в счёт.
        var sourceCount = (inboxCounts == nil ? 8 : 5) + (poolFromSummary ? 1 : 0)

        var next = counts
        var nextNotes = notes
        var failed: [String] = []
        var firstError: Error?
        func fail(_ name: String, _ f: Fetched) {
            failed.append(name)
            if firstError == nil { firstError = f.error }
        }

        if let d = dash.json {
            next[.registrations] = d["pending_regs"].intValue
            next[.publish] = d["pending_publish"].intValue
            next[.reviews] = d["pending_reviews"].intValue
            next[.complaints] = d["open_complaints"].intValue
            next[.cron] = d["cron"]["stale"].boolValue ? 1 : 0
            nextNotes[.cron] = Notifier.cronNote(d["cron"])
            let stale = d["stale_returns"].intValue
            nextNotes[.returns] = stale > 0 ? "Без ответа больше 72 часов: " + String(stale) : nil
        } else { fail("Сводка", dash) }

        if let w = wallets.json {
            next[.shopTopups] = w["pending"].array.count
            next[.onlinePayments] = w["orphan_online"].array.count + w["stuck_online"].array.count
            next[.walletReconcile] = w["reconcile"]["bad"].intValue
        } else {
            if let d = dash.json { next[.shopTopups] = d["pending_topups"].intValue }
            fail("Кошельки", wallets)
        }

        if let ic = inboxCounts {
            next[.documents] = ic["documents"].intValue
            next[.returns] = ic["returns"].intValue
            next[.support] = ic["support_tickets"].intValue
            next[.adReports] = ic["ad_reports"].intValue
        } else {
            if let j = docs.json { next[.documents] = j.array.count } else { fail("Лицензии", docs) }
            if let j = rets.json { next[.returns] = Notifier.totalOf(j) } else { fail("Возвраты", rets) }
            if let j = support.json { next[.support] = Notifier.totalOf(j) } else { fail("Поддержка", support) }
            if let j = ads.json { next[.adReports] = Notifier.totalOf(j) } else { fail("Объявления", ads) }
        }
        if let j = userTop.json {
            next[.userTopups] = j["items"].array.filter { $0["stale"].boolValue }.count
        } else { fail("Пополнения клиентов", userTop) }
        if let j = shopSup.json {
            next[.shopSupport] = j["threads"].intValue
            let msgs = j["messages"].intValue
            nextNotes[.shopSupport] = msgs > 0 ? "Непрочитанных сообщений: " + String(msgs) : nil
        } else { fail("Сообщения продавцам", shopSup) }
        if let pc = inboxPool {
            // Счётчики из inbox-counts. Ненулевой — раздел точно есть; разовая проверка
            // сводкой: ответила — есть, 404/503 — нет; сбой сети — спросим в следующий раз.
            if pc.values.contains(where: { $0 > 0 }) {
                poolAvailable = true
            } else if poolProbe {
                if pool.json != nil {
                    poolAvailable = true
                } else if Notifier.sectionMissing(pool.error) {
                    poolAvailable = false
                }
            }
            for c in [NotifyCategory.couriers, .courierProblems, .courierComplaints] {
                next[c] = poolAvailable == false ? nil : pc[c]
            }
        } else if let j = pool.json {
            next[.couriers] = j["pending"].intValue
            next[.courierProblems] = j["open_problems"].intValue
            next[.courierComplaints] = j["open_complaints"].intValue
        } else if Notifier.sectionMissing(pool.error) {
            // Раздела нет (старый сервер) или он выключен — строк «Курьеров» нет, это не сбой.
            sourceCount -= 1
            next[.couriers] = nil
            next[.courierProblems] = nil
            next[.courierComplaints] = nil
        } else { fail("Курьеры", pool) }

        counts = next
        notes = nextNotes
        if failed.count == sourceCount {
            lastError = firstError.map { APIError.describe($0) } ?? "Не удалось обновить"
        } else if !failed.isEmpty {
            lastError = "Не обновилось: " + failed.joined(separator: ", ")
        } else {
            lastError = nil
        }
        if failed.count < sourceCount { lastUpdated = Date() }
        await announceGrowth(next)
        updateBadge()
    }

    /// Забыть всё (выход из аккаунта).
    func reset() {
        stop()
        counts = [:]
        notes = [:]
        lastUpdated = nil
        lastError = nil
        lastAttempt = nil
        poolAvailable = nil
        UserDefaults.standard.removeObject(forKey: seenKey)
        UserDefaults.standard.removeObject(forKey: askedKey)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UIApplication.shared.applicationIconBadgeNumber = 0
    }

    // MARK: - Фон

    /// Зарегистрировать обработчик фоновой проверки. Звать из didFinishLaunching.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleBackground(refreshTask)
        }
    }

    /// Заказать следующую фоновую проверку (не раньше чем через 15 минут).
    nonisolated static func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    nonisolated private static func handleBackground(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor in
            await Notifier.shared.refresh(force: true)
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - Внутреннее

    /// Результат одного запроса опроса.
    struct Fetched {
        let json: JSON?
        let error: Error?
    }

    nonisolated private static func fetch(_ path: String, _ query: [String: String?]) async -> Fetched {
        do {
            let j = try await API.shared.get(path, query: query)
            return Fetched(json: j, error: nil)
        } catch {
            return Fetched(json: nil, error: error)
        }
    }

    /// counts из GET /api/admin/inbox-counts (П-29.3), если в нём есть все нужные
    /// поля; иначе nil — тогда опрос идёт прежними запросами по спискам.
    private static func inboxCounts(_ j: JSON?) -> JSON? {
        guard let c = j?["counts"], c.isObject else { return nil }
        for key in ["documents", "returns", "support_tickets", "ad_reports"] where c[key].int == nil {
            return nil
        }
        return c
    }

    /// Счётчики «Курьеров Yumurta» из counts ответа inbox-counts (волна А92); nil — старый
    /// сервер без этих полей (тогда — сводка раздела). Только если пришли все три.
    private static func poolCounts(_ c: JSON?) -> [NotifyCategory: Int]? {
        guard let c = c,
              let pending = c["pool_couriers_pending"].int,
              let problems = c["pool_problems_open"].int,
              let complaints = c["pool_complaints_open"].int else { return nil }
        return [.couriers: max(0, pending), .courierProblems: max(0, problems), .courierComplaints: max(0, complaints)]
    }

    /// Ручки раздела нет (404) или раздел выключен на сервере (503 «временно недоступны»).
    private static func sectionMissing(_ error: Error?) -> Bool {
        guard let e = error as? APIError else { return false }
        return e.status == 404 || e.status == 503
    }

    /// total из постраничного ответа {items,total,…}; без total — длина items/массива.
    private static func totalOf(_ j: JSON) -> Int {
        if let t = j["total"].int { return t }
        if j.isArray { return j.array.count }
        return j["items"].array.count
    }

    /// shop_id единственной переписки с непрочитанным (nil — их не одна или запрос не прошёл).
    nonisolated private static func singleUnreadShopId() async -> Int? {
        guard let j = try? await API.shared.get("/api/admin/shop-support/threads",
                                                query: ["filter": "unread", "page": "1"]) else { return nil }
        let items = j["items"].array
        guard items.count == 1 else { return nil }
        return items[0]["shop_id"].int
    }

    private static func cronNote(_ c: JSON) -> String? {
        if c["never"].boolValue { return "Крон ни разу не отмечался на сервере" }
        guard c["stale"].boolValue else { return nil }
        if let m = c["minutes_ago"].int { return "Последний запуск " + String(m) + " мин назад" }
        return nil
    }

    /// Уведомить о росте очередей с прошлого раза.
    private func announceGrowth(_ now: [NotifyCategory: Int]) async {
        var seen = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: Int]) ?? [:]
        for c in NotifyCategory.allCases {
            guard let value = now[c] else { continue }
            let prev = seen[c.rawValue]
            seen[c.rawValue] = value
            guard let p = prev, value > p, isEnabled(c) else { continue }
            // Сервер уже прислал push об этом событии — второй (локальный) баннер не нужен.
            if c.serverPushed && AdminPush.serverPushRegistered { continue }
            await post(c, added: value - p, total: value)
        }
        UserDefaults.standard.set(seen, forKey: seenKey)
    }

    private func post(_ c: NotifyCategory, added: Int, total: Int) async {
        let content = UNMutableNotificationContent()
        content.title = c.notifyTitle
        content.body = c.notifyBody(added: added, total: total)
        content.sound = .default
        content.threadIdentifier = c.rawValue
        var info: [String: String] = ["section": c.section.rawValue, "category": c.rawValue]
        if let sub = c.subtab { info["subtab"] = sub }
        // Ровно одна переписка с непрочитанным — тап откроет сразу её чат (id = shop_id).
        // Лишний запрос — только когда приложение на экране (в фоне iOS даёт мало времени).
        let active = UIApplication.shared.applicationState == .active
        if c == .shopSupport && total == 1 && active, let sid = await Notifier.singleUnreadShopId() {
            info["id"] = String(sid)
        }
        content.userInfo = info
        // Один идентификатор на категорию: новое уведомление заменяет старое,
        // а не копит десятки одинаковых.
        let req = UNNotificationRequest(identifier: "admin." + c.rawValue, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    private func updateBadge() {
        UIApplication.shared.applicationIconBadgeNumber = Session.shared.isLoggedIn ? total : 0
    }
}
