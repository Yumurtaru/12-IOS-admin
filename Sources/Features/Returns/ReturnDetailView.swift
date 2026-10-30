import SwiftUI

/// Заявка на возврат: GET /api/admin/returns/{id} (П-29.4) — строка списка плюс
/// причина, позиции, фото, журнал. Старый сервер без этой ручки — ищем, как раньше:
/// GET /api/admin/returns?q={id} — поиск совпадает и с номером возврата, и с номером
/// заказа, нужную строку выбираем по id.
///
/// Действия как на сайте: на рассмотрении — «Одобрить» (подтверждение с суммой) и
/// «Отклонить» (причина); деньгами вручную и одобрен — «Деньги выплачены».
struct ReturnDetailView: View {
    let id: Int
    let onChanged: (() -> Void)?

    @State private var row: JSON
    @State private var state: LoadState
    @State private var refreshError: String?
    @State private var askReject = false
    @State private var askPaid = false
    @State private var enrichTried = false
    /// Растёт при каждом действии на этом экране: ответ enrich, начатый до действия,
    /// не перетирает статус, который уже обновило действие.
    @State private var actionGen = 0

    init(id: Int, initial: JSON? = nil, onChanged: (() -> Void)? = nil) {
        self.id = id
        self.onChanged = onChanged
        let start = initial ?? .null
        _row = State(initialValue: start)
        _state = State(initialValue: start.isNull ? .idle : .loaded)
    }

    private var status: String { row["status"].string ?? "" }
    private var isPending: Bool { status == "pending" }

