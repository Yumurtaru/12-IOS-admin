import SwiftUI

/// Карточка заявки на регистрацию организации.
///
/// Отдельной ручки «заявка по id» на сервере нет: из списка карточка получает
/// строку целиком, а по deep link (`initial == nil`) ищет заявку в
/// GET /api/admin/registrations постранично (по 200, все статусы).
///
/// Действия (auth_seller.php):
///  * «Одобрить» — POST /api/admin/registrations/{id}/approve {plan_id,
///    commission_type, commission_value, service_fee_percent, service_fee_payer};
///    сервер создаёт организацию в статусе «не опубликована» и отвечает shop_id;
///  * «Запросить данные» — POST …/more-info {message};
///  * «Отклонить» — POST …/reject {reason}.
/// Отклонить и запросить данные сервер даёт только для pending/more_info_needed;
/// одобрить — всё, что ещё не одобрено.
struct RegistrationDetailView: View {
    let id: Int
    let model: PagedListModel?

    @State private var reg: JSON
    @State private var state: LoadState
    @State private var showApprove = false
    @State private var showMoreInfo = false
    @State private var showReject = false
    @State private var createdShopId: Int?

    init(id: Int, initial: JSON?, model: PagedListModel?) {
        self.id = id
        self.model = model
        let start = initial ?? .null
        _reg = State(initialValue: start)
        _state = State(initialValue: start.isNull ? .idle : .loaded)
    }

    private var status: String { reg["status"].stringValue }
    private var name: String { reg["shop_name"].nonEmptyString ?? ("Заявка #" + String(id)) }
    private var canDecide: Bool { status == "pending" || status == "more_info_needed" }

    var body: some View {
        AsyncContent(state: state, emptyText: "Заявка не найдена", emptySymbol: "doc.text.magnifyingglass",
                     retry: { await find() }) {
            content
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if state == .idle { await find() } }
        .sheet(isPresented: $showApprove) {
            RegistrationApproveSheet(regId: id, regName: name) { result in
                applyApproved(result)
            }
        }
        .sheet(isPresented: $showMoreInfo) {
            TextInputSheet(title: "Запросить данные",
                           message: "Что нужно уточнить? Текст уйдёт заявителю на почту.",
                           placeholder: "Например: пришлите ИНН и адрес точки",
                           multiline: true, submitTitle: "Отправить запрос") { text in
                try await API.shared.post("/api/admin/registrations/" + String(id) + "/more-info", body: ["message": text])
                applyDecision(status: "more_info_needed", note: text)
            }
        }
        .sheet(isPresented: $showReject) {
            TextInputSheet(title: "Отклонить заявку",
                           message: "Причина отказа уйдёт заявителю на почту.",
                           placeholder: "Например: деятельность не подходит площадке",
                           multiline: true, submitTitle: "Отклонить", destructive: true) { text in
                try await API.shared.post("/api/admin/registrations/" + String(id) + "/reject", body: ["reason": text])
                applyDecision(status: "rejected", note: text)
            }
        }
    }

    private var content: some View {
        List {
            headerSection
            if let shopId = createdShopId {
                Section {
                    NavigationLink(destination: ShopDetailView(id: shopId)) {
                        Label("Открыть созданную организацию", systemImage: "building.2")
                    }
                } footer: {
                    Text("Организация создана неопубликованной: продавец наполнит её и отправит на проверку — она появится во вкладке «Публикация».")
                }
            }
            if status != "approved" {
                actionsSection
            }
            RegistrationOrgSection(reg: reg)
            RegistrationApplicantSection(reg: reg)
            RegistrationDocumentsSection(reg: reg)
            Section {
                JSONInspectorView(reg)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    StatusBadge(status: status, label: ShopsLabels.registrationStatus(status))
                    StatusBadge(ShopsLabels.registrationType(reg["shop_type"].string), color: Brand.blue)
                }
                Text("Подана " + Fmt.date(reg["created_at"].string) + " · #" + String(id))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            .padding(.vertical, 4)
            if let note = reg["admin_note"].nonEmptyString {
                InfoBanner((status == "rejected" ? "Причина отказа: " : "Комментарий администратора: ") + note,
                           systemImage: "text.bubble", color: status == "rejected" ? Brand.red : Brand.amber)
            }
            if let reviewed = reg["reviewed_at"].nonEmptyString {
                KVRow("Рассмотрена", Fmt.date(reviewed))
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                showApprove = true
            } label: {
                Label("Одобрить", systemImage: "checkmark.circle")
            }
            if canDecide {
                Button {
                    showMoreInfo = true
                } label: {
                    Label("Запросить данные", systemImage: "questionmark.bubble")
                }
                Button(role: .destructive) {
                    showReject = true
                } label: {
                    Label("Отклонить", systemImage: "xmark.circle")
                }
            }
        } header: {
            Text("Решение")
        } footer: {
            Text("При одобрении создаётся организация с выбранной комиссией; витрина откроется после публикации.")
        }
    }

