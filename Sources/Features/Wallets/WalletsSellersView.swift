import SwiftUI

/// Что отклоняем и через какую ручку.
struct WalletsRejectTarget: Identifiable {
    enum Mode {
        /// Ручная заявка или оборвавшаяся онлайн-заявка магазина: POST /topups/{id}/reject.
        case plain
        /// Зависшая онлайн-заявка (магазин или клиент): POST /topups/{id}/resolve action=reject.
        case resolve
    }

    let topupId: Int
    let kind: String
    let amount: Decimal?
    let who: String
    let mode: Mode
    let defaultReason: String

    var id: String { kind + "-" + String(topupId) }
}

/// Вкладка «Продавцы»: сверка, очередь ручных пополнений, онлайн-заявки, низкий баланс.
struct WalletsSellersView: View {
    @ObservedObject var loader: ObjectLoader
    let focusId: Int?

    @State private var rejectTarget: WalletsRejectTarget?
    @State private var notice: String?

    init(loader: ObjectLoader, focusId: Int?) {
        self.loader = loader
        self.focusId = focusId
    }

    private var data: JSON { loader.data }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Нет данных", retry: { await loader.load() }) {
            list
        }
        .task { await loader.loadIfNeeded() }
        .sheet(item: $rejectTarget) { t in
            rejectSheet(t)
        }
        .alert(notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private var list: some View {
        List {
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            reconcileSection
            focusSection
            pendingSection
            orphanSection
            stuckSection
            lowSection
            if loader.data.isObject {
                Section {
                    JSONInspectorView(loader.data)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    // MARK: - Действия

    private func reload() async {
        await loader.load()
        WalletsLabels.refreshInbox()
    }

    private func rejectSheet(_ t: WalletsRejectTarget) -> some View {
        let amountText = Fmt.money(t.amount)
        let num = String(t.topupId)
        let head = "Заявка №" + num + " · " + amountText
        let msg = head + " · " + t.who + ". Деньги не зачисляются, заявка закрывается."
        // 409 «оплачен в ЮKassa» и 502 «ЮKassa не ответила» → «Отклонить без проверки?» (force)
        // разбирает TopupRejectSheet (П-62, А316; /reject — А516).
        return TopupRejectSheet(title: "Отклонить заявку", message: msg, placeholder: t.defaultReason,
                                initial: t.defaultReason, submitTitle: "Отклонить") { reason, force in
            var body: [String: Any?] = ["reason": reason]
            if force { body["force"] = true }
            switch t.mode {
            case .plain:
                try await API.shared.post("/api/admin/topups/\(t.topupId)/reject", body: body)
            case .resolve:
                body["kind"] = t.kind
                body["action"] = "reject"
                try await API.shared.post("/api/admin/topups/\(t.topupId)/resolve", body: body)
            }
            notice = "Заявка №" + String(t.topupId) + " отклонена"
            await reload()
        }
    }

    // MARK: - Сверка

    @ViewBuilder
    private var reconcileSection: some View {
        let rec = data["reconcile"]
        Section {
            if !rec.isObject {
                InfoBanner("Сверка кошельков ещё ни разу не выполнялась. Если так и останется — проверьте, что настроен crontab.",
                           systemImage: "exclamationmark.triangle", color: Brand.amber)
            } else if rec["bad"].intValue > 0 {
                WalletsReconcileBad(rec: rec)
            } else {
                InfoBanner(WalletsSellersView.reconcileOkText(rec), systemImage: "checkmark.seal", color: Brand.green)
            }
        } header: {
            Text("Ночная сверка кошельков")
        }
    }

    static func reconcileOkText(_ rec: JSON) -> String {
        var s = "Сверка от " + Fmt.date(rec["at"]) + ": расхождений нет."
        if let r = rec["round_at"].nonEmptyString {
            s += " Полный круг пройден " + Fmt.date(r) + "."
        } else {
            s += " Полный круг ещё не пройден."
        }
        if rec["stale"].boolValue {
            s += " Сверка выполнялась давно — проверьте crontab."
        }
        return s
    }

    // MARK: - Открытая по ссылке заявка

    @ViewBuilder
    private var focusSection: some View {
        if let fid = focusId, loader.state == .loaded {
            Section {
                if let p = data["pending"].array.first(where: { $0.id == fid }) {
                    pendingRow(p)
                } else if let o = data["orphan_online"].array.first(where: { $0.id == fid }) {
                    orphanRow(o)
                } else if let s = data["stuck_online"].array.first(where: { $0.id == fid && $0["kind"].string == "shop" }) {
                    stuckRow(s)
                } else {
                    InfoBanner("Заявка №" + String(fid) + " не ждёт разбора: уже обработана или не найдена.")
                }
            } header: {
                Text("Заявка №" + String(fid))
            }
        }
    }

    // MARK: - Ручные заявки

    @ViewBuilder
    private var pendingSection: some View {
        let items = data["pending"].array
        Section {
            if items.isEmpty {
                Text("Нет заявок").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.stableID) { t in
                    pendingRow(t)
                }
            }
        } header: {
            Text("Ожидают подтверждения (" + String(items.count) + ")")
        } footer: {
            Text("Переводы по реквизитам и наличные. Подтверждайте, только когда деньги поступили на счёт.")
        }
    }

    private func pendingRow(_ t: JSON) -> some View {
        WalletsPendingRow(item: t, onReject: {
            rejectTarget = WalletsRejectTarget(topupId: t.id ?? 0, kind: "shop", amount: t["amount"].decimal,
                                               who: "магазин «" + t["shop"].stringValue + "»", mode: .plain,
                                               defaultReason: "")
        }, onConfirmed: { text in
            notice = text
            await reload()
        })
    }

    // MARK: - Оборвавшиеся онлайн-заявки

    @ViewBuilder
    private var orphanSection: some View {
        let items = data["orphan_online"].array
        Section {
            if items.isEmpty {
                Text("Таких заявок нет").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.stableID) { t in
                    orphanRow(t)
                }
            }
        } header: {
            Text("Оборвавшиеся онлайн-заявки (" + String(items.count) + ")")
        } footer: {
            Text("Оплата картой или СБП, по которой не записалась ссылка на платёж. Подтверждать вручную НЕЛЬЗЯ: деньги могли не прийти. Найдите платёж в кабинете ЮKassa по номеру заявки (metadata.topup_id) и отклоните заявку, если оплаты не было.")
        }
    }

    private func orphanRow(_ t: JSON) -> some View {
        WalletsOrphanRow(item: t) {
            rejectTarget = WalletsRejectTarget(topupId: t.id ?? 0, kind: "shop", amount: t["amount"].decimal,
                                               who: "магазин «" + t["shop"].stringValue + "»", mode: .plain,
                                               defaultReason: "Платёж не найден")
        }
    }

    // MARK: - Зависшие онлайн-пополнения

    @ViewBuilder
    private var stuckSection: some View {
        let items = data["stuck_online"].array
        Section {
            if items.isEmpty {
                Text("Таких заявок нет").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.self) { t in
                    stuckRow(t)
                }
            }
        } header: {
            Text("Зависшие онлайн-пополнения (" + String(items.count) + ")")
        } footer: {
            Text("Платёж есть, а заявка висит «в ожидании» — обычно оплаченная сумма или валюта не совпали с заявкой. «Проверить» спросит ЮKassa. Если оплачено в рублях — можно зачислить РОВНО оплаченное. Если не оплачено — отклоните.")
        }
    }

    private func stuckRow(_ t: JSON) -> some View {
        let kind = t["kind"].string == "user" ? "user" : "shop"
        let whoKind = kind == "user" ? "клиент" : "магазин"
        let who = t["who"].stringValue + " (" + whoKind + ")"
        return WalletsStuckRow(item: t, onReject: {
            rejectTarget = WalletsRejectTarget(topupId: t.id ?? 0, kind: kind, amount: t["amount"].decimal,
                                               who: who, mode: .resolve, defaultReason: "Платёж не подтверждён")
        }, onCredited: { text in
            notice = text
            await reload()
        })
        .id(kind + String(t.id ?? 0))
    }

    // MARK: - Низкий баланс

    @ViewBuilder
    private var lowSection: some View {
        let items = data["low_balance"].array
        Section {
            if items.isEmpty {
                Text("Все балансы в норме").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.stableID) { s in
                    NavigationLink(destination: ShopDetailView(id: s.id ?? 0)) {
                        HStack {
                            Text(s["name"].stringValue)
                            Spacer()
                            MoneyText(s["balance"])
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        } header: {
            Text("Низкий / отрицательный баланс (" + String(items.count) + ")")
        } footer: {
            Text("Порог — «Порог низкого баланса» в настройках площадки.")
        }
    }
}

/// Красная плашка: сверка нашла расхождения.
struct WalletsReconcileBad: View {
    let rec: JSON

    init(rec: JSON) { self.rec = rec }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Расхождений: " + String(rec["bad"].intValue), systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundColor(Brand.red)
            Text("Проверено " + Fmt.date(rec["at"]) + ". Баланс не сходится с журналом движений — деньги считаются по журналу, разбирать нужно руками.")
                .font(.footnote)
            if let list = rec["list"].nonEmptyString {
                Text(list)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if rec["stale"].boolValue {
                Text("Сверка выполнялась давно — проверьте crontab.")
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Ручная заявка магазина: подтвердить (зачислить) или отклонить.
struct WalletsPendingRow: View {
    let item: JSON
    let onReject: () -> Void
    let onConfirmed: (String) async -> Void

    init(item: JSON, onReject: @escaping () -> Void, onConfirmed: @escaping (String) async -> Void) {
        self.item = item
        self.onReject = onReject
        self.onConfirmed = onConfirmed
    }

    private var idText: String { "№" + String(item.id ?? 0) }
    private var shop: String { item["shop"].stringValue }
    private var amount: Decimal? { item["amount"].decimal }

    private var confirm: ConfirmAction {
        let title = "Зачислить " + Fmt.money(amount) + " магазину «" + shop + "»?"
        let msg = "Заявка " + idText + ", " + WalletsLabels.method(item["method"].string)
            + ". Убедитесь, что деньги поступили на счёт."
        return ConfirmAction(title: title, message: msg, confirmLabel: "Зачислить " + Fmt.money(amount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(idText).font(.caption).foregroundColor(Brand.muted)
                Text(shop).font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(item["amount"]).font(.headline)
            }
            Text(WalletsLabels.method(item["method"].string) + " · " + Fmt.date(item["created_at"]))
                .font(.caption)
                .foregroundColor(Brand.muted)
            receipt
            HStack(spacing: 10) {
                if amount != nil {
                    ActionButton("Подтвердить", systemImage: "checkmark", style: .prominent, confirm: confirm) {
                        let id = item.id ?? 0
                        try await API.shared.post("/api/admin/topups/\(id)/confirm")
                        await onConfirmed("Подтверждено: " + Fmt.money(amount) + " зачислено магазину «" + shop + "»")
                    }
                } else {
                    Text("Сумма не распознана — подтвердите на сайте")
                        .font(.caption)
                        .foregroundColor(Brand.red)
                }
                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Отклонить", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var receipt: some View {
        if let path = item["receipt_file"].nonEmptyString, let url = API.absoluteURL(path) {
            Link(destination: url) {
                Label("Квитанция", systemImage: "doc.text")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}

/// Оборвавшаяся онлайн-заявка магазина (без ссылки на платёж).
struct WalletsOrphanRow: View {
    let item: JSON
    let onReject: () -> Void

    init(item: JSON, onReject: @escaping () -> Void) {
        self.item = item
        self.onReject = onReject
    }

    private var closedByCron: Bool { item["status"].string == "rejected" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("№" + String(item.id ?? 0)).font(.caption).foregroundColor(Brand.muted)
                Text(item["shop"].stringValue).font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(item["amount"]).font(.headline)
            }
            HStack(spacing: 8) {
                if closedByCron {
                    StatusBadge("закрыта кроном", color: Brand.muted)
                } else {
                    StatusBadge("ждёт разбора", color: Brand.amber)
                }
                Text(WalletsLabels.method(item["method"].string) + " · " + Fmt.date(item["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if !closedByCron {
                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Отклонить", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Зависшая онлайн-заявка: проверить платёж в ЮKassa, зачислить оплаченное или отклонить.
///
/// «Отклонить» (resolve action=reject) ЮKassa не спрашивает, а отклонённая оплаченная
/// заявка зачислится разве что по позднему уведомлению ЮKassa. Поэтому без свежей проверки
/// (не старше 2 мин) — предупреждение «Платёж мог пройти — сначала „Проверить в ЮKassa“»;
/// проверка показала оплату или waiting_for_capture (деньги заблокированы у плательщика) —
/// отдельное подтверждение.
struct WalletsStuckRow: View {
    let item: JSON
    let onReject: () -> Void
    let onCredited: (String) async -> Void

    @State private var check: JSON?
    @State private var checkError: String?
    @State private var askCheckFirst = false
    @State private var askRejectPaid = false
    @State private var checkingBeforeReject = false
    @State private var askRejectHeld = false
    /// Когда ЮKassa ответила на проверку: ответ старше 2 мин не доверяем.
    @State private var checkedAt: Date?

    /// Сколько секунд доверяем ответу проверки.
    static let checkTTL: TimeInterval = 120

    init(item: JSON, onReject: @escaping () -> Void, onCredited: @escaping (String) async -> Void) {
        self.item = item
        self.onReject = onReject
        self.onCredited = onCredited
    }

    private var kind: String { item["kind"].string == "user" ? "user" : "shop" }
    private var who: String { item["who"].stringValue }
    private var kindLabel: String { kind == "user" ? "клиент" : "магазин" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("№" + String(item.id ?? 0)).font(.caption).foregroundColor(Brand.muted)
                Text(who).font(.subheadline.weight(.semibold))
                Text("(" + kindLabel + ")").font(.caption).foregroundColor(Brand.muted)
                Spacer()
                MoneyText(item["amount"]).font(.headline)
            }
            Text("В заявке · " + WalletsLabels.method(item["method"].string) + " · " + Fmt.date(item["created_at"]))
                .font(.caption)
                .foregroundColor(Brand.muted)
            Text("Платёж: " + item["payment_ref"].stringValue)
                .font(.caption.monospaced())
                .foregroundColor(Brand.muted)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                ActionButton("Проверить", systemImage: "magnifyingglass", style: .bordered) {
                    await runCheck()
                }
                Button(role: .destructive) {
                    rejectTapped()
                } label: {
                    if checkingBeforeReject {
                        ProgressView()
                    } else {
                        Label("Отклонить", systemImage: "xmark")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(checkingBeforeReject)
            }
            if let e = checkError {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
            if let c = check {
                checkResult(c)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Платёж мог пройти", isPresented: $askCheckFirst, titleVisibility: .visible) {
            Button("Проверить в ЮKassa") { checkThenReject() }
            Button("Отклонить без проверки", role: .destructive) { onReject() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сначала нажмите «Проверить в ЮKassa». Если платёж прошёл, а заявку отклонить, человек увидит отказ; зачислится она, только если позже сработает уведомление ЮKassa, а при несовпадении суммы или валюты — только вручную.")
        }
        .confirmationDialog("ЮKassa: платёж ждёт подтверждения", isPresented: $askRejectHeld, titleVisibility: .visible) {
            Button("Всё равно отклонить", role: .destructive) { onReject() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Статус waiting_for_capture: деньги плательщика уже заблокированы и ждут подтверждения в кабинете ЮKassa. Отклонив заявку, не забудьте отменить платёж в ЮKassa — иначе деньги так и останутся заблокированы.")
        }
        .confirmationDialog("ЮKassa: платёж оплачен", isPresented: $askRejectPaid, titleVisibility: .visible) {
            Button("Всё равно отклонить", role: .destructive) { onReject() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Деньги получены. Обычно оплаченную заявку зачисляют кнопкой «Зачислить», а не отклоняют.")
        }
    }

    /// Оплачен ли платёж по ответу проверки (как в checkResult).
    private static func isPaid(_ c: JSON) -> Bool {
        let currency = c["currency"].stringValue.uppercased()
        let paid = c["paid"].decimal ?? 0
        let refunded = c["refunded"].decimal ?? 0
        return c["status"].string == "succeeded" && currency == "RUB" && paid > 0 && refunded + Decimal(1) / Decimal(100) < paid
    }

    /// Свежий ли ответ проверки (не старше checkTTL).
    private var checkFresh: Bool {
        guard let t = checkedAt else { return false }
        return Date().timeIntervalSince(t) < WalletsStuckRow.checkTTL
    }

    /// «Отклонить»: без свежей проверки — предупреждение; проверка показала оплату или
    /// удержание (waiting_for_capture) — подтверждение.
    private func rejectTapped() {
        guard let c = check, checkFresh else {
            Haptics.warning()
            askCheckFirst = true
            return
        }
        if c["status"].string == "waiting_for_capture" {
            Haptics.warning()
            askRejectHeld = true
        } else if WalletsStuckRow.isPaid(c) {
            Haptics.warning()
            askRejectPaid = true
        } else {
            onReject()
        }
    }

    /// Проверить платёж; не оплачен — отклонить, оплачен — показать результат (с «Зачислить»).
    private func checkThenReject() {
        guard !checkingBeforeReject else { return }
        checkingBeforeReject = true
        Task { @MainActor in
            await runCheck()
            checkingBeforeReject = false
            guard let c = check, checkFresh else { return }   // не вышло — текст ошибки уже под строкой
            if c["status"].string == "waiting_for_capture" {
                askRejectHeld = true
            } else if WalletsStuckRow.isPaid(c) {
                askRejectPaid = true
            } else {
                onReject()
            }
        }
    }

    private func runCheck() async {
        let id = item.id ?? 0
        let k = kind
        do {
            let r = try await API.shared.get("/api/admin/topups/\(id)/payment", query: ["kind": k])
            check = r
            checkedAt = Date()
            checkError = nil
        } catch {
            if !APIError.isCancellation(error) {
                check = nil
                checkError = APIError.describe(error)
            }
        }
    }

    /// Сумма в валюте платежа: рубли — «1 000 ₽», иначе «400.00 KZT».
    private static func amount(_ v: JSON, currency: String) -> String {
        if currency == "RUB" { return Fmt.money(v) }
        let n = v.decimal.map { Fmt.decimalInput($0) } ?? "—"
        return n + " " + currency
    }

    @ViewBuilder
    private func checkResult(_ c: JSON) -> some View {
        let currency = c["currency"].stringValue.uppercased()
        let paid = c["paid"].decimal ?? 0
        let refunded = c["refunded"].decimal ?? 0
        // Сервер (resolve credit_actual) зачисляет и при ЧАСТИЧНОМ возврате — остаток
        // «оплачено − возвращено»; отказ только при возврате целиком.
        let net = refunded > 0 ? paid - refunded : paid
        let ok = WalletsStuckRow.isPaid(c)
        let paidText = WalletsStuckRow.amount(c["paid"], currency: currency)
        let statusText = WalletsLabels.yooStatus(c["status"].string)
        VStack(alignment: .leading, spacing: 6) {
            Text("ЮKassa: " + statusText + ", оплачено " + paidText)
                .font(.footnote.weight(.semibold))
            if refunded > 0 {
                Text("Возвращено " + WalletsStuckRow.amount(c["refunded"], currency: currency))
                    .font(.footnote)
                    .foregroundColor(Brand.red)
            }
            if !c["matches"].boolValue {
                Text("Не совпадает с заявкой: в заявке " + Fmt.money(c["requested"]))
                    .font(.footnote)
                    .foregroundColor(Brand.amber)
            }
            if ok {
                creditButton(paid: net, requested: c["requested"].decimal, partial: refunded > 0)
            } else {
                Text(WalletsStuckRow.whyNot(status: c["status"].string, currency: currency, paid: paid, refunded: refunded))
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(8)
        .background(Brand.chip.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    static func whyNot(status: String?, currency: String, paid: Decimal, refunded: Decimal) -> String {
        if status == "waiting_for_capture" {
            return "Зачислять нельзя: платёж ждёт подтверждения в кабинете ЮKassa (деньги заблокированы у плательщика)."
        }
        if status != "succeeded" { return "Зачислять нельзя: платёж не оплачен." }
        if currency != "RUB" { return "Зачислять нельзя: платёж не в рублях — верните деньги в кабинете ЮKassa." }
        if paid <= 0 { return "Зачислять нельзя: в платеже нулевая сумма." }
        if refunded > 0 { return "Зачислять нечего: платёж возвращён целиком." }
        return "Зачислять нельзя."
    }

    /// `paid` — что будет зачислено (при частичном возврате — остаток после возврата).
    private func creditButton(paid: Decimal, requested: Decimal?, partial: Bool) -> some View {
        let paidText = Fmt.money(paid)
        let requestedText = Fmt.money(requested)
        let title = "Зачислить " + paidText + "?"
        let whoText = "Получатель: " + who + " (" + kindLabel + ")."
        let tail = partial ? ". Часть платежа возвращена — зачисляется остаток." : ". Зачисляется ровно оплаченная сумма."
        let msg = whoText + " В заявке было " + requestedText + tail
        let confirm = ConfirmAction(title: title, message: msg, confirmLabel: "Зачислить " + paidText)
        return ActionButton("Зачислить " + paidText, systemImage: "arrow.down.circle", style: .prominent,
                            confirm: confirm) {
            let id = item.id ?? 0
            let r = try await API.shared.post("/api/admin/topups/\(id)/resolve",
                                              body: ["kind": kind, "action": "credit_actual"])
            // При частичном возврате сервер в amount отдаёт оплаченное ДО возврата,
            // а зачисляет остаток — показываем остаток.
            let credited = partial ? paid : (r["amount"].decimal ?? paid)
            var text = "Зачислено " + Fmt.money(credited)
            if let bal = r["balance"].decimal {
                text += ". Баланс: " + Fmt.money(bal)
            }
            await onCredited(text)
        }
    }
}
