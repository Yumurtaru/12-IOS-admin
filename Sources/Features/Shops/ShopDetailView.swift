import SwiftUI

/// Карточка организации: GET /api/admin/shops/{id}.
///
/// Всё, что показывает окно магазина в веб-админке: показатели и финансы,
/// реквизиты и владелец, условия (комиссия, сборы, тариф, статус, заметка) с
/// правкой, кошелёк (пополнение, история), публикация (если ждёт), витрина,
/// удаление с подтверждением названием и паролем/кодом 2FA.
///
/// «Войти в кабинет магазина» (П-29.6): POST /api/admin/shops/{id}/enter-ticket →
/// {url, expires_in, expires_at, name} — одноразовая ссылка на 60 с; открываем её
/// сразу в Safari, там у браузера своя сессия администратора в кабинете этой
/// организации (4 часа). Прежний POST …/enter не годится: он отмечает вход в
/// сессии приложения, а не браузера. Не вышло (старый сервер) — в ошибке есть
/// кнопка «Открыть веб-админку», как было раньше.
struct ShopDetailView: View {
    let id: Int
    let onDeleted: ((Int) -> Void)?

    @StateObject private var loader: ObjectLoader
    @Environment(\.dismiss) private var dismiss
    @State private var showTopup = false
    @State private var showReject = false
    @State private var deletePreview: ShopDeletePreview?
    @State private var previewLoading = false
    @State private var previewError: String?
    @State private var deletedText: String?
    @State private var pendingDeletedText: String?
    @State private var enterBusy = false
    @State private var enterError: String?
    @State private var showOwnerPassword = false
    @Environment(\.openURL) private var openURL

    init(id: Int, onDeleted: ((Int) -> Void)? = nil) {
        self.id = id
        self.onDeleted = onDeleted
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/shops/" + String(id)))
    }

