import SwiftUI

/// Заявка на возврат. Отдельной ручки «возврат по id» на сервере нет, поэтому
/// строку берём из списка (initial) или ищем: GET /api/admin/returns?q={id} — поиск
/// совпадает и с номером возврата, и с номером заказа, нужную строку выбираем по id.
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
            if state == .idle { await load() }
        }
        .sheet(isPresented: $askReject) {
            ReturnsRejectSheet(count: 1) { note in
                try await ReturnsActions.moderate(id: id, approve: false, note: note)
                await afterAction()
            }
        }
        .sheet(isPresented: $askPaid) {
            ReturnsPaidSheet(row: row) { note in
                try await ReturnsActions.markPaid(id: id, note: note)
                await afterAction()
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

    private var linksSection: some View {
        Section("Связано") {
            if let oid = row["order_id"].int, oid > 0 {
                NavigationLink(destination: OrderDetailView(id: oid)) {
                    Label("Заказ #" + String(oid), systemImage: "list.bullet.rectangle")
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
                    try await ReturnsActions.moderate(id: id, approve: true, note: nil)
                    await afterAction()
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

    private func afterAction() async {
        await load()
        onChanged?()
        Task { await Notifier.shared.refresh(force: true) }
    }
}
