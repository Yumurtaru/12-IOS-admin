import SwiftUI

/// Правка карточки организации: PUT /api/admin/shops/{id}.
///
/// Те же поля и правила, что в окне магазина веб-админки (admin.js editShop):
/// комиссия и её тип, комиссия за заказ (пусто = 19 ₽ по умолчанию), сервисный
/// сбор (процент или ₽ — второе значение уходит прежним), кто платит сбор,
/// отдельный сбор за кассу/киоск, тариф (только если тарифы включены в
/// настройках площадки), статус, заметка администратора. Плюс реквизиты,
/// которые сервер тоже принимает (название, адрес, телефон, e-mail, ИНН, форма,
/// режим, город) — они уходят, только если их поменяли.
///
/// Смена статуса, комиссии, сборов или тарифа (деньги с каждого заказа, видимость на
/// витрине) — только после подтверждения с перечнем «было → стало».
struct ShopEditView: View {
    let shop: JSON
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var commissionType: String
    @State private var commissionValue: String
    @State private var commissionFee: String
    @State private var feeType: String
    @State private var feeValue: String
    @State private var payer: String
    @State private var posEnabled: Bool
    @State private var posType: String
    @State private var posValue: String
    @State private var planId: String
    @State private var status: String
    @State private var note: String
    @State private var name: String
    @State private var address: String
    @State private var phone: String
    @State private var email: String
    @State private var inn: String
    @State private var orgType: String
    @State private var mode: String
    @State private var cityId: String
    @State private var cityName: String

    @State private var plansEnabled = false
    @State private var planOptions: [PickerOption] = []
    @State private var plansNote: String?

    init(shop: JSON, onSaved: @escaping () async -> Void) {
        self.shop = shop
        self.onSaved = onSaved
        let feeFixed = shop["service_fee_type"].string == "fixed"
        let posPercent = shop["pos_service_fee_type"].string == "percent"
        _commissionType = State(initialValue: shop["commission_type"].string == "fixed" ? "fixed" : "percent")
        _commissionValue = State(initialValue: Fmt.decimalInput(shop["commission_value"].decimal))
        _commissionFee = State(initialValue: Fmt.decimalInput(shop["commission_fee"].decimal))
        _feeType = State(initialValue: feeFixed ? "fixed" : "percent")
        let feeJSON = feeFixed ? shop["service_fee_fixed"] : shop["service_fee_percent"]
        _feeValue = State(initialValue: Fmt.decimalInput(feeJSON.decimal ?? 0))
        _payer = State(initialValue: shop["service_fee_payer"].string == "shop" ? "shop" : "client")
        _posEnabled = State(initialValue: shop["pos_service_fee_enabled"].boolValue)
        _posType = State(initialValue: posPercent ? "percent" : "fixed")
        let posJSON = posPercent ? shop["pos_service_fee_percent"] : shop["pos_service_fee_fixed"]
        _posValue = State(initialValue: Fmt.decimalInput(posJSON.decimal ?? 0))
        _planId = State(initialValue: shop["subscription_plan_id"].int.map { String($0) } ?? "")
        _status = State(initialValue: shop["status"].stringValue)
        _note = State(initialValue: shop["admin_note"].stringValue)
        _name = State(initialValue: shop["name"].stringValue)
        _address = State(initialValue: shop["address"].stringValue)
        _phone = State(initialValue: shop["phone"].stringValue)
        _email = State(initialValue: shop["email"].stringValue)
        _inn = State(initialValue: shop["inn"].stringValue)
        _orgType = State(initialValue: shop["org_type"].stringValue)
        _mode = State(initialValue: shop["mode"].stringValue)
        _cityId = State(initialValue: shop["city_id"].int.map { String($0) } ?? "")
        _cityName = State(initialValue: "")
    }

    private var shopId: Int { shop.id ?? 0 }
    private var hasPosFee: Bool { shop.object["pos_service_fee_enabled"] != nil }
    private var hasCommissionFee: Bool { shop.object["commission_fee"] != nil }