    private var shop: JSON { loader.data }
    private var name: String { shop["name"].nonEmptyString ?? ("Магазин #" + String(id)) }
    private var status: String { shop["status"].stringValue }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Организация не найдена", retry: { await loader.load() }) {
            content
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
        .sheet(isPresented: $showTopup) {
            ShopTopupSheet(shopId: id, shopName: name) { _ in
                await loader.load()
            }
        }
        .sheet(isPresented: $showReject) {
            TextInputSheet(title: "На доработку",
                           message: "Что нужно исправить в «" + name + "»? Текст увидит продавец в панели.",
                           placeholder: "Например: добавьте фото и часы работы",
                           multiline: true, submitTitle: "Вернуть на доработку", minLength: 5,
                           destructive: true) { text in
                try await API.shared.post("/api/admin/shops/" + String(id) + "/publish-reject", body: ["note": text])
                await loader.load()
                Task { await Notifier.shared.refresh(force: true) }
            }
        }
        .sheet(item: $deletePreview, onDismiss: {
            // Алерт — только после закрытия листа: иначе iOS 16 может его не показать.
            if let t = pendingDeletedText {
                pendingDeletedText = nil
                deletedText = t
            }
        }) { pv in
            ShopDeleteSheet(shopId: id, shopName: name, preview: pv.data) { result in
                pendingDeletedText = result
            }
        }
        // Волна А76: «Выдать новый пароль». После закрытия — перечитать карточку
        // (has_password мог смениться).
        .sheet(isPresented: $showOwnerPassword, onDismiss: { Task { await loader.load() } }) {
            ShopOwnerPasswordSheet(shopId: id, shopName: name, ownerName: shop["owner"]["name"].nonEmptyString)
        }
        .alert("Организация удалена", isPresented: deletedShown) {
            Button("OK") {
                onDeleted?(id)
                dismiss()
            }
        } message: {
            Text(deletedText ?? "")
        }
        .alert("Не получилось", isPresented: previewErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(previewError ?? "")
        }
        .alert("Не удалось войти в кабинет", isPresented: enterErrorShown) {
            // Запасной путь, как раньше: веб-админка, где «В панель» работает в браузере.
            if let url = ShopsLabels.webAdminShopsURL {
                Button("Открыть веб-админку") { openURL(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(enterError ?? "")
        }
    }

    private var enterErrorShown: Binding<Bool> {
        Binding(get: { enterError != nil }, set: { if !$0 { enterError = nil } })
    }

    private var deletedShown: Binding<Bool> {
        Binding(get: { deletedText != nil }, set: { if !$0 { deletedText = nil } })
    }

    private var previewErrorShown: Binding<Bool> {
        Binding(get: { previewError != nil }, set: { if !$0 { previewError = nil } })
    }

    private var content: some View {
        List {
            if let e = loader.lastRefreshError {
                Section { ErrorBanner(message: e, retry: { Task { await loader.load() } }) }
            }
            ShopDetailHeaderSection(shop: shop)
            if status == "review" || status == "draft" {
                publishSection
            }
            ShopDetailStatsSection(shop: shop)
            ShopDetailOwnerSection(shop: shop)
            if ShopOwnerAccessSection.supported(shop) {
                ShopOwnerAccessSection(shop: shop, onResetPassword: { showOwnerPassword = true })
            }
            termsSection
            walletSection
            moreSection
            Section {
                JSONInspectorView(shop)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    // MARK: - Публикация

    private var publishSection: some View {
        Section {
            ActionButton("Опубликовать", systemImage: "checkmark.seal", style: .prominent,
                         confirm: ConfirmAction(title: "Опубликовать «" + name + "»?",
                                                message: "Организация появится на сайте и в мобильных приложениях, а клиенты города получат уведомление.",
                                                confirmLabel: "Опубликовать"),
                         fullWidth: true) {
                try await API.shared.post("/api/admin/shops/" + String(id) + "/publish", body: [:])
                await loader.load()
                Task { await Notifier.shared.refresh(force: true) }
            }
            if status == "review" {
                Button(role: .destructive) {
                    showReject = true
                } label: {
                    Label("Вернуть на доработку", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text(status == "review" ? "Ждёт публикации" : "Не опубликована")
        } footer: {
            Text(status == "review"
                 ? "Продавец заполнил организацию и отправил на проверку. Посмотрите товары, услуги и настройки — и опубликуйте или верните с замечанием."
                 : "Продавец ещё заполняет организацию. Опубликовать можно и сейчас, не дожидаясь его.")
        }
    }

    // MARK: - Условия

    private var termsSection: some View {
        Section {
            KVRow("Комиссия", ShopsLabels.rate(shop["commission_value"], type: shop["commission_type"].string))
            if shop.object["commission_fee"] != nil {
                KVRow("Комиссия за заказ", shop["commission_fee"].isNull ? "по умолчанию (19 ₽)" : Fmt.money(shop["commission_fee"]))
            }
            KVRow("Сервисный сбор", serviceFeeText)
            KVRow("Платит сбор", shop["service_fee_payer"].string == "shop" ? "Магазин за клиента" : "Клиент")
            if shop.object["pos_service_fee_enabled"] != nil {
                KVRow("Сбор за кассу/киоск", posFeeText)
            }
            if shop["subscription_plan_id"].int != nil {
                KVRow("Тариф (id)", shop["subscription_plan_id"].string)
            }
            if let note = shop["admin_note"].nonEmptyString {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle("Заметка администратора")
                    Text(note).font(.subheadline)
                }
            }
            NavigationLink(destination: ShopEditView(shop: shop, onSaved: { await loader.load() })) {
                Label("Изменить карточку", systemImage: "pencil")
            }
        } header: {
            Text("Условия и статус")
        }
    }

    private var serviceFeeText: String {
        if shop["service_fee_type"].string == "fixed" {
            return Fmt.money(shop["service_fee_fixed"])
        }
        return Fmt.number(shop["service_fee_percent"]) + " %"
    }

    private var posFeeText: String {
        guard shop["pos_service_fee_enabled"].boolValue else { return "выключен" }
        if shop["pos_service_fee_type"].string == "percent" {
            return Fmt.number(shop["pos_service_fee_percent"]) + " %"
        }
        return Fmt.money(shop["pos_service_fee_fixed"])
    }

    // MARK: - Кошелёк

    private var walletSection: some View {
        Section {
            HStack {
                Text("Баланс").foregroundColor(Brand.muted)
                Spacer()
                Text(Fmt.money(shop["balance"]))
                    .font(.headline.monospacedDigit())
                    .foregroundColor((shop["balance"].decimal ?? 0) < 500 ? Brand.red : Brand.text)
            }
            Button {
                showTopup = true
            } label: {
                Label("Пополнить кошелёк", systemImage: "plus.circle")
            }
            NavigationLink(destination: ShopWalletHistoryView(shopId: id, shopName: name)) {
                Label("Вся история кошелька", systemImage: "list.bullet")
            }
            ForEach(Array(shop["wallet_recent"].array.enumerated()), id: \.offset) { pair in
                ShopWalletTxRow(tx: pair.element)
            }
        } header: {
            Text("Кошелёк")
        } footer: {
            if shop["wallet_recent"].array.isEmpty {
                Text("Движений по кошельку нет")
            } else {
                Text("Последние движения")
            }
        }
    }

    // MARK: - Ещё

    private var moreSection: some View {
        Section {
            // Переписка с организацией (раздел «Сообщения продавцам»): чат открывается
            // и без прежней переписки — первое сообщение её создаст.
            NavigationLink(destination: ShopSupportChatView(shopId: id)) {
                Label("Написать организации", systemImage: "bubble.left.and.bubble.right")
            }
            if let url = ShopsLabels.storefrontURL(slug: shop["slug"].string) {
                Link(destination: url) {
                    Label("Витрина на сайте", systemImage: "storefront")
                }
            }
            // П-29.6: одноразовая ссылка входа в кабинет — вместо ссылки на веб-админку.
            Button {
                enterCabinet()
            } label: {
                HStack {
                    Label("Войти в кабинет магазина", systemImage: "rectangle.portrait.and.arrow.right")
                    if enterBusy {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(enterBusy)
            Button(role: .destructive) {
                loadDeletePreview()
            } label: {
                HStack {
                    Label("Удалить организацию", systemImage: "trash")
                    if previewLoading {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(previewLoading)
        } header: {
            Text("Действия")
        } footer: {
            Text("«Войти в кабинет магазина» откроет кабинет этой организации в Safari. Ссылка одноразовая и живёт 60 секунд; вход в браузере действует 4 часа. Если нужно лишь убрать организацию с витрины — поставьте статус «Заблокирована» вместо удаления.")
        }
    }

    /// POST …/enter-ticket и сразу открыть ссылку в Safari (она живёт 60 с).
    private func enterCabinet() {
        guard !enterBusy else { return }
        enterBusy = true
        let path = "/api/admin/shops/" + String(id) + "/enter-ticket"
        Task { @MainActor in
            do {
                let r = try await API.shared.post(path)
                enterBusy = false
                if let url = ShopDetailView.ticketURL(r["url"].string) {
                    openURL(url)
                } else {
                    enterError = "Сервер не выдал ссылку для входа. Повторите позже."
                }
            } catch {
                enterBusy = false
                if !APIError.isCancellation(error) {
                    enterError = APIError.describe(error)
                }
            }
        }
    }

    /// Адрес из ответа: полный http(s) или путь сайта «/admin/enter?ticket=…».
    static func ticketURL(_ raw: String?) -> URL? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("https://") || s.hasPrefix("http://") { return URL(string: s) }
        if s.hasPrefix("/") { return URL(string: API.baseURL.absoluteString + s) }
        return nil
    }

    private func loadDeletePreview() {
        guard !previewLoading else { return }
        previewLoading = true
        let path = "/api/admin/shops/" + String(id) + "/delete-preview"
        Task { @MainActor in
            do {
                let data = try await API.shared.get(path)
                previewLoading = false
                deletePreview = ShopDeletePreview(data: data)
            } catch {
                previewLoading = false
                if !APIError.isCancellation(error) {
                    previewError = APIError.describe(error)
                }
            }
        }
    }
}

/// Шапка карточки: название, статус, режим, тип, замечание продавцу.
struct ShopDetailHeaderSection: View {
    let shop: JSON

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                if let logo = shop["logo"].nonEmptyString {
                    AsyncImageView(path: logo, size: 54)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(shop["name"].nonEmptyString ?? "Без названия")
                        .font(.title3.weight(.semibold))
                    HStack(spacing: 6) {
                        StatusBadge(ShopsLabels.status(shop["status"].string),
                                    color: ShopsLabels.statusColor(shop["status"].string))
                        StatusBadge(ShopsLabels.mode(shop["mode"].string), color: Brand.blue)
                    }
                    Text(ShopsLabels.type(shop["type"].string) + " · #" + shop["id"].stringValue)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            .padding(.vertical, 4)
            if let note = shop["publish_note"].nonEmptyString {
                InfoBanner("Замечание продавцу: " + note, systemImage: "text.bubble", color: Brand.amber)
            }
        }
    }
}

/// Показатели и финансы (stats из ответа сервера) — сеткой, как на сайте.
struct ShopDetailStatsSection: View {
    let shop: JSON

    private var st: JSON { shop["stats"] }
    private var columns: [GridItem] { [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)] }

    private var ratingText: String {
        let r = st["rating"].double ?? 0
        return String(format: "%.2f ★", r)
    }

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 8) {
                // Group — не больше 10 элементов в одном блоке ViewBuilder.
                Group {
                    ShopsMetricTile("Баланс кошелька", Fmt.money(shop["balance"]),
                                    tint: (shop["balance"].decimal ?? 0) < 500 ? Brand.red : nil)
                    ShopsMetricTile("Пополнено всего", Fmt.money(st["topped_up"]))
                    ShopsMetricTile("Списано комиссий", Fmt.money(st["commission_charged"]))
                    ShopsMetricTile("Списано сборов", Fmt.money(st["service_fee_charged"]))
                    ShopsMetricTile("Возвращено комиссий", Fmt.money(st["commission_refunded"]))
                    ShopsMetricTile("Чистый доход площадки", Fmt.money(st["commission_net"]))
                    ShopsMetricTile("Заказов оплачено", Fmt.number(st["charged_orders"]))
                    ShopsMetricTile("Ожидает списания", Fmt.money(st["pending_charge"]))
                    ShopsMetricTile("GMV", Fmt.money(st["gmv"]))
                }
                Group {
                    ShopsMetricTile("Заказов", Fmt.number(st["orders"]), sub: lastOrder)
                    ShopsMetricTile("Средний чек", Fmt.money(st["avg_check"]))
                    ShopsMetricTile("Рейтинг", ratingText, sub: Fmt.plural(st["reviews_count"].intValue, "отзыв", "отзыва", "отзывов"))
                    ShopsMetricTile("Товаров", Fmt.number(st["products"]))
                    ShopsMetricTile("Услуг", Fmt.number(st["services"]))
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Показатели")
        }
    }

    private var lastOrder: String? {
        guard let s = st["last_order"].nonEmptyString else { return nil }
        return "последний " + Fmt.date(s)
    }
}

/// Реквизиты и владелец.
struct ShopDetailOwnerSection: View {
    let shop: JSON

    private var owner: JSON { shop["owner"] }

    var body: some View {
        Section {
            KVRow("Форма", ShopsLabels.orgType(shop["org_type"].string))
            KVRow("ИНН", shop["inn"].string, copyable: true)
            KVRow("Адрес", shop["address"].string, copyable: true)
            phoneRow("Телефон", shop["phone"].string)
            KVRow("E-mail", shop["email"].string, copyable: true)
            if let created = shop["created_at"].nonEmptyString {
                KVRow("На площадке с", Fmt.day(created))
            }
            if let pub = shop["published_at"].nonEmptyString {
                KVRow("Опубликована", Fmt.date(pub))
            }
            if owner.isObject {
                ownerRow
            }
        } header: {
            Text("Реквизиты и владелец")
        }
    }

    @ViewBuilder
    private var ownerRow: some View {
        if let uid = owner["id"].int {
            NavigationLink(destination: UserDetailView(id: uid)) {
                ownerLabel
            }
        } else {
            ownerLabel
        }
        // Волна А76: у аккаунта только с почтой phone — заглушка «o:…», не номер;
        // сервер отдаёт настоящий в login_phone (старый сервер — ключа нет).
        phoneRow("Телефон владельца", owner.object["login_phone"] != nil ? owner["login_phone"].string : owner["phone"].string)
        KVRow("E-mail владельца", owner["email"].string, copyable: true)
    }

    private var ownerLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            FieldTitle("Владелец")
            Text(owner["name"].nonEmptyString ?? "—")
        }
    }

    @ViewBuilder
    private func phoneRow(_ title: String, _ phone: String?) -> some View {
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

/// Предпросмотр удаления (для .sheet(item:)).
struct ShopDeletePreview: Identifiable {
    let id = UUID()
    let data: JSON
}
