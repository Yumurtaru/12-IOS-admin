import SwiftUI

/// Вкладка «Клиенты»: кошельки клиентов с операциями (GET /api/admin/user-wallets).
struct WalletsClientsView: View {
    @ObservedObject var model: PagedListModel

    init(model: PagedListModel) {
        self.model = model
    }

    var body: some View {
        List {
            summary
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(Brand.muted)
                    TextField("Имя, телефон, почта", text: $model.searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !model.searchText.isEmpty {
                        Button {
                            model.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Brand.muted)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            rowsSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var summary: some View {
        let d = model.lastData
        if d.isObject {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    WalletsMetric("На кошельках клиентов", value: Fmt.money(d["held"]),
                                  note: "деньги людей, обязательство площадки")
                    WalletsMetric("Заработано на объявлениях", value: Fmt.money(d["ads_earned"]),
                                  note: "за всё время")
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var rowsSection: some View {
        switch model.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 30)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.reload() })
                .frame(minHeight: 220)
        case .empty:
            EmptyStateView(title: "Кошельков с операциями нет", systemImage: "wallet.pass")
                .frame(minHeight: 220)
        case .loaded:
            Section {
                ForEach(model.items, id: \.stableID) { u in
                    NavigationLink(destination: WalletsUserWalletView(userId: u.id ?? 0, onChanged: {
                        await model.refresh()
                    })) {
                        WalletsClientRow(item: u)
                    }
                    .task { await model.loadMoreIfNeeded(current: u) }
                }
                ListFooter(model: model)
            }
        }
    }
}

/// Строка кошелька клиента.
struct WalletsClientRow: View {
    let item: JSON

    init(item: JSON) { self.item = item }

    private var stats: String {
        let credited = "пополнено " + Fmt.money(item["credited"])
        let spent = "потрачено " + Fmt.money(item["spent"])
        let ops = Fmt.plural(item["tx_count"].intValue, "операция", "операции", "операций")
        return credited + " · " + spent + " · " + ops
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["name"].nonEmptyString ?? "Без имени").font(.subheadline.weight(.semibold))
                Spacer()
                MoneyText(item["balance"]).font(.headline)
            }
            Text(Fmt.phone(item["phone"].string))
                .font(.caption)
                .foregroundColor(Brand.muted)
            Text(stats)
                .font(.caption2)
                .foregroundColor(Brand.muted)
            if let last = item["last_at"].nonEmptyString {
                Text("Последняя операция: " + Fmt.date(last))
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Кошелёк одного клиента: баланс, пополнения, журнал, корректировка.
struct WalletsUserWalletView: View {
    let userId: Int
    let onChanged: (() async -> Void)?

    @StateObject private var loader: ObjectLoader
    @State private var showCorrect = false
    @State private var notice: String?

    init(userId: Int, onChanged: (() async -> Void)? = nil) {
        self.userId = userId
        self.onChanged = onChanged
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/user-wallets/\(userId)"))
    }

    private var user: JSON { loader.data["user"] }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            List {
                if let e = loader.lastRefreshError {
                    ErrorBanner(message: e, retry: { Task { await loader.load() } })
                        .listRowSeparator(.hidden)
                }
                headerSection
                topupsSection
                txSection
                Section {
                    JSONInspectorView(loader.data)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loader.load() }
        }
        .navigationTitle(user["name"].nonEmptyString ?? "Кошелёк")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
        .sheet(isPresented: $showCorrect) {
            WalletsCorrectSheet(userId: userId, userName: user["name"].stringValue,
                                balance: user["balance"].decimal) { text in
                // Пустой текст — только обновить (лист закрыли при неизвестном исходе).
                if !text.isEmpty { notice = text }
                await afterChange()
            }
        }
        .alert(notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private func afterChange() async {
        await loader.load()
        if let cb = onChanged { await cb() }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Баланс").font(.caption).foregroundColor(Brand.muted)
                MoneyText(user["balance"]).font(.largeTitle.weight(.bold))
            }
            .padding(.vertical, 4)
            KVRow("Телефон", Fmt.phone(user["phone"].string), copyable: true)
            if let email = user["email"].nonEmptyString {
                KVRow("Почта", email, copyable: true)
            }
            KVRow("Статус", Fmt.statusLabel(user["status"].string))
            KVRow("Клиент с", Fmt.date(user["since"]))
            Button {
                showCorrect = true
            } label: {
                Label("Начислить / списать", systemImage: "plusminus.circle")
            }
            NavigationLink(destination: UserDetailView(id: userId)) {
                Label("Профиль пользователя", systemImage: "person.crop.circle")
            }
            if let url = Fmt.phoneURL(user["phone"].string) {
                Link(destination: url) {
                    Label("Позвонить", systemImage: "phone")
                }
            }
        }
    }

    @ViewBuilder
    private var topupsSection: some View {
        let items = loader.data["topups"].array
        if !items.isEmpty {
            Section("Пополнения") {
                ForEach(items, id: \.stableID) { t in
                    WalletsUserTopupRow(item: t, clientName: user["name"].stringValue, showClient: false,
                                        onNotice: { notice = $0 }, onDone: {
                                            await afterChange()
                                            WalletsLabels.refreshInbox()
                                        })
                }
            }
        }
    }

    @ViewBuilder
    private var txSection: some View {
        let items = loader.data["transactions"].array
        Section("История операций") {
            if items.isEmpty {
                Text("Операций нет").foregroundColor(Brand.muted)
            } else {
                ForEach(items, id: \.stableID) { t in
                    txRow(t)
                }
            }
        }
    }

    @ViewBuilder
    private func txRow(_ t: JSON) -> some View {
        if let orderId = t["order_id"].int, orderId > 0 {
            NavigationLink(destination: OrderDetailView(id: orderId)) {
                WalletsTxRow(item: t)
            }
        } else {
            WalletsTxRow(item: t)
        }
    }
}

/// Строка журнала кошелька клиента.
struct WalletsTxRow: View {
    let item: JSON

    init(item: JSON) { self.item = item }

    private var amount: Decimal? { item["amount"].decimal }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item["type_label"].nonEmptyString ?? item["type"].stringValue)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(Fmt.moneySigned(amount))
                    .monospacedDigit()
                    .foregroundColor((amount ?? 0) < 0 ? Brand.red : Brand.green)
            }
            if let d = item["description"].nonEmptyString {
                Text(d).font(.caption)
            }
            HStack {
                Text(Fmt.date(item["created_at"]))
                if let o = item["order_id"].int, o > 0 {
                    Text("· заказ №" + String(o))
                }
                Spacer()
                Text("баланс " + Fmt.money(item["balance_after"]))
            }
            .font(.caption2)
            .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }
}