    // MARK: - Варианты

    private let rateTypes = [PickerOption(value: "percent", label: "%"), PickerOption(value: "fixed", label: "₽")]
    private let payers = [PickerOption(value: "client", label: "Клиент платит"),
                          PickerOption(value: "shop", label: "Магазин платит за клиента")]

    private var statusOptions: [PickerOption] {
        var list: [String] = []
        if !ShopsLabels.editableStatuses.contains(status) && !status.isEmpty { list.append(status) }
        let current = shop["status"].stringValue
        if !ShopsLabels.editableStatuses.contains(current) && !current.isEmpty && !list.contains(current) {
            list.append(current)
        }
        list.append(contentsOf: ShopsLabels.editableStatuses)
        return list.map { PickerOption(value: $0, label: ShopsLabels.status($0) + " (" + $0 + ")") }
    }

    private var modeOptions: [PickerOption] {
        var list = ["storefront", "shop", "restaurant"]
        if !mode.isEmpty && !list.contains(mode) { list.insert(mode, at: 0) }
        return list.map { PickerOption(value: $0, label: ShopsLabels.mode($0)) }
    }

    private var orgOptions: [PickerOption] {
        var list = ["ip", "ooo", "self_employed"]
        if !orgType.isEmpty && !list.contains(orgType) { list.insert(orgType, at: 0) }
        var out = list.map { PickerOption(value: $0, label: ShopsLabels.orgType($0)) }
        if orgType.isEmpty { out.insert(PickerOption(value: "", label: "—"), at: 0) }
        return out
    }

    // MARK: - Вид

