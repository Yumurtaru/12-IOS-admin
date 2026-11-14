import SwiftUI

/// Бонусы клиента в карточке пользователя (как на сайте): баланс по организациям,
/// «Начислить / снять», история последних операций.
///
/// GET  /api/admin/users/{id}       → bonus_shops[{shop_id, shop_name, balance}],
///                                    bonus_history[{id, type, amount (со знаком), balance_after,
///                                    shop_id, shop_name, order_id, source, note, admin_name, created_at, expires_at}]
/// POST /api/admin/users/{id}/bonus {shop_id, amount: "500.00" | "-200.00", reason, idempotency_key}
///                                  → data {shop_id, shop_balance, bonus_balance, transaction_id}

/// «Бонусы по организациям» + кнопка «Начислить / снять».
struct UsersBonusSection: View {
    let shops: [JSON]
    let onAdd: () -> Void

    init(shops: [JSON], onAdd: @escaping () -> Void) {
        self.shops = shops
        self.onAdd = onAdd
    }

    var body: some View {
        Section("Бонусы по организациям") {
            if shops.isEmpty {
                Text("Бонусов в организациях нет")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(Array(shops.enumerated()), id: \.offset) { pair in
                    KVRow(pair.element["shop_name"].nonEmptyString ?? ("Организация #" + pair.element["shop_id"].stringValue),
                          json: pair.element["balance"], money: true)
                }
            }
            Button {
                Haptics.tap()
                onAdd()
            } label: {
                Label("Начислить / снять", systemImage: "plus.forwardslash.minus")
            }
        }
    }
}

/// «История бонусов»: последние операции (до 50).
struct UsersBonusHistorySection: View {
    let rows: [JSON]

    init(rows: [JSON]) {
        self.rows = rows
    }

    var body: some View {
        if !rows.isEmpty {
            Section("История бонусов") {
                ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                    UsersBonusHistoryLine(row: pair.element)
                }
            }
        }
    }
}

/// Строка истории бонусов.
struct UsersBonusHistoryLine: View {
    let row: JSON

    init(row: JSON) {
        self.row = row
    }

    private var amount: Decimal? { row["amount"].decimal }

    /// У ручных операций — «администратор: имя, причина»; у остальных — примечание.
    private var detail: String? {
        let note = row["note"].nonEmptyString
        if let admin = row["admin_name"].nonEmptyString {
            var s = "администратор: " + admin
            if let n = note { s += ", " + n }
            return s
        }
        return note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row["shop_name"].nonEmptyString ?? "Без организации")
                    .font(.subheadline)
                if let d = detail {
                    Text(d).font(.caption).foregroundColor(Brand.muted).lineLimit(3)
                }
                Text(Fmt.date(row["created_at"]))
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
            Spacer()
            Text(Fmt.moneySigned(amount))
                .font(.subheadline.monospacedDigit())
                .foregroundColor((amount ?? 0) < 0 ? Brand.red : Brand.green)
        }
    }
}

/// Лист «Начислить / снять бонусы»: организация, действие, сумма, причина, подтверждение.
/// Отправка через MoneyOpGuard (ключ повтора, неизвестный исход, защита от двойного нажатия);
/// при неизвестном исходе «Проверить» ищет операцию в bonus_history.
struct UsersBonusSheet: View {
    let userId: Int
    let userName: String
    let shops: [JSON]
    /// Итог для показа; пустая строка — только обновить экран.
    let onDone: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var op: MoneyOpGuard
    @State private var shopId: Int?
    @State private var shopName = ""
    @State private var direction = "credit"
    @State private var amountText = ""
    @State private var reason = ""
    @State private var askConfirm = false
    @State private var error: String?
    @State private var sentValue: Decimal?
    @State private var sentShop: Int?

    init(userId: Int, userName: String, shops: [JSON], onDone: @escaping (String) async -> Void) {
        self.userId = userId
        self.userName = userName
        self.shops = shops
        self.onDone = onDone
        let path = "/api/admin/users/" + String(userId)
        _op = StateObject(wrappedValue: MoneyOpGuard(scope: MoneyOpStore.userBonus(userId), history: { _ in
            let d = try await API.shared.get(path)
            return MoneyOpPage(rows: d["bonus_history"].array, more: false, idem: d["idem"].boolValue)
        }))
    }

