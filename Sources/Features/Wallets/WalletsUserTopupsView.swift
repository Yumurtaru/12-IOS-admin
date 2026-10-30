import SwiftUI

/// Вкладка «Пополнения»: пополнения кошельков клиентов (GET /api/admin/user-topups?status=).
/// Сервер отдаёт до 200 последних без страниц.
struct WalletsUserTopupsView: View {
    @ObservedObject var model: PagedListModel

    @State private var notice: String?
    @State private var walletUser: Int?

    init(model: PagedListModel) {
        self.model = model
    }

    private static let statuses: [PickerOption] = [
        PickerOption(value: "pending", label: "Ожидают"),
        PickerOption(value: "confirmed", label: "Зачислено"),
        PickerOption(value: "rejected", label: "Не оплачено"),
        PickerOption(value: "all", label: "Все"),
    ]

    private var status: Binding<String> {
        Binding(get: { model.filter("status") ?? "pending" },
                set: { model.setFilter("status", $0) })
    }

    private var walletShown: Binding<Bool> {
        Binding(get: { walletUser != nil }, set: { if !$0 { walletUser = nil } })
    }

    var body: some View {
        List {
            Section {
                Picker("Статус", selection: status) {
                    ForEach(WalletsUserTopupsView.statuses) { o in
                        Text(o.label).tag(o.value)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Если человек заплатил, а деньги не пришли на кошелёк (уведомление от ЮKassa не дошло), нажмите «Проверить» — сервер спросит ЮKassa и зачислит, если платёж прошёл. Дважды зачислить нельзя.")
            }
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            rows
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
        .navigationDestination(isPresented: walletShown) {
            WalletsUserWalletView(userId: walletUser ?? 0)
        }
        .alert(notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    @ViewBuilder
    private var rows: some View {
        switch model.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 30)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.reload() })
                .frame(minHeight: 220)
        case .empty:
            EmptyStateView(title: "Ничего нет", systemImage: "checkmark.circle")
                .frame(minHeight: 220)
        case .loaded:
            Section {
                ForEach(model.items, id: \.stableID) { t in
                    WalletsUserTopupRow(item: t, clientName: t["user_name"].stringValue, showClient: true,
                                        onNotice: { notice = $0 },
                                        onDone: {
                                            await model.refresh()
                                            WalletsLabels.refreshInbox()
                                        },
                                        onOpenWallet: { walletUser = t["user_id"].int })
                }
            } footer: {
                if model.items.count >= 200 {
                    Text("Показаны 200 последних.")
                }
            }
        }
    }
}

/// Пополнение кошелька клиента: данные + «Проверить» / «Закрыть» для ожидающих.
///
/// У заявки с платежом (payment_id) «Закрыть» сначала предлагает проверить платёж в
/// ЮKassa (POST …/recheck — сервер спросит ЮKassa и зачислит оплаченное). Закрытую, но
/// оплаченную заявку Wallet::creditTopup зачислит только по уведомлению ЮKassa или
/// «Проверить» (Wallet.php: «оплачена отменённая заявка — зачисляем»), а уведомление как
/// раз не дошло: человек увидит «не оплачено» и может заплатить второй раз.
/// Закрыть без проверки можно — после предупреждения.
struct WalletsUserTopupRow: View {
    let item: JSON
    let clientName: String
    let showClient: Bool
    let onNotice: (String) -> Void
    let onDone: () async -> Void
    let onOpenWallet: (() -> Void)?

    @State private var askClose = false
    /// Предупреждение перед «Закрыть» у заявки с платежом, ещё не проверенной в ЮKassa.
    @State private var askCheckFirst = false
    /// Идёт проверка из предупреждения.
    @State private var checkingBeforeClose = false
    /// В этом окне проверка уже была: ЮKassa оплату не подтвердила (заявка осталась pending).
    @State private var checkedNotPaid = false
    /// Что сказала ЮKassa при последней проверке (строка recheck: yookassa_status /
    /// yookassa_unavailable); nil — сервер этих полей не прислал.
    @State private var lastYooLine: String?

    init(item: JSON, clientName: String, showClient: Bool, onNotice: @escaping (String) -> Void,
         onDone: @escaping () async -> Void, onOpenWallet: (() -> Void)? = nil) {
        self.item = item
        self.clientName = clientName
        self.showClient = showClient
        self.onNotice = onNotice
        self.onDone = onDone
        self.onOpenWallet = onOpenWallet
    }