/// Ручная корректировка баланса клиента (POST /api/admin/user-wallets/{id}/correct).
///
/// Направление выбирается переключателем, сумма вводится без знака — так
/// «-19» и «19» нельзя перепутать. Перед отправкой — подтверждение с суммой.
///
/// Ручка принимает Idempotency-Key (П-62, А316; плюс adminRepeatGuard на 20 с и push
/// клиенту внутри запроса — ответ может задержаться). Форма (MoneyOpGuard): ожидание до
/// 200 с, при неизвестном исходе — «Проверить» по журналу кошелька (GET
/// /api/admin/user-wallets/{id} → transactions, тип correction); «Провести ещё раз» — только
/// если операции нет, с подтверждением, тем же ключом и телом.
struct WalletsCorrectSheet: View {
    let userId: Int
    let userName: String
    let balance: Decimal?
    /// Итог для показа; пустая строка — только обновить экран.
    let onDone: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var op: MoneyOpGuard
    @State private var direction = "credit"
    @State private var amountText = ""
    @State private var reason = ""
    @State private var askConfirm = false
    @State private var error: String?
    /// Сумма со знаком, ушедшая на сервер.
    @State private var sentValue: Decimal?

    init(userId: Int, userName: String, balance: Decimal?, onDone: @escaping (String) async -> Void) {
        self.userId = userId
        self.userName = userName
        self.balance = balance
        self.onDone = onDone
        let path = "/api/admin/user-wallets/" + String(userId)
        // Журнал без страниц: последние 200 операций одним ответом.
        _op = StateObject(wrappedValue: MoneyOpGuard(history: { _ in
            MoneyOpPage(rows: try await API.shared.get(path)["transactions"].array, more: false)
        }))
    }

    private var isCredit: Bool { direction == "credit" }

    /// Сумма без знака или nil.
    private var amount: Decimal? {
        let t = amountText.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-") || t.hasPrefix("+") { return nil }
        return Fmt.parseDecimal(t)
    }

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Что не так с формой (nil — можно отправлять).
    private var problem: String? {
        let t = amountText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Укажите сумму" }
        if t.hasPrefix("-") || t.hasPrefix("+") { return "Сумму вводите без знака — направление выбрано выше" }
        guard let a = amount else { return "Сумма — число, не больше двух знаков после запятой" }
        if a <= 0 { return "Сумма должна быть больше нуля" }
        if a > 100000 { return "Больше 100 000 ₽ за одну операцию нельзя" }
        if !isCredit, let b = balance, a > b { return "Списать больше баланса нельзя: кошелёк клиента не уходит в минус" }
        if trimmedReason.count < 3 { return "Напишите причину — её увидит клиент в истории" }
        return nil
    }

    private var signed: Decimal {
        let a = amount ?? 0
        return isCredit ? a : -a
    }

