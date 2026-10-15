import SwiftUI

/// Карточка товара. Отдельной ручки «товар по id» в админке нет — показываем
/// строку списка (всё, что отдаёт GET /api/admin/products) и действия.
struct ProductsDetailView: View {
    let model: PagedListModel
    @State private var product: JSON
    @State private var askHide = false

    init(product: JSON, model: PagedListModel) {
        self.model = model
        _product = State(initialValue: product)
    }

    private var id: Int { product.id ?? 0 }
    private var isHidden: Bool { product["status"].string == "hidden" }

    var body: some View {
        List {
            headerSection
            infoSection
            actionSection
            Section {
                JSONInspectorView(product)
            }
        }
        .navigationTitle("Товар #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $askHide) { hideSheet }
    }

    private var headerSection: some View {
        Section {
            if let path = ModerationMedia.uploadsPath(product["photo"].string) {
                AsyncImageView(path: path, height: 220, cornerRadius: 12, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(product["name"].nonEmptyString ?? "Без названия")
                    .font(.headline)
                HStack(spacing: 8) {
                    MoneyText(product["price"]).font(.title3.weight(.semibold))
                    StatusBadge(ProductsFormat.statusLabel(product["status"].string),
                                color: ProductsFormat.statusColor(product["status"].string))
                }
            }
            .padding(.vertical, 4)
            if let r = product["hide_reason"].nonEmptyString {
                InfoBanner("Причина скрытия: " + r, systemImage: "eye.slash", color: Brand.red)
            }
        }
    }

    private var infoSection: some View {
        Section("Сведения") {
            KVRow("Номер", "#" + String(id), copyable: true)
            shopRow
            KVRow("Тип", product["type"].string)
            KVRow("Добавлен", Fmt.date(product["created_at"]))
        }
    }

    @ViewBuilder
    private var shopRow: some View {
        if let shopId = product["shop_id"].int, shopId > 0 {
            NavigationLink(destination: ShopDetailView(id: shopId)) {
                KVRow("Магазин", product["shop"].nonEmptyString ?? ("#" + String(shopId)))
            }
        } else {
            KVRow("Магазин", product["shop"].string)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if isHidden {
                ActionButton("Вернуть на витрину", systemImage: "eye", style: .prominent,
                             confirm: ConfirmAction(title: "Вернуть товар на витрину?",
                                                    message: product["name"].string,
                                                    confirmLabel: "Вернуть"),
                             successMessage: "Товар возвращён на витрину", fullWidth: true) {
                    try await ProductsActions.setHidden(id: id, hide: false, reason: "")
                    apply(status: "active", reason: "")
                }
            } else {
                Button(role: .destructive) {
                    askHide = true
                } label: {
                    Label("Скрыть с витрины", systemImage: "eye.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        } footer: {
            Text("Скрытый товар пропадает с витрины и из поиска, но остаётся у продавца в панели. Продавец получит уведомление с причиной.")
        }
    }

    private var hideSheet: some View {
        let pid = id
        let name = product["name"].stringValue
        return ModerationReasonSheet(title: "Причина снятия товара",
                                     message: "«" + name + "» пропадёт с витрины. Причину увидит продавец.",
                                     reasons: ProductsFormat.hideReasons,
                                     submitTitle: "Скрыть товар") { reason in
            try await ProductsActions.setHidden(id: pid, hide: true, reason: reason)
            apply(status: "hidden", reason: reason)
        }
    }

    private func apply(status: String, reason: String) {
        let updated = ProductsActions.patched(product, status: status, reason: reason)
        product = updated
        model.update(id: id) { row in
            row = ProductsActions.patched(row, status: status, reason: reason)
        }
    }
}
