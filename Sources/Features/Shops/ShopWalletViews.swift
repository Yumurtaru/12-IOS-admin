import SwiftUI

/// Строка движения по кошельку магазина: тип, заказ, описание, сумма, баланс после.
struct ShopWalletTxRow: View {
    let tx: JSON

    init(tx: JSON) {
        self.tx = tx
    }

    private var amount: Decimal { tx["amount"].decimal ?? 0 }

    private var subtitle: String {
        var parts: [String] = [Fmt.date(tx["created_at"].string)]
        if let oid = tx["order_id"].int { parts.append("заказ #" + String(oid)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShopsLabels.walletType(tx["type"].string))
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if let d = tx["description"].nonEmptyString {
                    Text(d)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.moneySigned(amount))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundColor(amount < 0 ? Brand.red : Brand.green)
                Text(Fmt.money(tx["balance_after"]))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Полная история кошелька: GET /api/admin/shops/{id}/wallet (по 50, страницы).
struct ShopWalletHistoryView: View {
    let shopId: Int
    let shopName: String
    @StateObject private var model: PagedListModel

    init(shopId: Int, shopName: String) {
        self.shopId = shopId
        self.shopName = shopName
        _model = StateObject(wrappedValue: PagedListModel(path: "/api/admin/shops/" + String(shopId) + "/wallet",
                                                          searchParam: nil))
    }

    var body: some View {
        AdminListScreen("История кошелька", model: model, searchPrompt: nil, emptyText: "Движений нет",
                        header: AnyView(ShopWalletHistoryHeader(shopName: shopName)),
                        row: { ShopWalletTxRow(tx: $0) },
                        destination: { tx in walletDestination(tx) })
    }

    /// Строка с заказом ведёт в заказ; без заказа — в сводку операции.
    @ViewBuilder
    private func walletDestination(_ tx: JSON) -> some View {
        if let oid = tx["order_id"].int {
            OrderDetailView(id: oid)
        } else {
            List {
                Section { ShopWalletTxRow(tx: tx) }
                Section { JSONInspectorView(tx, expanded: true) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Операция")
        }
    }
}

/// Подпись над историей.
struct ShopWalletHistoryHeader: View {
    let shopName: String

    var body: some View {
        Text("«" + shopName + "»: пополнения, списания комиссий и сборов по заказам. Сумма справа — изменение, ниже — баланс после.")
            .font(.caption)
            .foregroundColor(Brand.muted)
            .listRowSeparator(.hidden)
    }
}

/// Ручное пополнение кошелька магазина: POST /api/admin/shops/{id}/topup
/// {amount, comment}. Сумма может быть отрицательной (ручное списание), не
/// больше 1 000 000 ₽ по модулю; повтор той же суммы в течение 20 с сервер отклонит.
struct ShopTopupSheet: View {
    let shopId: Int
    let shopName: String
    let onDone: (JSON) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = "1000"
    @State private var comment = "Наличные"
    @State private var askConfirm = false
    @State private var busy = false
    @State private var error: String?
    @State private var resultText: String?

    init(shopId: Int, shopName: String, onDone: @escaping (JSON) async -> Void) {
        self.shopId = shopId
        self.shopName = shopName
        self.onDone = onDone
    }

    private var amount: Decimal? {
        guard let d = Fmt.parseDecimal(amountText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return d == 0 ? nil : d
    }

    private var tooBig: Bool {
        guard let a = amount else { return false }
        let limit: Decimal = 1_000_000
        return a > limit || a < -limit
    }

    private var confirmTitle: String {
        guard let a = amount else { return "" }
        let shop: String = "«" + shopName + "»?"
        if a < 0 {
            let sum: String = Fmt.money(-a)
            return "Списать " + sum + " с кошелька " + shop
        }
        let sum: String = Fmt.money(a)
        return "Зачислить " + sum + " на кошелёк " + shop
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormDecimalField("Сумма", text: $amountText)
                    FormTextField("Комментарий", text: $comment, prompt: "Наличные")
                } header: {
                    Text(shopName)
                } footer: {
                    Text("Отрицательная сумма — ручное списание. Не больше 1 000 000 ₽ за одну операцию.")
                }
                if tooBig {
                    Section { ErrorBanner(message: "Больше 1 000 000 ₽ за одну операцию нельзя") }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button {
                        Haptics.tap()
                        askConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Зачислить").bold() }
                            Spacer()
                        }
                    }
                    .disabled(amount == nil || tooBig || busy)
                }
            }
            .navigationTitle("Пополнить кошелёк")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }.disabled(busy)
                }
            }
            .confirmationDialog(confirmTitle, isPresented: $askConfirm, titleVisibility: .visible) {
                Button((amount ?? 0) < 0 ? "Списать" : "Зачислить") { submit() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Операция попадёт в историю кошелька и журнал действий.")
            }
            .alert(resultText ?? "", isPresented: resultShown) {
                Button("OK") { dismiss() }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var resultShown: Binding<Bool> {
        Binding(get: { resultText != nil }, set: { if !$0 { resultText = nil } })
    }

    private func submit() {
        guard let a = amount, !busy else { return }
        busy = true
        error = nil
        let note = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = "/api/admin/shops/" + String(shopId) + "/topup"
        let done = onDone
        Task { @MainActor in
            do {
                let res = try await API.shared.post(path, body: ["amount": a, "comment": note])
                Haptics.success()
                await done(res)
                busy = false
                resultText = "Готово. Баланс: " + Fmt.money(res["balance"])
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