    // MARK: - Действия

    private func applyDecision(status newStatus: String, note: String) {
        reg = ShopsLabels.patched(reg, ["status": .string(newStatus), "admin_note": .string(note),
                                        "reviewed_at": .string(Fmt.serverDateTime(Date()))])
        afterAction()
    }

    private func applyApproved(_ result: JSON) {
        reg = ShopsLabels.patched(reg, ["status": .string("approved"),
                                        "reviewed_at": .string(Fmt.serverDateTime(Date()))])
        createdShopId = result["shop_id"].int
        afterAction()
    }

    private func afterAction() {
        let m = model
        Task { await m?.refresh() }
        Task { await Notifier.shared.refresh(force: true) }
    }

    /// Поиск заявки по id (deep link): все статусы, по 200 на страницу, не больше 25 страниц.
    private func find() async {
        if reg.isNull { state = .loading }
        var page = 1
        while page <= 25 {
            do {
                let q: [String: String?] = ["page": String(page), "per": "200"]
                let data = try await API.shared.get("/api/admin/registrations", query: q)
                let items = data["items"].array
                if let hit = items.first(where: { $0.id == id }) {
                    reg = hit
                    state = .loaded
                    return
                }
                let pages = data["pages"].int ?? 1
                if items.isEmpty || page >= pages { break }
                page += 1
            } catch {
                if APIError.isCancellation(error) { return }
                state = reg.isNull ? .failed(APIError.describe(error)) : .loaded
                return
            }
        }
        state = reg.isNull ? .empty("Заявка #" + String(id) + " не найдена") : .loaded
    }
}

/// Данные организации из заявки.
struct RegistrationOrgSection: View {
    let reg: JSON

    var body: some View {
        Section {
            KVRow("Форма", ShopsLabels.orgType(reg["org_type"].string))
            KVRow("ИНН", reg["inn"].string, copyable: true)
            RegistrationPhoneRow(title: "Телефон", phone: reg["phone"].string)
            KVRow("E-mail", reg["email"].string, copyable: true)
            KVRow("Город", reg["city_name"].string)
            if let d = reg["description"].nonEmptyString {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle("Описание")
                    Text(d).font(.subheadline)
                }
            }
        } header: {
            Text("Организация")
        }
    }
}

/// Заявитель (владелец будущей организации).
struct RegistrationApplicantSection: View {
    let reg: JSON

    var body: some View {
        Section {
            if let uid = reg["user_id"].int {
                NavigationLink(destination: UserDetailView(id: uid)) {
                    KVRow("Имя", reg["owner_name"].string)
                }
            } else {
                KVRow("Имя", reg["owner_name"].string)
            }
            RegistrationPhoneRow(title: "Телефон", phone: reg["owner_phone"].string)
        } header: {
            Text("Заявитель")
        }
    }
}

/// Телефон: нажатие — звонок.
struct RegistrationPhoneRow: View {
    let title: String
    let phone: String?

    var body: some View {
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) {
                HStack {
                    Text(title).foregroundColor(Brand.muted)
                    Spacer()
                    Text(Fmt.phone(phone))
                }
                .font(.subheadline)
            }
        } else {
            KVRow(title, phone)
        }
    }
}

/// Документы заявки (documents_json — строка JSON или объект): ссылки на файлы и всё содержимое.
struct RegistrationDocumentsSection: View {
    let reg: JSON

    private var docs: JSON {
        let raw = reg["documents_json"]
        if let s = raw.string, let parsed = JSON.parse(Data(s.utf8)) { return parsed }
        return raw
    }

    /// Все строки, похожие на путь к файлу или ссылку.
    private var links: [RegistrationFileLink] {
        var out: [RegistrationFileLink] = []
        RegistrationDocumentsSection.collect(docs, key: "Файл", into: &out)
        return out
    }

    private static func collect(_ j: JSON, key: String, into out: inout [RegistrationFileLink]) {
        switch j {
        case .string(let s):
            let looksLikeFile = s.hasPrefix("/") || s.hasPrefix("http://") || s.hasPrefix("https://")
            if looksLikeFile, let url = API.absoluteURL(s) {
                out.append(RegistrationFileLink(id: out.count, title: key, url: url))
            }
        case .array(let a):
            for (i, x) in a.enumerated() { collect(x, key: key + " " + String(i + 1), into: &out) }
        case .object(let o):
            for k in o.keys.sorted() { collect(o[k] ?? .null, key: k, into: &out) }
        default:
            break
        }
    }