    private var isCredit: Bool { direction == "credit" }

    private var amount: Decimal? {
        let t = amountText.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("-") || t.hasPrefix("+") { return nil }
        return Fmt.parseDecimal(t)
    }

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Баланс клиента в выбранной организации; nil — организации нет в списке клиента.
    private var shopBalance: Decimal? {
        guard let sid = shopId else { return nil }
        for s in shops where s["shop_id"].int == sid {
            return s["balance"].decimal ?? 0
        }
        return nil
    }

    private var signed: Decimal {
        let a = amount ?? 0
        return isCredit ? a : -a
    }

    private var problem: String? {
        if shopId == nil { return "Выберите организацию" }
        let t = amountText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Укажите сумму" }
        if t.hasPrefix("-") || t.hasPrefix("+") { return "Сумму вводите без знака — действие выбрано выше" }
        guard let a = amount else { return "Сумма — число, не больше двух знаков после запятой" }
        if a <= 0 { return "Сумма должна быть больше нуля" }
        if a > 100000 { return "Больше 100 000 ₽ за одну операцию нельзя" }
        if !isCredit, let b = shopBalance, a > b { return "Снять можно не больше " + Fmt.money(b) }
        if trimmedReason.count < 3 { return "Напишите причину (от 3 символов)" }
        if trimmedReason.count > 500 { return "Причина — не больше 500 символов" }
        return nil
    }

    private var confirmTitle: String {
        let verb = isCredit ? "Начислить " : "Снять "
        return verb + Fmt.money(amount) + " бонусов в «" + shopName + "»?"
    }

    private var confirmMessage: String {
        var s = "Причина: " + trimmedReason + "."
        if let b = shopBalance {
            let after: Decimal = b + signed
            let was = Fmt.money(b)
            let will = Fmt.money(after)
            s += " Баланс в организации: " + was + " → " + will + "."
        }
        return s
    }

    private var confirmButtonTitle: String {
        (isCredit ? "Начислить " : "Снять ") + Fmt.money(amount)
    }

    private var submitTitle: String { isCredit ? "Начислить" : "Снять" }

    var body: some View {
        NavigationStack {
            Form {
                shopSection
                amountSection
                if let p = problem, !op.unknown, !amountText.isEmpty || !reason.isEmpty {
                    Section {
                        Text(p).font(.footnote).foregroundColor(Brand.red)
                    }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                MoneyOpUnknownSection(guardian: op, whereText: "историю бонусов") { check() }
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
            .navigationTitle("Бонусы клиента")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(op.unknown ? "Закрыть" : "Отмена") { close() }.disabled(op.busy || op.checking)
                }
            }
            .confirmationDialog(confirmTitle, isPresented: $askConfirm, titleVisibility: .visible) {
                Button(confirmButtonTitle, role: isCredit ? nil : ButtonRole.destructive) { submit() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
            .onAppear { prepare() }
        }
        .moneyOpResendDialog(op) { resend() }
        .interactiveDismissDisabled(op.locked)
    }

    private var shopSection: some View {
        Section {
            ForEach(Array(shops.enumerated()), id: \.offset) { pair in
                clientShopRow(pair.element)
            }
            NavigationLink(destination: ShopsOptionsPicker(selectedId: shopId) { sid, name in
                shopId = sid
                shopName = name
            }) {
                Text("Другая организация…")
            }
        } header: {
            Text("Организация, где можно потратить баллы")
        } footer: {
            if let sid = shopId {
                Text(verbatim: "Выбрано: \(shopName) (#\(sid))")
            }
        }
        .disabled(op.locked)
    }

    private func clientShopRow(_ s: JSON) -> some View {
        let sid = s["shop_id"].int ?? 0
        let name = s["shop_name"].nonEmptyString ?? ("Организация #" + String(sid))
        return Button {
            shopId = sid
            shopName = name
        } label: {
            HStack {
                Text(name).foregroundColor(Brand.text).lineLimit(1)
                Spacer()
                Text(Fmt.money(s["balance"])).foregroundColor(Brand.muted)
                if sid == shopId {
                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                }
            }
        }
    }

    private var amountSection: some View {
        Section {
            Picker("Действие", selection: $direction) {
                Text("Начислить").tag("credit")
                Text("Снять").tag("debit")
            }
            .pickerStyle(.segmented)
            FormDecimalField("Сумма", text: $amountText)
            FormTextField("Причина", text: $reason, prompt: "Компенсация за задержку заказа")
        } header: {
            Text(userName.isEmpty ? "Клиент" : userName)
        } footer: {
            Text("Баллы можно потратить только в выбранной организации. При начислении клиент получит уведомление «Вам начислены бонусы». Операция попадёт в историю бонусов и в журнал действий администратора.")
        }
        .disabled(op.locked)
    }

    // MARK: - Действия

    /// Ровно два знака после точки, без разделителей тысяч: "500.00", "-200.00".
    static func amountString(_ d: Decimal) -> String {
        var src = d
        var out = Decimal()
        NSDecimalRound(&out, &src, 2, .plain)
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: out)) ?? "0.00"
    }

