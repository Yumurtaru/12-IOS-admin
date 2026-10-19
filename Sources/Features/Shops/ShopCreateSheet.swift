import SwiftUI

/// «Добавить организацию» (волна А76): администратор сам заводит организацию и
/// выдаёт владельцу логин и пароль. Поля и подписи — как в форме веб-админки
/// (admin.js openCreateShop).
///
/// POST /api/admin/shops/create {name, type: shop|cafe|service|lodging, city_id,
/// address?, phone?, inn?, owner_name, owner_phone?, owner_email? (хотя бы одно),
/// password?, generate_password?, reset_password?, publish_now?,
/// commission_percent?, send_email?} c ключом повтора Idempotency-Key.
/// Ответ — карточка результата (ShopCredentialsSections): пароль один раз.
struct ShopCreateSheet: View {
    /// Организация создана (или могла быть создана) — обновить список.
    let onCreated: () -> Void
    /// Открыть карточку организации (лист уже закрывается).
    let onOpenShop: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type = "shop"
    @State private var cityId: Int?
    @State private var cityName: String?
    @State private var address = ""
    @State private var phone = ""
    @State private var inn = ""
    @State private var ownerName = ""
    @State private var ownerPhone = ""
    @State private var ownerEmail = ""
    @State private var pwMode = "gen"
    @State private var password = ""
    @State private var resetPassword = false
    @State private var commission = "0"
    @State private var publishNow = false
    @State private var sendEmail = false

    @State private var pickCity = false
    @State private var busy = false
    @State private var error: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var existingShopId: Int?
    /// Ключ повтора текущей формы. Живёт до окончательного ответа сервера:
    /// обрыв связи/таймаут — повтор уходит с тем же ключом, и сервер вернёт
    /// прежний результат вместо второй организации.
    @State private var idemKey: String?
    @State private var result: ShopCredentials?

    init(onCreated: @escaping () -> Void, onOpenShop: @escaping (Int) -> Void) {
        self.onCreated = onCreated
        self.onOpenShop = onOpenShop
    }

    /// Типы — как NEW_SHOP_TYPES в admin.js (Admin::ADMIN_SHOP_TYPES на сервере).
    static let typeOptions: [PickerOption] = [
        PickerOption(value: "shop", label: "Магазин"),
        PickerOption(value: "cafe", label: "Кафе / ресторан"),
        PickerOption(value: "service", label: "Услуги"),
        PickerOption(value: "lodging", label: "Жильё"),
    ]

    static let passwordModes: [PickerOption] = [
        PickerOption(value: "gen", label: "Придумать автоматически"),
        PickerOption(value: "own", label: "Ввести самому"),
    ]