    var body: some View {
        Form {
            commissionSection
            feeSection
            if hasPosFee { posSection }
            if plansEnabled { planSection }
            statusSection
            Section("Заметка администратора") {
                FormMultilineField("Видна только администраторам", text: $note, minHeight: 80)
            }
            requisitesSection
            Section {
                ActionButton("Сохранить", systemImage: "checkmark", style: .prominent,
                             confirm: saveConfirm, fullWidth: true) {
                    try await save()
                }
            }
        }
        .navigationTitle("Карточка")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPlans() }
    }

    private var commissionSection: some View {
        Section {
            HStack(alignment: .bottom) {
                FormDecimalField("Комиссия", text: $commissionValue, suffix: nil)
                Picker("", selection: $commissionType) {
                    ForEach(rateTypes) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
            if hasCommissionFee {
                FormDecimalField("Комиссия за заказ (пусто — по умолчанию 19 ₽)", text: $commissionFee, prompt: "19")
            }
        } header: {
            Text("Комиссия")
        } footer: {
            if commissionType == "percent" {
                Text("Процент больше 100 сервер урежет до 100.")
            }
        }
    }

    private var feeSection: some View {
        Section {
            HStack(alignment: .bottom) {
                FormDecimalField("Сервисный сбор", text: $feeValue, suffix: nil)
                Picker("", selection: $feeType) {
                    ForEach(rateTypes) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
            FormPicker("Кто платит", selection: $payer, options: payers)
        } header: {
            Text("Сервисный сбор")
        } footer: {
            if payer == "shop" {
                Text("Сервисный сбор будет списываться с баланса кошелька магазина. Убедитесь, что баланс достаточен.")
                    .foregroundColor(Brand.red)
            }
        }
    }

    private var posSection: some View {
        Section {
            FormToggle("Отдельный сбор за продажу через кассу/киоск", isOn: $posEnabled)
            HStack(alignment: .bottom) {
                FormDecimalField("Размер", text: $posValue, suffix: nil)
                Picker("", selection: $posType) {
                    ForEach(rateTypes) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
        } header: {
            Text("Касса и киоск")
        } footer: {
            Text("Заменяет обычный сбор для продаж через кассу и киоск. Списывается с кошелька магазина при завершении заказа.")
        }
    }

    private var planSection: some View {
        Section {
            FormPicker("Тариф", selection: $planId, options: planOptions)
        } header: {
            Text("Тариф")
        } footer: {
            Text("Смена тарифа заводит новую подписку на месяц без списания, старая закрывается.")
        }
    }

    private var statusSection: some View {
        Section {
            FormPicker("Статус", selection: $status, options: statusOptions)
        } header: {
            Text("Статус")
        } footer: {
            Text("Черновик и «ждёт публикации» публикуются только кнопкой «Опубликовать» в карточке — простое сохранение со статусом «active» их не опубликует. «blocked» убирает организацию с витрины, данные остаются.")
        }
    }

    private var requisitesSection: some View {
        Section {
            FormTextField("Название", text: $name)
            FormTextField("Адрес", text: $address)
            FormTextField("Телефон", text: $phone, keyboard: .phonePad, autocapitalize: false)
            FormTextField("E-mail", text: $email, keyboard: .emailAddress, autocapitalize: false)
            FormTextField("ИНН", text: $inn, keyboard: .numberPad, autocapitalize: false)
            FormPicker("Форма", selection: $orgType, options: orgOptions)
            FormPicker("Режим", selection: $mode, options: modeOptions)
            NavigationLink(destination: ShopCityPicker(cityId: $cityId, cityName: $cityName)) {
                HStack {
                    Text("Город")
                    Spacer()
                    Text(cityLabel).foregroundColor(Brand.muted)
                }
            }
        } header: {
            Text("Реквизиты")
        } footer: {
            Text("Уходят на сервер, только если изменены.")
        }
    }

    private var cityLabel: String {
        if !cityName.isEmpty { return cityName }
        if !cityId.isEmpty { return "id " + cityId }
        return "—"
    }

    // MARK: - Подтверждение

    /// Подтверждение, если менялись статус, комиссия, сборы или тариф (иначе nil — сразу).
    private var saveConfirm: ConfirmAction? {
        let list = sensitiveChanges
        guard !list.isEmpty else { return nil }
        let blocking = status == "blocked" && shop["status"].stringValue != "blocked"
        var msg = list.joined(separator: "\n")
        if blocking { msg += "\n\nОрганизация пропадёт с витрины у клиентов." }
        return ConfirmAction(title: "Сохранить изменения «" + shop["name"].stringValue + "»?", message: msg,
                             confirmLabel: "Сохранить", destructive: blocking)
    }

    /// Ставка для показа: «10 %» / «50 ₽»; пусто — «—».
    private static func rateText(_ v: Decimal?, type: String) -> String {
        guard let d = v else { return "—" }
        return type == "fixed" ? Fmt.money(d) : Fmt.number(d) + " %"
    }

    /// Число из поля для сравнения (пусто — 0, мусор — nil).
    private static func fieldNumber(_ text: String) -> Decimal? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        return Fmt.parseDecimal(t)
    }

    private static func same(_ a: Decimal?, _ b: Decimal?) -> Bool {
        (a ?? 0) == (b ?? 0)
    }

    private func planLabel(_ id: String) -> String {
        if id.isEmpty { return "без тарифа" }
        return planOptions.first(where: { $0.value == id })?.label ?? ("Тариф #" + id)
    }

    /// «Комиссия: 10 % → 12 %» — по каждому изменённому денежному/статусному полю.
    private var sensitiveChanges: [String] {
        var out: [String] = []
        let oldStatus = shop["status"].stringValue
        if status != oldStatus {
            out.append("Статус: " + ShopsLabels.status(oldStatus) + " → " + ShopsLabels.status(status))
        }
        let oldCType = shop["commission_type"].string == "fixed" ? "fixed" : "percent"
        let oldC = shop["commission_value"].decimal
        let newC = ShopEditView.fieldNumber(commissionValue)
        if oldCType != commissionType || !ShopEditView.same(oldC, newC) {
            out.append("Комиссия: " + ShopEditView.rateText(oldC, type: oldCType) + " → "
                       + (newC == nil ? commissionValue : ShopEditView.rateText(newC, type: commissionType)))
        }
        if hasCommissionFee {
            let oldF = shop["commission_fee"].decimal
            let t = commissionFee.trimmingCharacters(in: .whitespaces)
            let newF: Decimal? = t.isEmpty ? nil : Fmt.parseDecimal(t)
            let was = oldF.map { Fmt.money($0) } ?? "по умолчанию"
            let will = t.isEmpty ? "по умолчанию" : (newF.map { Fmt.money($0) } ?? t)
            if was != will {
                out.append("Комиссия за заказ: " + was + " → " + will)
            }
        }
        let oldFeeType = shop["service_fee_type"].string == "fixed" ? "fixed" : "percent"
        let oldFee = oldFeeType == "fixed" ? shop["service_fee_fixed"].decimal : shop["service_fee_percent"].decimal
        let newFee = ShopEditView.fieldNumber(feeValue)
        if oldFeeType != feeType || !ShopEditView.same(oldFee, newFee) {
            out.append("Сервисный сбор: " + ShopEditView.rateText(oldFee ?? 0, type: oldFeeType) + " → "
                       + (newFee == nil ? feeValue : ShopEditView.rateText(newFee, type: feeType)))
        }
        let oldPayer = shop["service_fee_payer"].string == "shop" ? "shop" : "client"
        if payer != oldPayer {
            out.append("Сбор платит: " + (oldPayer == "shop" ? "магазин" : "клиент") + " → " + (payer == "shop" ? "магазин" : "клиент"))
        }
        if hasPosFee {
            let oldOn = shop["pos_service_fee_enabled"].boolValue
            let oldPType = shop["pos_service_fee_type"].string == "percent" ? "percent" : "fixed"
            let oldP = oldPType == "percent" ? shop["pos_service_fee_percent"].decimal : shop["pos_service_fee_fixed"].decimal
            let newP = ShopEditView.fieldNumber(posValue)
            if oldOn != posEnabled {
                out.append("Сбор за кассу/киоск: " + (oldOn ? "включён" : "выключен") + " → " + (posEnabled ? "включён" : "выключен"))
            }
            if posEnabled && (oldPType != posType || !ShopEditView.same(oldP, newP)) {
                out.append("Размер сбора за кассу/киоск: " + ShopEditView.rateText(oldP ?? 0, type: oldPType) + " → "
                           + (newP == nil ? posValue : ShopEditView.rateText(newP, type: posType)))
            }
        }
        if plansEnabled {
            let oldPlan = shop["subscription_plan_id"].int.map { String($0) } ?? ""
            if planId != oldPlan {
                out.append("Тариф: " + planLabel(oldPlan) + " → " + planLabel(planId))
            }
        }
        return out
    }

    // MARK: - Загрузка и сохранение

    /// Тарифы показываем, только если они включены (настройка seller_plans_enabled).
    private func loadPlans() async {
        guard let settings = try? await API.shared.get("/api/admin/settings") else { return }
        guard settings["seller_plans_enabled"].string == "1" else { return }
        guard let plans = try? await API.shared.get("/api/admin/plans") else { return }
        var opts = [PickerOption(value: "", label: "—")]
        for p in plans.array {
            guard let pid = p["id"].string else { continue }
            let active = p["is_active"].isNull || p["is_active"].boolValue
            let label = p["name"].stringValue + (active ? "" : " (выключен)")
            if active || pid == planId { opts.append(PickerOption(value: pid, label: label)) }
        }
        if !planId.isEmpty && !opts.contains(where: { $0.value == planId }) {
            opts.append(PickerOption(value: planId, label: "Тариф #" + planId))
        }
        planOptions = opts
        plansEnabled = true
    }

    /// Число из поля: пусто → 0, мусор → ошибка с названием поля.
    private func number(_ text: String, _ field: String) throws -> Decimal {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        guard let d = Fmt.parseDecimal(t) else {
            throw APIError.validation("Проверьте число в поле «" + field + "»", fields: [:])
        }
        guard d >= 0 else {
            throw APIError.validation("Поле «" + field + "» не может быть отрицательным", fields: [:])
        }
        return d
    }

    private func buildBody() throws -> [String: Any?] {
        var out: [String: Any?] = [:]
        out["commission_value"] = try number(commissionValue, "Комиссия")
        out["commission_type"] = commissionType
        if hasCommissionFee {
            let feeText = commissionFee.trimmingCharacters(in: .whitespaces)
            if feeText.isEmpty {
                out["commission_fee"] = ""
            } else {
                out["commission_fee"] = try number(feeText, "Комиссия за заказ")
            }
        }
        let fee = try number(feeValue, "Сервисный сбор")
        let oldPercent = shop["service_fee_percent"].decimal ?? 0
        let oldFixed = shop["service_fee_fixed"].decimal ?? 0
        out["service_fee_type"] = feeType
        out["service_fee_percent"] = feeType == "percent" ? fee : oldPercent
        out["service_fee_fixed"] = feeType == "fixed" ? fee : oldFixed
        out["service_fee_payer"] = payer
        if hasPosFee {
            let pos = try number(posValue, "Сбор за кассу/киоск")
            let oldPosFixed = shop["pos_service_fee_fixed"].decimal ?? 0
            let oldPosPercent = shop["pos_service_fee_percent"].decimal ?? 0
            out["pos_service_fee_enabled"] = posEnabled ? 1 : 0
            out["pos_service_fee_type"] = posType
            out["pos_service_fee_fixed"] = posType == "fixed" ? pos : oldPosFixed
            out["pos_service_fee_percent"] = posType == "percent" ? pos : oldPosPercent
        }
        if plansEnabled {
            // "" → сервер ставит «без тарифа» (idOf('') = 0 → NULL).
            if let pid = Int(planId) {
                out["subscription_plan_id"] = pid
            } else {
                out["subscription_plan_id"] = ""
            }
        }
        out["status"] = status
        out["admin_note"] = note
        try addRequisites(&out)
        return out
    }

    /// Реквизиты — только изменённые.
    private func addRequisites(_ body: inout [String: Any?]) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != shop["name"].stringValue {
            guard !trimmedName.isEmpty else {
                throw APIError.validation("Название не может быть пустым", fields: [:])
            }
            body["name"] = trimmedName
        }
        let texts: [(String, String)] = [("address", address), ("phone", phone), ("email", email), ("inn", inn)]
        for (key, value) in texts {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v != shop[key].stringValue { body[key] = v }
        }
        if !orgType.isEmpty && orgType != shop["org_type"].stringValue { body["org_type"] = orgType }
        if !mode.isEmpty && mode != shop["mode"].stringValue { body["mode"] = mode }
        let oldCity = shop["city_id"].int.map { String($0) } ?? ""
        if cityId != oldCity, let cid = Int(cityId) { body["city_id"] = cid }
    }

    private func save() async throws {
        let body = try buildBody()
        try await API.shared.put("/api/admin/shops/" + String(shopId), body: body)
        await onSaved()
        dismiss()
    }
}

/// Выбор города для карточки: GET /api/admin/cities (поиск q).
struct ShopCityPicker: View {
    @Binding var cityId: String
    @Binding var cityName: String
    @StateObject private var model = PagedListModel(path: "/api/admin/cities")
    @Environment(\.dismiss) private var dismiss

    init(cityId: Binding<String>, cityName: Binding<String>) {
        _cityId = cityId
        _cityName = cityName
    }

    var body: some View {
        AdminListScreen("Город", model: model, searchPrompt: "Город или регион", emptyText: "Городов нет",
                        row: { city in cityRow(city) })
    }

    private func cityRow(_ city: JSON) -> some View {
        let cid = city["id"].stringValue
        let selected = cid == cityId
        return Button {
            cityId = cid
            cityName = city["name"].stringValue
            Haptics.tap()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(city["name"].stringValue).foregroundColor(Brand.text)
                    if let region = city["region"].nonEmptyString {
                        Text(region).font(.caption).foregroundColor(Brand.muted)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                }
            }
        }
    }
}