    /// Первый показ: поднять незавершённую операцию или выбрать организацию клиента.
    private func prepare() {
        if let r = op.takeRestored() {
            let v = r.body["amount"].decimal ?? 0
            direction = v < 0 ? "debit" : "credit"
            amountText = NSDecimalNumber(decimal: v < 0 ? -v : v).stringValue
            reason = r.body["reason"].stringValue
            shopId = r.body["shop_id"].int
            shopName = r.extra["shop_name"] ?? ""
            sentValue = v
            sentShop = shopId
            check()
            return
        }
        if shopId == nil, let first = shops.first, let sid = first["shop_id"].int {
            shopId = sid
            shopName = first["shop_name"].nonEmptyString ?? ("Организация #" + String(sid))
        }
    }

    private func close() {
        guard !op.busy, !op.checking else { return }
        if op.unknown {
            let done = onDone
            Task { await done("") }
        }
        dismiss()
    }

    private func submit() {
        guard problem == nil, !op.locked, let sid = shopId else { return }
        let value = signed
        let text = trimmedReason
        let name = shopName
        error = nil
        sentValue = value
        sentShop = sid
        let path = "/api/admin/users/" + String(userId) + "/bonus"
        let body: [String: Any?] = ["shop_id": sid, "amount": UsersBonusSheet.amountString(value), "reason": text]
        Task { @MainActor in
            handle(await op.send(path, body: body, extra: ["shop_name": name]))
        }
    }

    private func resend() {
        error = nil
        Task { @MainActor in
            handle(await op.resend())
        }
    }

    private func failText(_ e: APIError) -> String {
        if let av = e.fieldErrors["available"], let d = Decimal(string: av, locale: Locale(identifier: "en_US_POSIX")) {
            return "Снять можно не больше " + Fmt.money(d)
        }
        return e.message
    }

    private func handle(_ outcome: MoneyOpOutcome) {
        let done = onDone
        switch outcome {
        case .done(let res):
            Haptics.success()
            let r = res.data
            let name = shopName.isEmpty ? "организации" : shopName
            dismiss()
            let text = MoneyOp.replayPrefix(res) + "Готово: баланс в «" + name + "» — " + Fmt.money(r["shop_balance"])
            Task { await done(text) }
        case .failed(let e):
            Haptics.error()
            error = failText(e)
        case .unknown(let e):
            if e != .cancelled { Haptics.error() }
            if op.shouldAutoCheck { check() }
            Task { await done("") }
        case .ignored:
            break
        }
    }

    /// «Проверить»: новая строка истории бонусов с этой организацией и суммой.
    private func check() {
        guard let v = sentValue, let sid = sentShop else { return }
        let done = onDone
        let name = shopName.isEmpty ? "организации" : shopName
        Task { @MainActor in
            let found = await op.check { row in
                row["shop_id"].int == sid && MoneyOp.sameAmount(row["amount"], v)
            }
            guard found != nil else { return }
            Haptics.success()
            dismiss()
            let text = "Операция прошла (найдена в истории бонусов) в «" + name + "»: " + Fmt.moneySigned(v)
            Task { await done(text) }
        }
    }
}