    /// Поля, ошибки которых показываются под самими полями.
    private static let inlineFields: Set<String> = ["name", "type", "city_id", "address", "phone", "inn",
                                                    "owner_name", "owner_phone", "owner_email",
                                                    "password", "commission_percent"]

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasEmail: Bool { !trim(ownerEmail).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if let r = result {
                    ShopCredentialsSections(creds: r, onOpenShop: { sid in openShop(sid) })
                } else {
                    formSections
                }
            }
            .navigationTitle(result == nil ? "Новая организация" : "Организация создана")
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
                    } else {
                        Button("Создать") { create() }
                    }
                }
            }
            .sheet(isPresented: $pickCity) {
                CitiesPickerSheet(allowAll: false) { id, name in
                    cityId = id
                    cityName = name
                    fieldErrors["city_id"] = nil
                }
            }
        }
        // Пароль виден только здесь: случайный свайп вниз не должен его потерять.
        .interactiveDismissDisabled(busy || result?.password != nil)
    }

    // MARK: - Форма

    @ViewBuilder
    private var formSections: some View {
        organizationSection
        ownerSection
        passwordSection
        termsSection
        if let e = error {
            Section {
                ErrorBanner(message: e)
                if let sid = existingShopId {
                    Button {
                        openShop(sid)
                    } label: {
                        Label("Открыть существующую организацию", systemImage: "building.2")
                    }
                }
            }
        }
        Section {
            Button {
                create()
            } label: {
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                        Text("Создаю…")
                    } else {
                        Text("Создать").font(.body.weight(.semibold))
                    }
                    Spacer()
                }
            }
            .disabled(busy)
        }
    }

    private var organizationSection: some View {
        Section {
            FormTextField("Название *", text: $name)
            fieldError("name")
            FormPicker("Тип *", selection: $type, options: ShopCreateSheet.typeOptions)
            fieldError("type")
            cityRow
            fieldError("city_id")
            FormTextField("Адрес (необязательно)", text: $address)
            fieldError("address")
            FormTextField("Телефон организации (необязательно)", text: $phone, prompt: "+7",
                          keyboard: .phonePad, autocapitalize: false)
            fieldError("phone")
            FormTextField("ИНН (необязательно)", text: $inn, prompt: "10 или 12 цифр",
                          keyboard: .numberPad, autocapitalize: false)
            fieldError("inn")
        } header: {
            Text("Организация")
        }
    }

    private var cityRow: some View {
        Button {
            pickCity = true
        } label: {
            HStack {
                Text("Город *")
                    .foregroundColor(Brand.text)
                Spacer()
                Text(cityName ?? "Выбрать")
                    .foregroundColor(cityName == nil ? Brand.accent : Brand.muted)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
        .disabled(busy)
    }

    private var ownerSection: some View {
        Section {
            FormTextField("Имя владельца *", text: $ownerName)
            fieldError("owner_name")
            FormTextField("Телефон владельца", text: $ownerPhone, prompt: "+7",
                          keyboard: .phonePad, autocapitalize: false)
            fieldError("owner_phone")
            FormTextField("Почта владельца", text: $ownerEmail, prompt: "owner@mail.ru",
                          keyboard: .emailAddress, autocapitalize: false)
            fieldError("owner_email")
        } header: {
            Text("Владелец — логин для входа")
        } footer: {
            Text("Телефон или почта (хотя бы одно) — по ним владелец входит в панель продавца на сайте и в приложение «Yumurta Seller».")
        }
        .onChange(of: ownerEmail) { value in
            // Письмо — только если указана почта (как в веб-форме).
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sendEmail = false }
        }
    }

    private var passwordSection: some View {
        Section {
            FormPicker("Пароль", selection: $pwMode, options: ShopCreateSheet.passwordModes)
            if pwMode == "own" {
                // Обычное поле, не «новый пароль»: иначе iOS предложит сохранить
                // его в Связку ключей этого телефона.
                TextField("минимум 6 символов", text: $password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            } else {
                Text("10 символов, без похожих букв — покажем после создания.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            fieldError("password")
            FormToggle("Если аккаунт с этим телефоном или почтой уже есть — задать ему новый пароль",
                       isOn: $resetPassword,
                       subtitle: "Без галочки пароль существующего аккаунта не меняется (даже если его нет — владелец задаст сам через «Забыли пароль»), его телефон и почта тоже не меняются. С галочкой прежние входы владельца завершатся, ему придёт уведомление о смене пароля. Аккаунты администраторов, курьеров и сотрудников других организаций не привязываются.")
        } header: {
            Text("Пароль")
        }
    }

    private var termsSection: some View {
        Section {
            FormDecimalField("Комиссия", text: $commission, suffix: "%")
            Text("У организаций Yumurta комиссии с продаж нет — оставьте 0.")
                .font(.caption)
                .foregroundColor(Brand.muted)
            fieldError("commission_percent")
            FormToggle("Опубликовать сразу", isOn: $publishNow,
                       subtitle: "Без галочки организация не видна клиентам: владелец заполнит её, вы опубликуете из очереди «Ждут публикации».")
            FormToggle("Отправить владельцу письмо со ссылкой на вход", isOn: $sendEmail,
                       subtitle: "Только если указана почта. В письме — логин и ссылка; пароля в письме нет, его передаёте вы.")
                .disabled(!hasEmail)
        } header: {
            Text("Публикация и условия")
        }
    }

    @ViewBuilder
    private func fieldError(_ key: String) -> some View {
        if let msg = fieldErrors[key] {
            Text(msg)
                .font(.caption)
                .foregroundColor(Brand.red)
        }
    }

    // MARK: - Отправка

    private func openShop(_ sid: Int) {
        onOpenShop(sid)
        dismiss()
    }

    /// Новый ключ повтора: [A-Za-z0-9_-], до 128 символов (apiIdemKey).
    static func newKey() -> String {
        "a76-ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Проверки до отправки — только то, что сервер всё равно отклонит.
    private func localErrors() -> [String: String] {
        var out: [String: String] = [:]
        if trim(name).isEmpty { out["name"] = "Укажите название" }
        if cityId == nil { out["city_id"] = "Выберите город" }
        if trim(ownerName).isEmpty { out["owner_name"] = "Укажите имя владельца" }
        if trim(ownerPhone).isEmpty && trim(ownerEmail).isEmpty {
            out["owner_phone"] = "Укажите телефон или почту владельца — это его логин"
        }
        if pwMode == "own" && password.isEmpty {
            out["password"] = "Введите пароль или выберите «Придумать автоматически»"
        }
        if commissionValue() == nil { out["commission_percent"] = "Комиссия — число от 0 до 100" }
        return out
    }

    /// Комиссия: пусто → 0; nil — не число или вне 0…100.
    private func commissionValue() -> Decimal? {
        let t = trim(commission)
        if t.isEmpty { return 0 }
        guard let d = Fmt.parseDecimal(t), d >= 0, d <= 100 else { return nil }
        return d
    }

    private func create() {
        guard !busy, result == nil else { return }
        error = nil
        existingShopId = nil
        let local = localErrors()
        fieldErrors = local
        if !local.isEmpty {
            error = "Проверьте отмеченные поля."
            Haptics.error()
            return
        }
        guard let cid = cityId else { return }
        let key = idemKey ?? ShopCreateSheet.newKey()
        idemKey = key
        let own = pwMode == "own"
        let body: [String: Any?] = [
            "name": trim(name),
            "type": type,
            "city_id": cid,
            "address": trim(address),
            "phone": trim(phone),
            "inn": trim(inn),
            "owner_name": trim(ownerName),
            "owner_phone": trim(ownerPhone),
            "owner_email": trim(ownerEmail),
            "password": own ? password : "",
            "generate_password": !own,
            "reset_password": resetPassword,
            "commission_percent": commissionValue() ?? 0,
            "publish_now": publishNow,
            "send_email": sendEmail && hasEmail,
            // Дубль ключа в теле: если хостинг срежет заголовок, сервер возьмёт
            // поле idempotency_key (apiIdemKey; при обоих действует заголовок).
            "idempotency_key": key,
        ]
        busy = true
        Task { @MainActor in
            do {
                let res = try await API.shared.postIdempotent("/api/admin/shops/create", body: body, key: key)
                busy = false
                idemKey = nil
                fieldErrors = [:]
                Haptics.success()
                result = ShopCredentials.fromCreate(res.data)
                onCreated()
            } catch {
                busy = false
                // Отмена: запрос мог дойти до сервера — ключ оставляем.
                if APIError.isCancellation(error) { return }
                Haptics.error()
                let e = (error as? APIError) ?? API.mapTransport(error)
                if ShopCreateSheet.isDefinitive(e) { idemKey = nil }
                apply(e)
            }
        }
    }

    /// Окончательный ли ответ (тогда следующий «Создать» — с новым ключом).
    /// Нет — сеть, 5xx, 429 и 409 «запрос уже выполняется»: исход неизвестен,
    /// повтор тем же ключом не создаст вторую организацию.
    static func isDefinitive(_ e: APIError) -> Bool {
        let s = e.status
        guard s >= 400 && s < 500, s != 429 else { return false }
        if s == 409 && e.message.contains("уже выполняется") { return false }
        return true
    }

    private func apply(_ e: APIError) {
        let fields = e.fieldErrors
        if e.status == 422 && fields.isEmpty && e.message.contains("Ключ повтора") {
            // idempotency_key_reused: этим ключом уже ушла другая версия формы (до
            // обрыва связи) и сервер её выполнил. Ключ уже сброшен.
            error = "Эта форма уже отправлялась, и сервер её обработал — возможно, организация уже создана. Проверьте список организаций; если её там нет — нажмите «Создать» ещё раз."
            onCreated()
            return
        }
        if e.status == 404 || e.status == 405 {
            // Старый сервер без волны А76 — ручки создания ещё нет.
            error = "Сервер ещё не поддерживает создание организаций из приложения — обновите сайт (волна А76) или добавьте организацию в веб-админке."
            return
        }
        switch e {
        case .validation(let m, let f):
            fieldErrors = f
            let other = f.keys.sorted().filter { !ShopCreateSheet.inlineFields.contains($0) }.compactMap { f[$0] }
            var text = f.isEmpty ? e.message : (m.isEmpty ? "Проверьте отмеченные поля." : m)
            if !other.isEmpty { text += "\n" + other.joined(separator: "\n") }
            error = text
        case .server(let status, let m, let details):
            // 409: такое название у владельца (+ existing_shop_id), телефон и почта
            // у разных аккаунтов, аккаунт заблокирован, создание уже идёт.
            fieldErrors = API.fieldErrors(details).filter { ShopCreateSheet.inlineFields.contains($0.key) }
            existingShopId = status == 409 ? details["existing_shop_id"].int : nil
            error = ShopCreateSheet.isDefinitive(e) ? m : m + "\nНажмите «Создать» ещё раз — повтор не создаст вторую организацию."
        case .offline, .badResponse:
            error = e.message + "\nНажмите «Создать» ещё раз — повтор не создаст вторую организацию."
        default:
            error = e.message
        }
    }
}
