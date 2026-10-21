import SwiftUI

/// Какой лист открыт в карточке курьера.
enum CourierSheet: String, Identifiable {
    case reject, block, unblock, cashLimit, adjust

    var id: String { rawValue }
}

/// Карточка курьера: GET /api/admin/pool/couriers/{user_id} (CourierPool::adminCourier).
///
/// Всё из заявки (ФИО, телефон, город, машина, кузов, грузоподъёмность, грузчики,
/// межгород и цена за км, самозанятость, согласие), фото лица и водительского
/// удостоверения (с увеличением), деньги (долг, сальдо по заведениям, лимит наличных),
/// последние доставки, проблемы и жалобы, история решений (журнал audit_log).
///
/// Решения — POST /api/admin/pool/couriers/{id}/approve|reject|block|unblock {note}
/// (CourierPool::adminDecide): отказ и блокировка — только с причиной (курьер её увидит),
/// одобрить нельзя без фото и прав (409 no_docs), из чужого статуса — 409 bad_status.
/// Ответ — та же карточка (+ already: статус уже был таким).
struct CourierDetailView: View {
    let id: Int
    /// Вызывается после любого изменения. Открывший экран НЕ должен сразу перезагружать
    /// список, из строки которого открыта карточка (строка сменит ключ — карточка
    /// закроется): ставьте пометку и обновляйте при возврате (CouriersListScreen).
    let onChanged: (() -> Void)?

    @StateObject private var loader: ObjectLoader
    @StateObject private var history: CourierHistoryLoader
    @State private var sheet: CourierSheet?
    @State private var notice: String?
    /// Сообщение, отложенное до закрытия листа (алерт поверх листа может не показаться).
    @State private var pendingNotice: String?
    /// Меняется при «потянуть, чтобы обновить» — миниатюры документов грузятся заново.
    @State private var docsReload = 0

    init(id: Int, onChanged: (() -> Void)? = nil) {
        self.id = id
        self.onChanged = onChanged
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/pool/couriers/" + String(id)))
        _history = StateObject(wrappedValue: CourierHistoryLoader(courierId: id))
    }