    private var confirmTitle: String {
        let verb = isCredit ? "Начислить " : "Списать "
        let prep = isCredit ? " клиенту «" : " у клиента «"
        return verb + Fmt.money(amount) + prep + userName + "»?"
    }

    private var confirmMessage: String {
        var s = "Причина: " + trimmedReason + ". Клиент увидит её в истории."
        if let b = balance {
            // Сумму считаем отдельно: «+» чисел и строк в одном выражении грузит проверку типов.
            let after: Decimal = b + signed
            let was = Fmt.money(b)
            let will = Fmt.money(after)
            s += " Баланс: " + was + " → " + will + "."
        }
        return s
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Действие", selection: $direction) {
                        Text("Начислить").tag("credit")
                        Text("Списать").tag("debit")
                    }
                    .pickerStyle(.segmented)
                    FormDecimalField("Сумма", text: $amountText)
                    FormTextField("Причина (увидит клиент)", text: $reason,
                                  prompt: "Возврат за заблокированное объявление")
                } header: {
                    Text(userName.isEmpty ? "Клиент" : userName)
                } footer: {
                    Text("Баланс сейчас: " + Fmt.money(balance) + ". Операция попадёт в журнал кошелька и в журнал действий администратора. В минус кошелёк клиента уйти не может.")
                }
                .disabled(op.locked)
                if let p = problem, !op.unknown, !amountText.isEmpty || !reason.isEmpty {
                    Section {
                        Text(p).font(.footnote).foregroundColor(Brand.red)
                    }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                MoneyOpUnknownSection(guardian: op, whereText: "журнал кошелька") { check() }
                if !op.unknown {
                    Section {
                        Button {
                            guard !op.locked else { return }
                            Haptics.tap()
                            askConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                if op.busy { ProgressView() } else { Text(submitTitle).bold() }
                                Spacer()
                            }
                        }
                        .disabled(problem != nil || op.locked)
                    }
                }
            }
            .navigationTitle("Изменить баланс")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(op.unknown ? "Закрыть" : "Отмена") { close() }.disabled(op.busy || op.checking)
                }
            }
            .confirmationDialog(confirmTitle, isPresented: $askConfirm, titleVisibility: .visible) {
                Button(confirmButtonTitle, role: confirmRole) {
                    submit()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
        }
        .moneyOpResendDialog(op) { resend() }
        .interactiveDismissDisabled(op.locked)
    }

    private var confirmButtonTitle: String {
        let verb = isCredit ? "Начислить " : "Списать "
        return verb + Fmt.money(amount)
    }

    private var confirmRole: ButtonRole? {
        isCredit ? nil : ButtonRole.destructive
    }

    private var submitTitle: String {
        isCredit ? "Начислить" : "Списать"
    }

    /// «Отмена»/«Закрыть»: при неизвестном исходе — обновить кошелёк (баланс мог измениться).
    private func close() {
        guard !op.busy, !op.checking else { return }
        if op.unknown {
            let done = onDone
            Task { await done("") }
        }
        dismiss()
    }

    private func submit() {
        guard problem == nil, !op.locked else { return }
        let value = signed
        let text = trimmedReason
        error = nil
        sentValue = value
        let path = "/api/admin/user-wallets/" + String(userId) + "/correct"
        Task { @MainActor in
            handle(await op.send(path, body: ["amount": value, "description": text]))
        }
    }

    private func resend() {
        error = nil
        Task { @MainActor in
            handle(await op.resend())
        }
    }

    private func handle(_ outcome: MoneyOpOutcome) {
        let done = onDone
        switch outcome {
        case .done(let res):
            Haptics.success()
            let r = res.data
            let applied = r["applied"].decimal ?? (sentValue ?? 0)
            dismiss()
            let text = "Готово: " + Fmt.moneySigned(applied) + ". Баланс: " + Fmt.money(r["balance"])
            Task { await done(text) }
        case .failed(let e):
            Haptics.error()
            error = e.message
        case .unknown(let e):
            if e != .cancelled { Haptics.error() }
            // 409 «только что прошло» / «не удалось узнать результат» — сразу смотрим историю.
            if op.shouldAutoCheck { check() }
            Task { await done("") }
        case .ignored:
            break
        }
    }

    /// «Проверить»: новая строка correction с этой суммой в журнале кошелька.
    private func check() {
        guard let v = sentValue else { return }
        let done = onDone
        Task { @MainActor in
            let found = await op.check { row in
                row["type"].stringValue == "correction" && MoneyOp.sameAmount(row["amount"], v)
            }
            guard let row = found else { return }
            Haptics.success()
            dismiss()
            let text = "Операция прошла (найдена в журнале): " + Fmt.moneySigned(v) + ". Баланс после: " + Fmt.money(row["balance_after"])
            Task { await done(text) }
        }
    }
}