    var body: some View {
        AsyncContent(state: state, emptyText: "Возврат #" + String(id) + " не найден",
                     retry: { await load() }) {
            content
        }
        .navigationTitle("Возврат #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if state == .idle {
                await load()
            } else {
                await enrich()
            }
        }
        .sheet(isPresented: $askReject) {
            ReturnsRejectSheet(count: 1) { note in
                try await act { try await ReturnsActions.moderate(id: id, approve: false, note: note) }
            }
        }
        .sheet(isPresented: $askPaid) {
            ReturnsPaidSheet(row: row) { note in
                try await act { try await ReturnsActions.markPaid(id: id, note: note) }
            }
        }
    }

    private var content: some View {
        List {
            if let err = refreshError {
                ErrorBanner(message: err, retry: { Task { await load() } })
                    .listRowSeparator(.hidden)
            }
            headerSection
            linksSection
            // Подробности карточки по id (П-29.4); у строки списка их нет — секций не будет.
            ReturnDetailExtraSections(row: row)
            actionsSection
            Section {
                JSONInspectorView(row)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
    }

    private var headerSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("Возврат #" + String(id))
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                ReturnsStatusBadge(status: row["status"].string)
            }
            .padding(.vertical, 4)
            HStack {
                Text("Сумма").foregroundColor(Brand.muted)
                Spacer()
                MoneyText(row["refund_amount"])
                    .font(.title3.weight(.semibold))
            }
            KVRow("Тип", ReturnsLabels.type(row["type"].string))
            KVRow("Причина", ReturnsLabels.reason(row["reason_code"].string))
            KVRow("Как вернуть", ReturnsLabels.method(row["refund_method"].string))
            KVRow("Создан", Fmt.date(row["created_at"]))
            if isPending && row["age_hours"].intValue >= 72 {
                InfoBanner("Без ответа " + Fmt.plural(row["age_hours"].intValue, "час", "часа", "часов")
                           + " — заявка эскалирована на площадку.",
                           systemImage: "exclamationmark.triangle.fill", color: Brand.red)
            }
        }
    }

    /// «Заказ №N · #id», если сервер прислал номер дня (order_daily_number, А316), иначе «Заказ #id».
    static func orderLinkTitle(_ row: JSON, orderId: Int) -> String {
        if let day = row["order_daily_number"].int, day > 0 {
            return "Заказ №" + String(day) + " · #" + String(orderId)
        }
        return "Заказ #" + String(orderId)
    }

    private var linksSection: some View {
        Section("Связано") {
            if let oid = row["order_id"].int, oid > 0 {
                NavigationLink(destination: OrderDetailView(id: oid)) {
                    Label(ReturnDetailView.orderLinkTitle(row, orderId: oid), systemImage: "list.bullet.rectangle")
                }
            }
            shopLink
            KVRow("Клиент", row["client"].nonEmptyString)
        }
    }

    @ViewBuilder
    private var shopLink: some View {
        let name = row["shop"].nonEmptyString ?? ("Магазин #" + row["shop_id"].stringValue)
        if let sid = row["shop_id"].int, sid > 0 {
            NavigationLink(destination: ShopDetailView(id: sid)) {
                Label(name, systemImage: "building.2")
            }
        } else {
            KVRow("Магазин", name)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if isPending {
            Section {
                ActionButton("Одобрить", systemImage: "checkmark", style: .prominent,
                             confirm: ReturnsActions.approveConfirm(rows: [row]),
                             successMessage: "Возврат одобрен", fullWidth: true) {
                    try await act { try await ReturnsActions.moderate(id: id, approve: true, note: nil) }
                }
                Button(role: .destructive) {
                    askReject = true
                } label: {
                    Label("Отклонить", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } header: {
                Text("Решение")
            } footer: {
                Text("Покупатель получит уведомление о решении.")
            }
        } else if ReturnsActions.canMarkPaid(row) {
            Section {
                InfoBanner("Деньги покупателю возвращает магазин. Когда выплата сделана, отметьте её — заявка закроется.")
                Button {
                    askPaid = true
                } label: {
                    Label("Деньги выплачены", systemImage: "banknote")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } header: {
                Text("Выплата")
            }
        }
    }

    // MARK: - Загрузка

    private func load() async {
        if row.isNull { state = .loading }
        // П-29.4: карточка по id — свежая и с подробностями. Старый сервер такой
        // ручки не знает — тогда, как раньше, ищем строку в списке.
        if let one = try? await API.shared.get("/api/admin/returns/" + String(id)), one.id == id {
            row = one
            state = .loaded
            refreshError = nil
            return
        }
        do {
            let data = try await API.shared.get("/api/admin/returns", query: ["q": String(id)])
            let list = data["items"].array
            let found = list.first { $0.id == id }
            if let f = found {
                row = f
                state = .loaded
                refreshError = nil
            } else if row.isNull {
                state = .empty(nil)
            } else {
                refreshError = "Заявка не найдена в списке возвратов"
            }
        } catch {
            if APIError.isCancellation(error) { return }
            let msg = APIError.describe(error)
            if row.isNull { state = .failed(msg) } else { refreshError = msg }
        }
    }

    /// Открыли из списка (строка без подробностей) — дополнить карточкой по id (П-29.4).
    /// Строка списка могла устареть (продавец уже одобрил) — свежие поля карточки
    /// (статус, сумма, комментарий модератора и остальное) берём с сервера; поля, которых
    /// в карточке нет, остаются из строки. Действие на этом экране, сделанное раньше
    /// ответа, не перетираем. Не вышло (старый сервер, нет сети) — остаётся строка списка.
    private func enrich() async {
        guard !enrichTried, row.object["log"] == nil else { return }
        enrichTried = true
        let gen = actionGen
        guard let one = try? await API.shared.get("/api/admin/returns/" + String(id)), one.id == id else { return }
        var o = row.object
        if gen == actionGen {
            for (k, v) in one.object { o[k] = v }
        } else {
            for (k, v) in one.object where o[k] == nil { o[k] = v }
        }
        row = .object(o)
    }

    /// Действие с заявкой. 409 «Заявка уже обработана» (её решил продавец или другой
    /// администратор) — перечитать карточку, чтобы кнопки и статус стали честными.
    private func act(_ work: () async throws -> Void) async throws {
        actionGen += 1
        do {
            try await work()
        } catch {
            if let e = error as? APIError, e.status == 409 {
                await load()
                onChanged?()
            }
            throw error
        }
        await afterAction()
    }

    private func afterAction() async {
        await load()
        onChanged?()
        Task { await Notifier.shared.refresh(force: true) }
    }
}

/// Подробности заявки из GET /api/admin/returns/{id} (П-29.4): слова покупателя,
/// комментарий модератора, телефон, заказ, позиции, фото, журнал статусов.
/// В строке списка этих полей нет — тогда секции просто не показываются.
struct ReturnDetailExtraSections: View {
    let row: JSON

    init(row: JSON) {
        self.row = row
    }

    var body: some View {
        Group {
            detailsSection
            itemsSection
            photosSection
            logSection
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        let reason = row["reason_text"].nonEmptyString
        let note = row["moderator_note"].nonEmptyString
        let phone = row["client_phone"].nonEmptyString
        let order = row["order"]
        if reason != nil || note != nil || phone != nil || order.isObject {
            Section("Подробности") {
                if let r = reason {
                    textBlock("Слова покупателя", r)
                }
                if let n = note {
                    textBlock("Комментарий модератора", n)
                }
                if let p = phone {
                    phoneRow(p)
                }
                if order.isObject {
                    KVRow("Заказ", ReturnDetailExtraSections.orderText(order))
                }
            }
        }
    }

    private func textBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldTitle(title)
            Text(text)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func phoneRow(_ phone: String) -> some View {
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) { KVRow("Телефон клиента", Fmt.phone(phone)) }
        } else {
            KVRow("Телефон клиента", phone)
        }
    }

    /// «№12 · 1 500,00 ₽ · Доставлен».
    static func orderText(_ order: JSON) -> String {
        var parts: [String] = []
        if let n = order["daily_number"].nonEmptyString { parts.append("№" + n) }
        if !order["total"].isNull { parts.append(Fmt.money(order["total"])) }
        if let st = order["status"].nonEmptyString { parts.append(OrdersLabels.status(st)) }
        return parts.joined(separator: " · ")
    }

    /// Частичный возврат — по типу заявки, а не по items: у частичного items_json
    /// бывает {"unknown":true} или [] (позиции не записаны).
    private var isPartial: Bool { row["type"].string == "partial" }

    /// Строки позиций: частичный возврат — items [{item_id, qty}] с названиями из
    /// order_items (не читаются — пусто); полный — все позиции заказа.
    private var itemLines: [String] {
        let orderItems = row["order_items"].array
        var names: [Int: String] = [:]
        for it in orderItems {
            if let iid = it.id { names[iid] = it["name"].stringValue }
        }
        var out: [String] = []
        let picked = row["items"].array
        if !picked.isEmpty {
            for it in picked {
                let iid = it["item_id"].intValue
                let name = names[iid] ?? ("Позиция #" + String(iid))
                out.append(name + " × " + Fmt.number(it["qty"]))
            }
            return out
        }
        // Частичный без читаемых позиций — весь заказ не показываем, это было бы неправдой.
        if isPartial { return out }
        for it in orderItems {
            let name = it["name"].nonEmptyString ?? "—"
            out.append(name + " × " + Fmt.number(it["qty"]))
        }
        return out
    }

    @ViewBuilder
    private var itemsSection: some View {
        let lines = itemLines
        let partial = isPartial
        if !lines.isEmpty {
            let title: String = partial ? "Что возвращают" : "Позиции заказа (возврат всего заказа)"
            Section(title) {
                ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                    Text(pair.element)
                        .font(.subheadline)
                }
            }
        } else if partial && row["order_items"].isArray {
            // Карточка по id пришла, а позиции частичного возврата не записаны.
            Section("Что возвращают") {
                Text("Какие позиции — не указано")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            }
        }
    }

    /// Пути фото заявки (строки; относительные — от /assets/uploads/).
    private var photoPaths: [String] {
        var out: [String] = []
        for p in row["photos"].array {
            if let path = ModerationMedia.uploadsPath(p.string) { out.append(path) }
        }
        return out
    }

    @ViewBuilder
    private var photosSection: some View {
        let paths = photoPaths
        if !paths.isEmpty {
            Section("Фото (" + String(paths.count) + ")") {
                ReviewsPhotoStrip(paths: paths, size: 120)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
    }

    @ViewBuilder
    private var logSection: some View {
        let log = row["log"].array
        if !log.isEmpty {
            Section("История") {
                ForEach(Array(log.enumerated()), id: \.offset) { pair in
                    ReturnDetailLogRow(entry: pair.element)
                }
            }
        }
    }
}

/// Строка журнала статусов возврата: статус, когда, комментарий.
struct ReturnDetailLogRow: View {
    let entry: JSON

    init(entry: JSON) {
        self.entry = entry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                ReturnsStatusBadge(status: entry["status"].string)
                Spacer(minLength: 8)
                Text(Fmt.date(entry["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let c = entry["comment"].nonEmptyString {
                Text(c)
                    .font(.caption)
                    .foregroundColor(Brand.text)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}