    private var c: JSON { loader.data }
    private var status: String { c["status"].stringValue }
    private var base: String { "/api/admin/pool/couriers/" + String(id) }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            content
        }
        .navigationTitle(c["full_name"].nonEmptyString ?? "Курьер")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loader.loadIfNeeded()
            await history.loadIfNeeded()
        }
        .sheet(item: $sheet, onDismiss: showPendingNotice) { s in
            sheetView(s)
        }
        .alert(notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
    }

    private func showPendingNotice() {
        guard let text = pendingNotice else { return }
        pendingNotice = nil
        notice = text
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private var content: some View {
        List {
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            Group {
                CourierHeaderSection(c: c)
                CourierDocsSection(courierId: id, c: c, reload: docsReload)
                actionsSection
                CourierContactsSection(c: c)
                CourierVehicleSection(c: c)
            }
            Group {
                CourierWorkSection(c: c)
                CourierMoneySection(c: c, onCashLimit: { sheet = .cashLimit }, onAdjust: { sheet = .adjust })
                CourierActivitySections(c: c)
                CourierHistorySection(c: c, history: history)
                Section { JSONInspectorView(c) }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refreshAll() }
    }

    /// «Потянуть, чтобы обновить»: карточка, журнал и фото документов (у одобренного
    /// курьера дата заявки не меняется, а фото он мог заменить — кэш сбрасываем).
    private func refreshAll() async {
        let version = c["submitted_at"].stringValue
        let docs = "/api/admin/pool/couriers/" + String(id) + "/doc/"
        CourierImageCache.remove(path: docs + "photo", version: version)
        CourierImageCache.remove(path: docs + "license", version: version)
        await loader.load()
        docsReload += 1
        await history.load()
    }

    // MARK: - Решение

    private var docsReady: Bool { c["has_photo"].boolValue && c["has_license"].boolValue }

    private var actionsSection: some View {
        Section {
            if status == "pending" || status == "rejected" {
                ActionButton("Одобрить", systemImage: "checkmark", style: .prominent,
                             confirm: ConfirmAction(title: "Одобрить курьера?",
                                                    message: "Курьер сможет выходить на линию и брать заказы. Ему придёт уведомление.",
                                                    confirmLabel: "Одобрить"),
                             fullWidth: true) {
                    try await decide("approve", note: "")
                }
                .disabled(!docsReady)
            }
            if status == "pending" {
                Button(role: .destructive) {
                    sheet = .reject
                } label: {
                    Label("Отклонить с причиной", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if status == "blocked" {
                Button {
                    sheet = .unblock
                } label: {
                    Label("Разблокировать", systemImage: "lock.open").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if !status.isEmpty {
                Button(role: .destructive) {
                    sheet = .block
                } label: {
                    Label("Заблокировать", systemImage: "lock").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Решение")
        } footer: {
            Text(actionsFooter)
        }
    }

    private var actionsFooter: String {
        if (status == "pending" || status == "rejected") && !docsReady {
            return "Нет фото курьера или водительского удостоверения — одобрить нельзя. Отклоните заявку с причиной: курьер загрузит документы и подаст её снова."
        }
        return "Причину отказа и блокировки курьер увидит в приложении. Заблокированный курьер не получает заказы; принятые, но не забранные вызовы сразу уходят другим курьерам."
    }

    @ViewBuilder
    private func sheetView(_ s: CourierSheet) -> some View {
        switch s {
        case .reject:
            CourierReasonSheet(title: "Отклонить заявку",
                               message: "Курьер увидит причину и сможет подать заявку заново.",
                               reasons: CouriersFormat.rejectReasons,
                               submitTitle: "Отклонить") { note in
                try await decide("reject", note: note)
            }
        case .block:
            CourierReasonSheet(title: "Заблокировать курьера",
                               message: "Курьер перестанет получать заказы и увидит причину. Принятые, но не забранные вызовы уйдут другим курьерам; забранный заказ он довезёт сам.",
                               reasons: CouriersFormat.blockReasons,
                               submitTitle: "Заблокировать",
                               confirm: ConfirmAction(title: "Заблокировать " + (c["full_name"].nonEmptyString ?? "курьера") + "?",
                                                      message: "Снова допустить к заказам можно будет кнопкой «Разблокировать».",
                                                      confirmLabel: "Заблокировать", destructive: true)) { note in
                try await decide("block", note: note)
            }
        case .unblock:
            CourierReasonSheet(title: "Разблокировать курьера",
                               message: "Курьер снова сможет выходить на линию. Комментарий необязателен; прежняя причина блокировки сотрётся.",
                               placeholder: "Комментарий",
                               submitTitle: "Разблокировать", allowEmpty: true, destructive: false,
                               confirm: ConfirmAction(title: "Разблокировать курьера?", confirmLabel: "Разблокировать")) { note in
                try await decide("unblock", note: note)
            }
        case .cashLimit:
            TextInputSheet(title: "Лимит наличных",
                           message: "Сколько наличных курьер может держать на руках, ₽. Пусто — как у всех (настройка раздела на сайте).",
                           placeholder: "Например, 5000",
                           initial: c["cash_limit"].decimal.map { Fmt.decimalInput($0) } ?? "",
                           keyboard: .decimalPad, submitTitle: "Сохранить", minLength: 0) { text in
                try await saveCashLimit(text)
            }
        case .adjust:
            CourierAdjustSheet(courierName: c["full_name"].stringValue, balances: c["balances"].array) { body in
                let res = try await API.shared.post(base + "/adjust", body: body)
                await applied(res)
            }
        }
    }

    // MARK: - Запросы

    private func decide(_ action: String, note: String) async throws {
        let res: JSON
        do {
            res = try await API.shared.post(base + "/" + action, body: ["note": note])
        } catch {
            // 409 — статус уже сменил другой администратор: показываем свежую карточку.
            if let e = error as? APIError, e.status == 409 { await loader.load() }
            throw error
        }
        if res["already"].boolValue {
            let text = "Статус уже был «" + CouriersFormat.statusLabel(of: res) + "» — возможно, его сменил другой администратор."
            // Решение из листа: покажем после его закрытия (onDismiss), иначе — сразу.
            if sheet == nil { notice = text } else { pendingNotice = text }
        }
        await applied(res)
        Task { await Notifier.shared.refresh(force: true) }
    }

    /// POST /api/admin/pool/couriers/{id}/cash-limit {cash_limit: число | null}.
    private func saveCashLimit(_ text: String) async throws {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        let value: String? = cleaned.isEmpty ? nil : cleaned
        let res = try await API.shared.post(base + "/cash-limit", body: ["cash_limit": value])
        await applied(res)
    }

    /// Ответ любой ручки курьера — его карточка целиком: подставляем без лишнего запроса.
    private func applied(_ res: JSON) async {
        if res["user_id"].int == id {
            loader.data = res
        } else {
            await loader.load()
        }
        await history.load()
        onChanged?()
    }
}

// MARK: - Секции карточки

/// ФИО, статус, «на линии», дата заявки, причина последнего решения.
struct CourierHeaderSection: View {
    let c: JSON

    private var noteTitle: String {
        switch c["status"].stringValue {
        case "rejected": return "Причина отказа"
        case "blocked": return "Причина блокировки"
        default: return "Комментарий администратора"
        }
    }

    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text(c["full_name"].nonEmptyString ?? "Курьер")
                    .font(.headline)
                Spacer(minLength: 6)
                StatusBadge(status: c["status"].string, label: CouriersFormat.statusLabel(of: c))
            }
            if c["online"].boolValue {
                Label("На линии", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundColor(Brand.green)
            }
            KVRow("Заявка подана", Fmt.date(c["submitted_at"]))
            if c["reviewed_at"].nonEmptyString != nil {
                KVRow("Последнее решение", Fmt.date(c["reviewed_at"]))
            }
            if let note = c["review_note"].nonEmptyString {
                VStack(alignment: .leading, spacing: 3) {
                    Text(noteTitle)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                    Text(note)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Фото лица и водительского удостоверения (только с токеном администратора).
struct CourierDocsSection: View {
    let courierId: Int
    let c: JSON
    /// Счётчик обновлений карточки: меняется — миниатюры создаются и грузятся заново.
    let reload: Int

    @State private var viewed: CourierPhoto?

    private var base: String { "/api/admin/pool/couriers/" + String(courierId) + "/doc/" }
    private var version: String { c["submitted_at"].stringValue }

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                CourierDocThumb(path: base + "photo", version: version, title: "Фото курьера",
                                available: c["has_photo"].boolValue) { p in viewed = p }
                    .id("photo#" + version + "#" + String(reload))
                CourierDocThumb(path: base + "license", version: version, title: "Водительское удостоверение",
                                available: c["has_license"].boolValue) { p in viewed = p }
                    .id("license#" + version + "#" + String(reload))
            }
            .padding(.vertical, 4)
            .fullScreenCover(item: $viewed) { p in
                CourierPhotoViewer(photo: p)
            }
        } header: {
            Text("Документы")
        } footer: {
            Text("Нажмите на фото, чтобы открыть на весь экран и увеличить.")
        }
    }
}

/// Телефон, город, самозанятость, аккаунт сайта.
struct CourierContactsSection: View {
    let c: JSON

    private var account: JSON { c["account"] }

    var body: some View {
        Section("Контакты и аккаунт") {
            phoneRow
            KVRow("Город", c["city"].string)
            KVRow("Самозанятый", Fmt.yesNo(c["self_employed"].bool))
            if account.isObject {
                accountRow
                KVRow("E-mail", account["email"].string, copyable: true)
                KVRow("Аккаунт создан", Fmt.date(account["created_at"]))
                if account["status"].stringValue == "blocked" {
                    Text("Аккаунт пользователя на сайте заблокирован")
                        .font(.caption)
                        .foregroundColor(Brand.red)
                }
            }
        }
    }

    @ViewBuilder
    private var phoneRow: some View {
        let phone = c["phone"].string
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) {
                KVRow("Телефон", Fmt.phone(phone))
            }
        } else {
            KVRow("Телефон", Fmt.phone(phone), copyable: true)
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        let name = account["name"].nonEmptyString ?? "—"
        if let uid = account["id"].int, uid > 0 {
            NavigationLink(destination: UserDetailView(id: uid)) {
                KVRow("Пользователь", name + " · #" + String(uid))
            }
        } else {
            KVRow("Пользователь", name)
        }
    }
}

/// Машина и груз (CourierPool::courierVehicle).
struct CourierVehicleSection: View {
    let c: JSON

    private var v: JSON { c["vehicle"] }

    private var body3: String? {
        let b = v["body"]
        guard b.isObject, let l = b["l"].int, let w = b["w"].int, let h = b["h"].int else { return nil }
        return String(l) + " × " + String(w) + " × " + String(h) + " см"
    }

    private var loaders: String {
        let n = v["loaders"].intValue
        if n <= 0 { return "нет" }
        if v["loader_price"].decimal != nil { return String(n) + " по " + Fmt.money(v["loader_price"]) }
        return String(n)
    }

    private var capacity: String? {
        guard let kg = v["max_kg"].int, kg > 0 else { return nil }
        return "до " + Fmt.number(kg) + " кг"
    }

    var body: some View {
        Section("Машина") {
            KVRow("Марка", c["car_model"].string)
            KVRow("Цвет", c["car_color"].string)
            KVRow("Госномер", c["car_plate"].string, copyable: true)
            KVRow("Кузов", v["vehicle_label"].string)
            KVRow("Грузоподъёмность", capacity)
            KVRow("Размер кузова", body3)
            KVRow("Грузчики", loaders)
            KVRow("Где возит", v["service_area_label"].string)
            if v["service_area"].stringValue != "city" {
                KVRow("Межгород, цена за км", CouriersFormat.perKm(v["km_price"]))
                KVRow("Межгород, минимум", v["intercity_min"].decimal == nil ? nil : Fmt.money(v["intercity_min"]))
            }
        }
    }
}

/// Работа: доставки, отказы, рейтинг, правило «пассажиров не перевожу», согласие.
struct CourierWorkSection: View {
    let c: JSON

    var body: some View {
        Section("Работа") {
            KVRow("Доставок", Fmt.number(c["deliveries_count"].intValue))
            KVRow("Не довёз", Fmt.number(c["failed_count"].intValue))
            KVRow("Отказался после принятия", Fmt.number(c["released_count"].intValue))
            KVRow("Рейтинг", CouriersFormat.rating(c))
            KVRow("Последний раз на связи", Fmt.date(c["last_seen_at"]))
            rulesRow
            KVRow("Согласие на обработку данных", Fmt.date(c["consent_at"]))
        }
    }

    @ViewBuilder
    private var rulesRow: some View {
        if c["rules_accepted_at"].nonEmptyString != nil {
            KVRow("Правило «пассажиров не перевожу»", "подтвердил " + Fmt.date(c["rules_accepted_at"]))
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Правило «пассажиров не перевожу»")
                    .foregroundColor(Brand.muted)
                Spacer(minLength: 8)
                Text("не подтверждал")
                    .foregroundColor(Brand.red)
            }
            .font(.subheadline)
        }
    }
}

/// Деньги: долг, сальдо по заведениям, личный лимит наличных, поправка.
struct CourierMoneySection: View {
    let c: JSON
    let onCashLimit: () -> Void
    let onAdjust: () -> Void

    private var money: JSON { c["money"] }

    var body: some View {
        Section {
            KVRow("Должен заведениям", Fmt.money(money["debt"]))
            KVRow("Ему должны", Fmt.money(money["owed"]))
            if money["blocked"].boolValue, let why = money["block_reason"].nonEmptyString {
                InfoBanner(why, systemImage: "exclamationmark.octagon", color: Brand.red)
            }
            KVRow("Личный лимит наличных", c["cash_limit"].decimal == nil ? "как у всех" : Fmt.money(c["cash_limit"]))
            ForEach(c["balances"].array, id: \.stableID) { b in
                CourierBalanceRow(balance: b)
            }
            Button(action: onCashLimit) {
                Label("Изменить лимит наличных", systemImage: "banknote")
            }
            Button(action: onAdjust) {
                Label("Поправка расчёта…", systemImage: "plusminus")
            }
        } header: {
            Text("Деньги")
        } footer: {
            Text("Сальдо по заведениям: «должен» — курьер держит их деньги, «ему должны» — заведение должно курьеру. «Площадка (комиссия)» — долг курьера перед площадкой.")
        }
    }
}

/// Сальдо курьера с одним заведением.
struct CourierBalanceRow: View {
    let balance: JSON

    private var text: String {
        guard let v = balance["balance"].decimal else { return "—" }
        if v > 0 { return "должен " + Fmt.money(v) }
        if v < 0 { return "ему должны " + Fmt.money(-v) }
        return "0 ₽"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(balance["name"].nonEmptyString ?? ("Заведение #" + balance["shop_id"].stringValue))
                if balance["since"].nonEmptyString != nil {
                    Text("долг с " + Fmt.date(balance["since"]))
                        .font(.caption2)
                        .foregroundColor(Brand.muted)
                }
            }
            Spacer(minLength: 8)
            Text(text)
                .foregroundColor((balance["balance"].decimal ?? 0) > 0 ? Brand.amber : Brand.text)
        }
        .font(.subheadline)
    }
}

/// Последние доставки, проблемы и жалобы на курьера (по 30 последних с сервера).
struct CourierActivitySections: View {
    let c: JSON

    private var calls: [JSON] { Array(c["calls"].array.prefix(10)) }

    var body: some View {
        if !calls.isEmpty {
            Section("Последние доставки") {
                ForEach(calls, id: \.stableID) { call in
                    CourierCallRow(call: call)
                }
            }
        }
        if !c["problems"].array.isEmpty {
            Section("Проблемы с доставкой") {
                ForEach(c["problems"].array, id: \.stableID) { p in
                    CourierProblemLine(problem: p)
                }
            }
        }
        if !c["complaints"].array.isEmpty {
            Section("Жалобы на курьера") {
                ForEach(c["complaints"].array, id: \.stableID) { x in
                    CourierComplaintLine(complaint: x)
                }
            }
        }
    }
}

/// Одна доставка: дата, заведение, статус, цена, оценка.
struct CourierCallRow: View {
    let call: JSON

    private var line: String {
        var parts: [String] = [Fmt.date(call["created_at"])]
        parts.append(Fmt.money(call["fee"]))
        if let r = call["rating"].int { parts.append("★ " + String(r)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(call["shop"].nonEmptyString ?? "Посылка")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("№" + call["id"].stringValue)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(call["status_label"].nonEmptyString ?? call["status"].stringValue)
                .font(.caption)
            Text(line)
                .font(.caption2)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 1)
    }
}

/// Проблема с доставкой в карточке курьера.
struct CourierProblemLine: View {
    let problem: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(problem["reason_label"].nonEmptyString ?? "Проблема")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                StatusBadge(CourierIssuesFormat.problemStatus(problem["status"].string),
                            color: CourierIssuesFormat.problemColor(problem["status"].string))
            }
            Text(problem["shop"].stringValue + " · доставка №" + problem["call_id"].stringValue
                 + " · " + Fmt.money(problem["amount"]))
                .font(.caption)
                .foregroundColor(Brand.muted)
            if let t = problem["comment"].nonEmptyString {
                Text(t).font(.caption)
            }
        }
        .padding(.vertical, 1)
    }
}

/// Жалоба на курьера в его карточке.
struct CourierComplaintLine: View {
    let complaint: JSON

    private var passenger: Bool { complaint["reason"].stringValue == "passenger" }
    private var open: Bool { complaint["status"].stringValue == "open" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text((passenger ? "⚠️ " : "") + (complaint["reason_label"].nonEmptyString ?? "Жалоба"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(passenger ? Brand.red : Brand.text)
                Spacer(minLength: 6)
                StatusBadge(open ? "Открыта" : (complaint["resolution_label"].nonEmptyString ?? "Рассмотрена"),
                            color: open ? Brand.amber : Brand.green)
            }
            Text(complaint["author_label"].stringValue + " · " + Fmt.date(complaint["created_at"]))
                .font(.caption)
                .foregroundColor(Brand.muted)
            if let t = complaint["comment"].nonEmptyString {
                Text(t).font(.caption)
            }
        }
        .padding(.vertical, 1)
    }
}

/// Журнал решений по курьеру: GET /api/admin/audit?entity=pool_courier&q={user_id}&page=N
/// (routes/admin.php: 50 записей на страницу, {items, total, page, pages}).
///
/// Ручки «журнал одного курьера» на сервере нет: q ищет LIKE по имени администратора,
/// IP и тексту записи и точно — по entity_id, поэтому в выдачу попадают и чужие записи.
/// Отсекаем их по entity_id и догружаем страницы, пока не кончится журнал или не
/// просмотрим maxPages страниц.
@MainActor
final class CourierHistoryLoader: ObservableObject {
    /// Записи этого курьера (новые сверху).
    @Published private(set) var entries: [JSON] = []
    @Published private(set) var state: LoadState = .idle
    /// Сколько записей журнала просмотрено.
    @Published private(set) var scanned = 0
    /// Журнал просмотрен до конца (дальше страниц нет).
    @Published private(set) var complete = false

    let courierId: Int
    /// Не больше стольких страниц по 50 записей за одно открытие карточки.
    static let maxPages = 5
    private var generation = 0

    init(courierId: Int) {
        self.courierId = courierId
    }

    func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    func load() async {
        generation += 1
        let gen = generation
        if entries.isEmpty { state = .loading }
        var found: [JSON] = []
        var seen = 0
        var done = false
        var page = 1
        do {
            while page <= CourierHistoryLoader.maxPages {
                let res = try await API.shared.getResult("/api/admin/audit", query: [
                    "entity": "pool_courier", "q": String(courierId), "page": String(page),
                ])
                guard gen == generation else { return }
                let items = res.data["items"].array
                seen += items.count
                found += items.filter { matches($0) }
                let pages = res.data["pages"].int ?? res.meta["pages"].int ?? page
                if items.isEmpty || page >= pages {
                    done = true
                    break
                }
                page += 1
            }
            entries = found
            scanned = seen
            complete = done
            state = .loaded
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            if found.isEmpty {
                state = .failed(APIError.describe(error))
            } else {
                // Часть страниц пришла — показываем найденное, журнал считаем неполным.
                entries = found
                scanned = seen
                complete = false
                state = .loaded
            }
        }
    }

    /// Запись именно этого курьера.
    private func matches(_ e: JSON) -> Bool {
        e["entity_type"].stringValue == "pool_courier" && e["entity_id"].int == courierId
    }
}

/// История решений: журнал администраторов по курьеру (approve/reject/block/unblock/adjust,
/// с волны А92 — cash_limit) + дата заявки.
struct CourierHistorySection: View {
    let c: JSON
    @ObservedObject var history: CourierHistoryLoader

    init(c: JSON, history: CourierHistoryLoader) {
        self.c = c
        self.history = history
    }

    /// «250 записях» — для «в последних … журнала».
    private var scannedText: String {
        Fmt.plural(history.scanned, "записи", "записях", "записях")
    }

    var body: some View {
        Section {
            ForEach(history.entries, id: \.stableID) { e in
                CourierHistoryRow(entry: e)
            }
            statusLine
            KVRow("Заявка подана", Fmt.date(c["submitted_at"]))
        } header: {
            Text("История решений")
        } footer: {
            if history.state == .loaded && !history.complete && !history.entries.isEmpty {
                Text("Показаны решения из последних " + scannedText + " журнала.")
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if case .failed(let msg) = history.state {
            Text("Журнал не загрузился: " + msg)
                .font(.caption)
                .foregroundColor(Brand.muted)
        } else if history.state == .loading {
            HStack { Spacer(); ProgressView(); Spacer() }
        } else if history.entries.isEmpty && history.state == .loaded {
            Text(history.complete
                 ? "Решений по курьеру в журнале нет"
                 : "В последних " + scannedText + " журнала решений по курьеру нет")
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
    }
}

/// Запись журнала: действие, кто, когда, причина / сумма поправки.
struct CourierHistoryRow: View {
    let entry: JSON

    /// new_json хранится строкой JSON ({"note": …}, {"shop_id", "amount"} или {"cash_limit"}).
    private var details: JSON { CourierHistoryRow.parsed(entry["new_json"]) }

    /// old_json — значение до правки (у cash_limit: {"cash_limit": "1500.00" | null}).
    private var before: JSON { CourierHistoryRow.parsed(entry["old_json"]) }

    /// Поле журнала: объект или строка с JSON; иначе .null.
    static func parsed(_ v: JSON) -> JSON {
        if v.isObject { return v }
        guard let s = v.nonEmptyString, let j = JSON.parse(Data(s.utf8)) else { return .null }
        return j
    }

    /// Значение лимита наличных: сумма или «как у всех» (null — общий лимит из настроек раздела).
    static func cashLimitText(_ v: JSON) -> String {
        v.decimal == nil ? "как у всех" : Fmt.money(v)
    }

    private var detailText: String? {
        let d = details
        // Лимит наличных (волна А92, П-45 №3): «1 500 ₽ → как у всех»; без old_json — только новое.
        if entry["action"].stringValue == "cash_limit" {
            let now = CourierHistoryRow.cashLimitText(d["cash_limit"])
            guard before.isObject else { return now }
            return CourierHistoryRow.cashLimitText(before["cash_limit"]) + " → " + now
        }
        if let note = d["note"].nonEmptyString { return note }
        if let amount = d["amount"].decimal {
            let shop = d["shop_id"].intValue
            let place = shop == 0 ? "площадка" : "заведение #" + String(shop)
            return Fmt.moneySigned(amount) + " · " + place
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(CouriersFormat.auditAction(entry["action"].string))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(CouriersFormat.auditColor(entry["action"].string))
                Spacer(minLength: 6)
                Text(Fmt.date(entry["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let n = entry["name"].nonEmptyString {
                Text(n)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let t = detailText {
                Text(t)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Листы

/// Лист «причина» с частыми вариантами и (по желанию) подтверждением перед отправкой.
/// Сервер хранит до 255 символов (CourierPool::text).
struct CourierReasonSheet: View {
    let title: String
    let message: String?
    let reasons: [String]
    let placeholder: String
    let submitTitle: String
    let allowEmpty: Bool
    let destructive: Bool
    let confirm: ConfirmAction?
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var busy = false
    @State private var error: String?
    @State private var askConfirm = false

    /// Сколько символов сохраняет сервер.
    static let maxLength = 255

    /// - Parameters:
    ///   - title: заголовок листа;
    ///   - message: что произойдёт;
    ///   - reasons: частые причины (тап подставляет текст);
    ///   - placeholder: подсказка поля;
    ///   - initial: начальный текст;
    ///   - submitTitle: кнопка;
    ///   - allowEmpty: можно без текста;
    ///   - destructive: красная кнопка;
    ///   - confirm: спросить «точно?» перед отправкой (необратимое действие);
    ///   - onSubmit: отправка (бросает — текст ошибки покажется в листе).
    init(title: String, message: String? = nil, reasons: [String] = [], placeholder: String = "Причина",
         initial: String = "", submitTitle: String, allowEmpty: Bool = false, destructive: Bool = true,
         confirm: ConfirmAction? = nil, onSubmit: @escaping (String) async throws -> Void) {
        self.title = title
        self.message = message
        self.reasons = reasons
        self.placeholder = placeholder
        self.submitTitle = submitTitle
        self.allowEmpty = allowEmpty
        self.destructive = destructive
        self.confirm = confirm
        self.onSubmit = onSubmit
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !busy && (allowEmpty || !trimmed.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                if let m = message {
                    Section { Text(m).font(.subheadline).foregroundColor(Brand.muted) }
                }
                if !reasons.isEmpty {
                    Section("Частые причины") {
                        ForEach(reasons, id: \.self) { r in
                            reasonRow(r)
                        }
                    }
                }
                textSection
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section { submitButton }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
            .confirmationDialog(confirm?.title ?? "", isPresented: $askConfirm, titleVisibility: .visible) {
                if let c = confirm {
                    Button(c.confirmLabel, role: c.destructive ? .destructive : nil) { send() }
                    Button("Отмена", role: .cancel) {}
                }
            } message: {
                if let m = confirm?.message { Text(m) }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var textSection: some View {
        Section {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text(allowEmpty ? "Комментарий (необязательно)" : "Причина — её увидит курьер")
        } footer: {
            if trimmed.count > CourierReasonSheet.maxLength {
                Text("Сервер сохранит первые 255 символов").foregroundColor(Brand.amber)
            }
        }
    }

    private func reasonRow(_ r: String) -> some View {
        Button {
            Haptics.tap()
            text = r
        } label: {
            HStack {
                Text(r).foregroundColor(Brand.text)
                Spacer()
                if trimmed == r {
                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                }
            }
        }
    }

    private var submitButton: some View {
        Button(role: destructive ? .destructive : nil) {
            submitTapped()
        } label: {
            HStack {
                Spacer()
                if busy { ProgressView() } else { Text(submitTitle).bold() }
                Spacer()
            }
        }
        .disabled(!canSubmit)
    }

    private func submitTapped() {
        guard canSubmit else { return }
        if confirm != nil {
            Haptics.tap()
            askConfirm = true
        } else {
            send()
        }
    }

    private func send() {
        guard canSubmit else { return }
        busy = true
        error = nil
        let value = trimmed
        let work = onSubmit
        Task { @MainActor in
            do {
                try await work(value)
                Haptics.success()
                busy = false
                dismiss()
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
        }
    }
}

/// Заведение в листе поправки.
struct CourierShopOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// Поправка расчёта: POST /api/admin/pool/couriers/{id}/adjust
/// {kind: adjustment|platform_paid, shop_id, amount (со знаком: + курьер должен больше), note}.
/// «Комиссия получена» (platform_paid) — сервер сам пишет минус по площадке (shop_id 0).
struct CourierAdjustSheet: View {
    let courierName: String
    let shops: [CourierShopOption]
    let onSubmit: ([String: Any?]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind = "adjustment"
    @State private var shopChoice: Int
    @State private var otherShop = ""
    @State private var direction = 1
    @State private var amount = ""
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    @State private var askConfirm = false

    /// - Parameters:
    ///   - courierName: имя курьера (для подтверждения);
    ///   - balances: сальдо из карточки (заведения для выбора);
    ///   - onSubmit: отправка тела запроса.
    init(courierName: String, balances: [JSON], onSubmit: @escaping ([String: Any?]) async throws -> Void) {
        self.courierName = courierName
        var list: [CourierShopOption] = []
        for b in balances {
            guard let sid = b["shop_id"].int, sid > 0 else { continue }
            list.append(CourierShopOption(id: sid, name: b["name"].nonEmptyString ?? "Заведение #" + String(sid)))
        }
        list.append(CourierShopOption(id: 0, name: "Площадка (комиссия)"))
        self.shops = list
        self.onSubmit = onSubmit
        _shopChoice = State(initialValue: list.first?.id ?? 0)
    }

    private var amountValue: Decimal? {
        guard let d = Fmt.parseDecimal(amount), d > 0 else { return nil }
        return d
    }

    /// shop_id для запроса (nil — другое заведение без номера).
    private var shopId: Int? {
        if kind == "platform_paid" { return 0 }
        if shopChoice >= 0 { return shopChoice }
        guard let n = Int(otherShop.trimmingCharacters(in: .whitespaces)), n > 0 else { return nil }
        return n
    }

    private var noteText: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !busy && amountValue != nil && shopId != nil && !noteText.isEmpty }

    private var shopName: String {
        guard let sid = shopId else { return "—" }
        if let s = shops.first(where: { $0.id == sid }) { return s.name }
        return "заведение #" + String(sid)
    }

    private var confirmText: String {
        let sum = Fmt.money(amountValue)
        if kind == "platform_paid" {
            return courierName + " сдал комиссию площадке: " + sum + ". Долг перед площадкой уменьшится."
        }
        let verb = direction > 0 ? "Увеличить" : "Уменьшить"
        return verb + " долг курьера перед «" + shopName + "» на " + sum + "."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Что записать", selection: $kind) {
                        Text("Поправка").tag("adjustment")
                        Text("Комиссия получена").tag("platform_paid")
                    }
                    .pickerStyle(.segmented)
                }
                if kind == "adjustment" {
                    shopSection
                }
                amountSection
                Section("За что поправка") {
                    TextField("Например: вернул выручку наличными", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button {
                        askConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Записать").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("Поправка расчёта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
            .confirmationDialog("Записать поправку?", isPresented: $askConfirm, titleVisibility: .visible) {
                Button("Записать") { send() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(confirmText)
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var shopSection: some View {
        Section {
            Picker("Заведение", selection: $shopChoice) {
                ForEach(shops) { s in
                    Text(s.name).tag(s.id)
                }
                Text("Другое — указать номер").tag(-1)
            }
            if shopChoice < 0 {
                TextField("Номер заведения (ID)", text: $otherShop)
                    .keyboardType(.numberPad)
            }
            Picker("Направление", selection: $direction) {
                Text("Должен больше (+)").tag(1)
                Text("Должен меньше (−)").tag(-1)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Кому")
        } footer: {
            Text("«+» — курьер должен заведению больше, «−» — меньше (например, сдал выручку).")
        }
    }

    private var amountSection: some View {
        Section {
            TextField("Сумма, ₽", text: $amount)
                .keyboardType(.decimalPad)
        } header: {
            Text("Сумма")
        } footer: {
            if kind == "platform_paid" {
                Text("Сколько комиссии курьер передал площадке.")
            }
        }
    }

    private func send() {
        guard canSubmit, let value = amountValue, let sid = shopId else { return }
        busy = true
        error = nil
        let plain = NSDecimalNumber(decimal: value).stringValue
        let signed = (kind == "adjustment" && direction < 0) ? "-" + plain : plain
        let body: [String: Any?] = ["kind": kind, "shop_id": sid, "amount": signed, "note": noteText]
        let work = onSubmit
        Task { @MainActor in
            do {
                try await work(body)
                Haptics.success()
                busy = false
                dismiss()
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = CourierAdjustSheet.errorText(error)
                }
            }
        }
    }

    /// У /adjust нет ключа повтора: если связь оборвалась, запись могла уже сохраниться.
    static func errorText(_ error: Error) -> String {
        let lost = "Связь оборвалась — проверьте историю решений и деньги курьера, прежде чем повторять, иначе поправка может записаться дважды."
        if let e = error as? APIError, e == .offline { return lost }
        if let u = error as? URLError, u.code == .timedOut || u.code == .networkConnectionLost { return lost }
        return APIError.describe(error)
    }
}
