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
struct WalletsUserTopupRow: View {
    let item: JSON
    let clientName: String
    let showClient: Bool
    let onNotice: (String) -> Void
    let onDone: () async -> Void
    let onOpenWallet: (() -> Void)?

    @State private var askClose = false

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
                        askClose = true
                    } label: {
                        Label("Закрыть", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
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
        if st == "confirmed" {
            onNotice("Платёж прошёл, зачислено. Баланс клиента: " + Fmt.money(r["balance"]))
        } else {
            onNotice("ЮKassa: платёж пока не оплачен (" + WalletsLabels.userTopupStatus(st) + ")")
        }
        await onDone()
    }

    private var closeSheet: some View {
        let who = clientName.isEmpty ? "клиент" : "клиент «" + clientName + "»"
        // Части отдельно: длинная цепочка «+» с ?? и перегруженными функциями
        // заметно грузит проверку типов Xcode.
        let num = String(item.id ?? 0)
        let sum = Fmt.money(item["amount"])
        let head = "Пополнение №" + num + " · " + sum
        let msg = head + " · " + who + ". Закрыть как неоплаченное — деньги не зачисляются."
        return TextInputSheet(title: "Закрыть заявку", message: msg, placeholder: "Закрыто администратором",
                              multiline: true, submitTitle: "Закрыть как неоплаченную", minLength: 0,
                              destructive: true) { text in
            let id = item.id ?? 0
            let reason = text.isEmpty ? "Закрыто администратором" : text
            try await API.shared.post("/api/admin/user-topups/\(id)/reject", body: ["reason": reason])
            onNotice("Заявка закрыта")
            await onDone()
        }
    }
}