    private var status: String { item["status"].stringValue }
    private var isPending: Bool { status == "pending" }
    private var paymentId: String { item["payment_id"].stringValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                if showClient {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(clientName.isEmpty ? "Клиент #" + String(item["user_id"].intValue) : clientName)
                            .font(.subheadline.weight(.semibold))
                        Text(Fmt.phone(item["user_phone"].string))
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                    }
                } else {
                    Text("№" + String(item.id ?? 0)).font(.caption).foregroundColor(Brand.muted)
                }
                Spacer()
                MoneyText(item["amount"]).font(.headline)
            }
            HStack(spacing: 6) {
                StatusBadge(WalletsLabels.userTopupStatus(status), color: StatusBadge.tone(for: status))
                if item["stale"].boolValue {
                    StatusBadge("висит сутки", color: Brand.amber)
                }
                Text(Fmt.date(item["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let m = item["method"].nonEmptyString {
                Text(WalletsLabels.method(m)).font(.caption).foregroundColor(Brand.muted)
            }
            if !paymentId.isEmpty {
                Text("Платёж: " + paymentId)
                    .font(.caption.monospaced())
                    .foregroundColor(Brand.muted)
                    .textSelection(.enabled)
            }
            if let note = item["error_note"].nonEmptyString {
                Text(note).font(.caption).foregroundColor(Brand.red)
            }
            buttons
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $askClose) {
            closeSheet
        }
        .confirmationDialog("Платёж мог пройти", isPresented: $askCheckFirst, titleVisibility: .visible) {
            Button("Проверить в ЮKassa") { checkThenClose() }
            Button("Закрыть без проверки", role: .destructive) { askClose = true }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сначала нажмите «Проверить в ЮKassa»: если человек оплатил, а уведомление не дошло, сервер зачислит деньги. Закрытую оплаченную заявку сервер зачислит, только если уведомление ЮKassa всё-таки придёт или нажать «Проверить», — а до тех пор клиент видит «не оплачено» и может заплатить ещё раз.")
        }
    }

    /// «Закрыть»: у заявки с платежом, не проверенной в ЮKassa, — сначала предупреждение.
    private func closeTapped() {
        if !paymentId.isEmpty && !checkedNotPaid {
            Haptics.warning()
            askCheckFirst = true
        } else {
            askClose = true
        }
    }

    /// Проверить в ЮKassa; оплата не подтверждена — открыть закрытие, оплачен — сообщить о зачислении.
    private func checkThenClose() {
        guard !checkingBeforeClose else { return }
        checkingBeforeClose = true
        Task { @MainActor in
            defer { checkingBeforeClose = false }
            let id = item.id ?? 0
            do {
                let r = try await API.shared.post("/api/admin/user-topups/\(id)/recheck")
                let st = r["status"].stringValue
                let yoo = r["yookassa_status"].string
                lastYooLine = TopupReject.recheckLine(r)
                if st == "confirmed" {
                    onNotice("Платёж прошёл, зачислено. Баланс клиента: " + Fmt.money(r["balance"]))
                    await onDone()
                } else if st == "pending" && (yoo == "succeeded" || yoo == "waiting_for_capture") {
                    // Деньги у ЮKassa есть, а заявка не зачислилась — закрывать нельзя.
                    onNotice(WalletsUserTopupRow.pendingText(r))
                    await onDone()
                } else if st == "pending" && r["yookassa_unavailable"].bool == true {
                    onNotice(WalletsUserTopupRow.pendingText(r) + " Закрывать заявку без проверки не стоит — платёж мог пройти.")
                } else if st == "pending" {
                    checkedNotPaid = true
                    askClose = true
                } else {
                    // rejected / иное: заявка уже не ожидает — показать и обновить список.
                    onNotice("Заявка уже не ожидает оплаты: " + WalletsLabels.userTopupStatus(st) + ".")
                    await onDone()
                }
            } catch {
                if !APIError.isCancellation(error) {
                    onNotice("Проверить в ЮKassa не удалось: " + APIError.describe(error) + ". Закрывать заявку без проверки не стоит — платёж мог пройти.")
                }
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if isPending || onOpenWallet != nil {
            HStack(spacing: 10) {
                if isPending {
                    if !paymentId.isEmpty {
                        ActionButton("Проверить", systemImage: "arrow.triangle.2.circlepath", style: .bordered) {
                            try await recheck()
                        }
                    }
                    Button(role: .destructive) {
                        closeTapped()
                    } label: {
                        if checkingBeforeClose {
                            ProgressView()
                        } else {
                            Label("Закрыть", systemImage: "xmark")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(checkingBeforeClose)
                }
                if let open = onOpenWallet {
                    Button {
                        open()
                    } label: {
                        Label("Кошелёк", systemImage: "wallet.pass")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func recheck() async throws {
        let id = item.id ?? 0
        let r = try await API.shared.post("/api/admin/user-topups/\(id)/recheck")
        let st = r["status"].stringValue
        lastYooLine = TopupReject.recheckLine(r)
        if st == "confirmed" {
            onNotice("Платёж прошёл, зачислено. Баланс клиента: " + Fmt.money(r["balance"]))
        } else {
            if st == "pending" {
                let yoo = r["yookassa_status"].string
                let blocked = yoo == "succeeded" || yoo == "waiting_for_capture" || r["yookassa_unavailable"].bool == true
                checkedNotPaid = !blocked
                onNotice(WalletsUserTopupRow.pendingText(r))
            } else {
                onNotice("Заявка уже не ожидает оплаты: " + WalletsLabels.userTopupStatus(st) + ".")
            }
        }
        await onDone()
    }

    /// Заявка осталась «в ожидании» после recheck — что честно сказать по статусу ЮKassa.
    static func pendingText(_ r: JSON) -> String {
        if r["yookassa_unavailable"].bool == true {
            return "ЮKassa не ответила — статус платежа неизвестен. Повторите проверку позже."
        }
        switch r["yookassa_status"].string ?? "" {
        case "succeeded":
            return "Платёж в ЮKassa оплачен, но не зачислен (сумма или валюта не совпали с заявкой). Закрывать нельзя — разберите его в «Продавцы» → «Зависшие онлайн-пополнения»."
        case "waiting_for_capture":
            return "Платёж в ЮKassa ждёт списания — деньги у клиента заблокированы. Закрывать нельзя: подтвердите или отмените платёж в кабинете ЮKassa."
        case "pending":
            return "Статус в ЮKassa: ожидает оплаты — клиент ещё не заплатил."
        case "canceled":
            return "Статус в ЮKassa: отменён — оплаты не было, заявку можно закрыть."
        case "":
            return "ЮKassa не подтвердила оплату (платёж может быть в процессе или ЮKassa недоступна)."
        case let other:
            return "Статус в ЮKassa: " + WalletsLabels.yooStatus(other) + ". Оплата не подтверждена."
        }
    }

    private var closeSheet: some View {
        let who = clientName.isEmpty ? "клиент" : "клиент «" + clientName + "»"
        // Части отдельно: длинная цепочка «+» с ?? и перегруженными функциями
        // заметно грузит проверку типов Xcode.
        let num = String(item.id ?? 0)
        let sum = Fmt.money(item["amount"])
        let head = "Пополнение №" + num + " · " + sum
        var msg = head + " · " + who + ". Закрыть как неоплаченное — деньги не зачисляются."
        if !paymentId.isEmpty {
            if checkedNotPaid {
                msg += " Только что проверили: " + (lastYooLine ?? "ЮKassa не подтвердила оплату (платёж может быть в процессе или ЮKassa недоступна).")
            } else {
                msg += " Платёж в ЮKassa не проверен — если он прошёл, клиент увидит «не оплачено» и может заплатить ещё раз."
            }
        }
        // Сервер сам спрашивает ЮKassa (П-62, А316): «оплачен» — 409, «не ответила» — 502
        // need=force → «Отклонить без проверки?» — это разбирает TopupRejectSheet.
        return TopupRejectSheet(title: "Закрыть заявку", message: msg, placeholder: "Закрыто администратором",
                                submitTitle: "Закрыть как неоплаченную") { reason, force in
            let id = item.id ?? 0
            var body: [String: Any?] = ["reason": reason]
            if force { body["force"] = true }
            try await API.shared.post("/api/admin/user-topups/\(id)/reject", body: body)
            onNotice("Заявка закрыта")
            await onDone()
        }
    }
}
