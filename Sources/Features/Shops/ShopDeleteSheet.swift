import SwiftUI

/// Удаление организации со всем содержимым: POST /api/admin/shops/{id}/delete
/// {confirm_name, password | code}. Показывает предпросмотр (delete-preview:
/// что исчезнет), требует набрать название и подтвердить паролем администратора
/// или кодом 2FA (что именно — говорит сервер полем has_2fa), как на сайте.
struct ShopDeleteSheet: View {
    let shopId: Int
    let shopName: String
    let preview: JSON
    /// Вызывается после удаления с текстом итога.
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?

    init(shopId: Int, shopName: String, preview: JSON, onDeleted: @escaping (String) -> Void) {
        self.shopId = shopId
        self.shopName = shopName
        self.preview = preview
        self.onDeleted = onDeleted
    }

    private var counts: JSON { preview["counts"] }
    private var has2FA: Bool { preview["has_2fa"].boolValue }
    private var name: String { preview["shop"]["name"].nonEmptyString ?? shopName }
    private var hasHistory: Bool { counts["orders"].intValue > 0 }

    /// Как на сайте: без учёта регистра, лишние пробелы схлопываются.
    private static func norm(_ s: String) -> String {
        let parts = s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        return parts.joined(separator: " ")
    }

    private var canDelete: Bool {
        !busy && !secret.isEmpty && ShopDeleteSheet.norm(typedName) == ShopDeleteSheet.norm(name)
    }

    private var rows: [ShopDeleteCount] {
        let keys: [(String, String)] = [
            ("Товары", "products"), ("Услуги", "services"), ("Заказы", "orders"),
            ("Фото товаров", "photos"), ("Отзывы", "reviews"), ("Сотрудники", "employees"),
            ("Мастера", "masters"), ("Движения по кошельку", "wallet_ops"),
        ]
        var out: [ShopDeleteCount] = []
        for (title, key) in keys {
            let n = counts[key].intValue
            if n > 0 { out.append(ShopDeleteCount(title: title, count: n)) }
        }
        let files = preview["files"].intValue
        if files > 0 { out.append(ShopDeleteCount(title: "Файлов на диске", count: files)) }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                whatSection
                if hasHistory { historySection }
                confirmSection
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button(role: .destructive) {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Удалить навсегда").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canDelete)
                }
            }
            .navigationTitle("Удалить «" + name + "»?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var whatSection: some View {
        Section {
            if rows.isEmpty {
                Text("Организация пустая: товаров, заказов и файлов нет.")
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(rows) { row in
                    KVRow(row.title, Fmt.number(row.count))
                }
            }
        } header: {
            Text("Будет удалено безвозвратно")
        }
    }

    private var historySection: some View {
        Section {
            InfoBanner(historyText, systemImage: "exclamationmark.triangle.fill", color: Brand.red)
        }
    }

    private var historyText: String {
        var t = "У организации есть история заказов. Вместе с заказами исчезнут и списания комиссий по ним"
        if (counts["commission_total"].decimal ?? 0) > 0 {
            t += " (площадка получила с них " + Fmt.money(counts["commission_total"]) + ")"
        }
        t += ", поэтому выручка и GMV за прошлые периоды в отчётах изменятся. Если нужно просто убрать организацию с витрины — поставьте ей статус «Заблокирована» (Изменить карточку → Статус): она пропадёт у клиентов, а данные останутся."
        return t
    }

    private var confirmSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("Наберите название организации: «" + name + "»")
                TextField(name, text: $typedName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if has2FA {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle("Код двухфакторной аутентификации")
                    TextField("000000", text: $secret)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle("Ваш пароль администратора")
                    SecureField("пароль", text: $secret)
                        .textContentType(.password)
                }
            }
        } header: {
            Text("Подтверждение")
        }
    }

    private func submit() {
        guard canDelete else { return }
        busy = true
        error = nil
        Haptics.warning()
        var payload: [String: Any?] = ["confirm_name": typedName]
        if has2FA { payload["code"] = secret } else { payload["password"] = secret }
        let sendBody = payload
        let path = "/api/admin/shops/" + String(shopId) + "/delete"
        let done = onDeleted
        let fallbackName = name
        Task { @MainActor in
            do {
                let res = try await API.shared.post(path, body: sendBody)
                Haptics.success()
                busy = false
                let deletedName = res["name"].nonEmptyString ?? fallbackName
                // Короткими частями — длинная цепочка `+` с перегруженным Fmt.number тяжела для проверки типов.
                let tables: String = Fmt.number(res["tables"])
                let files: String = Fmt.number(res["files"])
                let head: String = "«" + deletedName + "»: "
                let text: String = head + tables + " таблиц, " + files + " файлов."
                done(text)
                dismiss()
                Task { await Notifier.shared.refresh(force: true) }
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                    // Неверный пароль/код — очищаем поле, как на сайте.
                    let need = (error as? APIError)?.details["need"].string ?? ""
                    if need == "password" || need == "2fa" { secret = "" }
                }
            }
        }
    }
}

/// Строка предпросмотра удаления: что и сколько исчезнет.
struct ShopDeleteCount: Identifiable {
    let title: String
    let count: Int
    var id: String { title }
}