    var body: some View {
        if docs.isObject || docs.isArray {
            Section {
                ForEach(links) { l in
                    Link(destination: l.url) {
                        Label(l.title, systemImage: "doc")
                    }
                }
                JSONInspectorView(docs, title: "Содержимое", expanded: links.isEmpty)
            } header: {
                Text("Документы заявки")
            }
        }
    }
}

/// Ссылка на файл из заявки.
struct RegistrationFileLink: Identifiable {
    let id: Int
    let title: String
    let url: URL
}

/// Одобрение заявки: комиссия, сервисный сбор, кто платит, тариф (если тарифы
/// включены). Значения по умолчанию — из настроек площадки (GET /api/admin/settings:
/// default_commission_type/value, default_service_fee_percent/payer).
struct RegistrationApproveSheet: View {
    let regId: Int
    let regName: String
    let onApproved: (JSON) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var commissionType = "percent"
    @State private var commissionValue = "10"
    @State private var feePercent = "0"
    @State private var payer = "client"
    @State private var planId = ""
    @State private var planOptions: [PickerOption] = []
    @State private var loadingDefaults = true
    @State private var busy = false
    @State private var error: String?

    init(regId: Int, regName: String, onApproved: @escaping (JSON) -> Void) {
        self.regId = regId
        self.regName = regName
        self.onApproved = onApproved
    }

    private var typeOptions: [PickerOption] {
        [PickerOption(value: "percent", label: "%"), PickerOption(value: "fixed", label: "₽")]
    }

    private var payerOptions: [PickerOption] {
        [PickerOption(value: "client", label: "Клиент платит"), PickerOption(value: "shop", label: "Магазин платит за клиента")]
    }

    var body: some View {
        NavigationStack {
            Form {
                if loadingDefaults {
                    Section {
                        HStack { ProgressView(); Text("Загружаю условия по умолчанию…").foregroundColor(Brand.muted) }
                    }
                }
                Section {
                    HStack(alignment: .bottom) {
                        FormDecimalField("Комиссия", text: $commissionValue, suffix: nil)
                        Picker("", selection: $commissionType) {
                            ForEach(typeOptions) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)
                    }
                    FormDecimalField("Сервисный сбор", text: $feePercent, suffix: "%")
                    FormPicker("Кто платит сбор", selection: $payer, options: payerOptions)
                    if !planOptions.isEmpty {
                        FormPicker("Тариф", selection: $planId, options: planOptions)
                    }
                } header: {
                    Text("Условия для «" + regName + "»")
                } footer: {
                    Text("Организация будет создана неопубликованной. Владельцу уйдёт письмо со ссылкой на панель.")
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Одобрить").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("Одобрить заявку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
            .task { await loadDefaults() }
        }
        .interactiveDismissDisabled(busy)
    }

    private func loadDefaults() async {
        defer { loadingDefaults = false }
        guard let s = try? await API.shared.get("/api/admin/settings") else { return }
        if s["default_commission_type"].string == "fixed" { commissionType = "fixed" }
        if let v = s["default_commission_value"].decimal { commissionValue = Fmt.decimalInput(v) }
        if let f = s["default_service_fee_percent"].decimal { feePercent = Fmt.decimalInput(f) }
        if s["default_service_fee_payer"].string == "shop" { payer = "shop" }
        guard s["seller_plans_enabled"].string == "1" else { return }
        guard let plans = try? await API.shared.get("/api/admin/plans") else { return }
        var opts = [PickerOption(value: "", label: "Без тарифа")]
        for p in plans.array where p["is_active"].isNull || p["is_active"].boolValue {
            if let pid = p["id"].string { opts.append(PickerOption(value: pid, label: p["name"].stringValue)) }
        }
        planOptions = opts
    }

    private func submit() {
        guard !busy else { return }
        guard let value = Fmt.parseDecimal(commissionValue.trimmingCharacters(in: .whitespaces)), value >= 0 else {
            error = "Проверьте комиссию: нужно неотрицательное число"
            return
        }
        guard let fee = Fmt.parseDecimal(feePercent.trimmingCharacters(in: .whitespaces)), fee >= 0, fee <= 100 else {
            error = "Сервисный сбор — процент от 0 до 100"
            return
        }
        busy = true
        error = nil
        var payload: [String: Any?] = [
            "commission_type": commissionType,
            "commission_value": value,
            "service_fee_percent": fee,
            "service_fee_payer": payer,
        ]
        if let pid = Int(planId) { payload["plan_id"] = pid }
        let sendBody = payload
        let path = "/api/admin/registrations/" + String(regId) + "/approve"
        let done = onApproved
        Task { @MainActor in
            do {
                let res = try await API.shared.post(path, body: sendBody)
                Haptics.success()
                busy = false
                done(res)
                dismiss()
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
