import SwiftUI

/// Секция карточки организации «Вход владельца» (волна А76): логин владельца
/// (owner.login_phone / owner.login_email из GET /api/admin/shops/{id}), задан ли
/// пароль (owner.has_password), «Создана администратором» (created_by_admin) и
/// кнопка «Выдать новый пароль». Старый сервер этих полей не отдаёт — секции нет.
struct ShopOwnerAccessSection: View {
    let shop: JSON
    let onResetPassword: () -> Void

    init(shop: JSON, onResetPassword: @escaping () -> Void) {
        self.shop = shop
        self.onResetPassword = onResetPassword
    }

    private var owner: JSON { shop["owner"] }

    /// Сервер с волной А76: ключи логина есть (значение может быть null).
    static func supported(_ shop: JSON) -> Bool {
        shop["owner"].isObject
            && (shop["owner"].object["login_phone"] != nil || shop.object["owner_login_phone"] != nil)
    }

    private var loginPhone: String? { owner["login_phone"].nonEmptyString ?? shop["owner_login_phone"].nonEmptyString }
    private var loginEmail: String? { owner["login_email"].nonEmptyString ?? shop["owner_login_email"].nonEmptyString }

    var body: some View {
        Section {
            if let p = loginPhone {
                KVRow("Логин — телефон", ShopCredentials.phoneLogin(p), copyable: true)
            }
            if let e = loginEmail {
                KVRow("Логин — почта", e, copyable: true)
            }
            if loginPhone == nil && loginEmail == nil {
                KVRow("Логин", "нет ни телефона, ни почты")
            }
            if let has = owner["has_password"].bool {
                HStack {
                    Text("Пароль").foregroundColor(Brand.muted)
                    Spacer()
                    Text(has ? "задан" : "не задан")
                        .foregroundColor(has ? Brand.text : Brand.red)
                }
                .font(.subheadline)
            }
            if let adminId = shop["created_by_admin"].int {
                NavigationLink(destination: UserDetailView(id: adminId)) {
                    Label("Создана администратором", systemImage: "person.badge.key")
                        .font(.subheadline)
                }
            }
            Button {
                onResetPassword()
            } label: {
                Label("Выдать новый пароль", systemImage: "key")
            }
        } header: {
            Text("Вход владельца")
        } footer: {
            Text("По телефону или почте владелец входит в панель продавца на сайте и в приложение «Yumurta Seller». Новый пароль завершает все его прежние входы.")
        }
    }
}

/// «Выдать новый пароль» владельцу организации:
/// POST /api/admin/shops/{id}/owner-password {password} или {generate: true}
/// → {shop_id, user_id, login_phone, login_email, password, generated,
///    sessions_revoked, login_url, blocked, warnings[], share_text}.
/// Подтверждение перед отправкой: все входы владельца (сайт, приложения, касса
/// по его логину) завершатся. Результат — пароль один раз (ShopCredentialsSections).
struct ShopOwnerPasswordSheet: View {
    let shopId: Int
    let shopName: String
    let ownerName: String?

    @Environment(\.dismiss) private var dismiss
    @State private var mode = "gen"
    @State private var password = ""
    @State private var askConfirm = false
    @State private var busy = false
    @State private var error: String?
    @State private var passwordError: String?
    @State private var result: ShopCredentials?

    init(shopId: Int, shopName: String, ownerName: String?) {
        self.shopId = shopId
        self.shopName = shopName
        self.ownerName = ownerName
    }

    var body: some View {
        NavigationStack {
            Form {
                if let r = result {
                    ShopCredentialsSections(creds: r)
                } else {
                    formSections
                }
            }
            .navigationTitle("Новый пароль владельца")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if result == nil {
                        Button("Отмена") { dismiss() }.disabled(busy)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil {
                        Button("Готово") { dismiss() }
                    } else if busy {
                        ProgressView()
                    }
                }
            }
            .confirmationDialog("Выдать новый пароль владельцу «" + shopName + "»?",
                                isPresented: $askConfirm, titleVisibility: .visible) {
                Button("Выдать пароль", role: .destructive) { submit() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Прежний пароль перестанет работать, все входы владельца (сайт, приложения, касса по его логину) будут завершены — ему нужно будет войти заново с новым паролем.")
            }
        }
        // Пароль виден только здесь: случайный свайп вниз не должен его потерять.
        .interactiveDismissDisabled(busy || result?.password != nil)
    }

    @ViewBuilder
    private var formSections: some View {
        Section {
            KVRow("Организация", shopName)
            KVRow("Владелец", ownerName)
        }
        Section {
            FormPicker("Пароль", selection: $mode, options: ShopCreateSheet.passwordModes)
            if mode == "own" {
                // Обычное поле, не «новый пароль»: иначе iOS предложит сохранить
                // его в Связку ключей этого телефона.
                TextField("минимум 6 символов", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
            if let pe = passwordError {
                Text(pe)
                    .font(.caption)
                    .foregroundColor(Brand.red)
            }
        } header: {
            Text("Новый пароль")
        } footer: {
            Text("Прежний пароль перестанет работать, все входы владельца (сайт, приложения, касса по его логину) будут завершены — ему нужно будет войти заново с новым паролем. Владельцу придёт уведомление о смене пароля (без самого пароля).")
        }
        if let e = error {
            Section { ErrorBanner(message: e) }
        }
        Section {
            Button {
                startSubmit()
            } label: {
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                    } else {
                        Label("Выдать пароль", systemImage: "key")
                            .font(.body.weight(.semibold))
                    }
                    Spacer()
                }
            }
            .disabled(busy)
        }
    }

    private func startSubmit() {
        guard !busy else { return }
        error = nil
        passwordError = nil
        if mode == "own" && password.isEmpty {
            passwordError = "Введите пароль или выберите «Придумать автоматически»"
            return
        }
        askConfirm = true
    }

    private func submit() {
        guard !busy else { return }
        let body: [String: Any?] = mode == "own" ? ["password": password] : ["generate": true]
        let path = "/api/admin/shops/" + String(shopId) + "/owner-password"
        busy = true
        Task { @MainActor in
            do {
                let d = try await API.shared.post(path, body: body)
                busy = false
                Haptics.success()
                result = ShopCredentials.fromReset(d, shopName: shopName)
            } catch {
                busy = false
                if APIError.isCancellation(error) { return }
                Haptics.error()
                let e = (error as? APIError) ?? API.mapTransport(error)
                passwordError = e.fieldErrors["password"]
                if e.status == 0 {
                    // Ответ не дошёл: пароль мог уже смениться на сервере.
                    self.error = e.message + "\nЕсли повторите, сервер выдаст ещё один новый пароль — прежний (неизвестный) перестанет действовать."
                } else {
                    self.error = e.message
                }
            }
        }
    }
}
