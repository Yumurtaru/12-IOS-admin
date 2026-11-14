import SwiftUI

/// Одно поле настроек «Курьеры Yumurta» (как «Настройки» в admin/assets/js/admin-pool.js).
/// `key` — ключ POST /api/admin/pool/settings (pool_*); в ответе GET/POST то же поле называется
/// без префикса (enabled, commission_value, …), цены кузовов лежат в cargo_prices.{s,m,l,xl,xxl}.
struct PoolSettingField: Identifiable {
    enum Kind {
        case toggle
        case int
        case decimal
        case choice([PickerOption])
    }

    let key: String
    let title: String
    let hint: String?
    let kind: Kind
    let suffix: String?

    var id: String { key }

    init(_ key: String, _ title: String, _ kind: Kind, hint: String? = nil, suffix: String? = nil) {
        self.key = key
        self.title = title
        self.kind = kind
        self.hint = hint
        self.suffix = suffix
    }

    /// Значение в ответе сервера.
    func read(_ cfg: JSON) -> JSON {
        if key.hasPrefix("pool_price_") {
            return cfg["cargo_prices"][String(key.dropFirst("pool_price_".count))]
        }
        return cfg[String(key.dropFirst("pool_".count))]
    }
}

/// Блок полей настроек с заголовком и пояснением (порядок и тексты — как на сайте).
struct PoolSettingGroup: Identifiable {
    let title: String?
    let note: String?
    let fields: [PoolSettingField]

    var id: String { title ?? "main" }

    static let commissionTypes: [PickerOption] = [
        PickerOption(value: "fixed", label: "Рублей за доставку"),
        PickerOption(value: "percent", label: "Процент от цены доставки"),
    ]

    static let all: [PoolSettingGroup] = [
        PoolSettingGroup(title: nil, note: nil, fields: [
            PoolSettingField("pool_enabled", "Курьеры Yumurta включены", .toggle,
                             hint: "Заведения могут вызывать курьеров, курьеры — подавать заявки."),
        ]),
        PoolSettingGroup(title: "Комиссия площадки с курьерской доставки", note: nil, fields: [
            PoolSettingField("pool_commission_type", "Тип", .choice(commissionTypes)),
            PoolSettingField("pool_commission_value", "Размер", .decimal,
                             hint: "0 — без комиссии. Без кошелька комиссия копится долгом курьера перед площадкой; получили — отметьте поправкой в карточке курьера.",
                             suffix: "₽ / %"),
            PoolSettingField("pool_commission_wallet", "Списывать комиссию из кошелька курьера", .toggle,
                             hint: "Курьер пополняет кошелёк онлайн (ЮKassa), комиссия списывается сразу после «Доставил». Не хватило — остаток долгом, и новых заказов нет, пока не пополнит. Нужна включённая ЮKassa. Внимание: при включении уже накопленный долг по комиссии тоже спишется из кошелька (это тот же кошелёк Yumurta, что у покупателя), а курьер без денег на нём перестанет получать заказы до пополнения."),
            PoolSettingField("pool_wallet_min", "Не меньше на балансе, чтобы получать заказы", .decimal,
                             hint: "0 — без порога. Например, 300 — курьер с меньшим балансом заказов не получает.",
                             suffix: "₽"),
        ]),
        PoolSettingGroup(title: "Деньги на руках у курьера", note: nil, fields: [
            PoolSettingField("pool_debt_limit", "Лимит долга курьера", .decimal,
                             hint: "Больше — новые заказы не приходят, пока не сдаст.", suffix: "₽"),
            PoolSettingField("pool_hold_hours", "Сдать выручку не позже, ч", .int,
                             hint: "Держит деньги дольше — заказы не приходят."),
            PoolSettingField("pool_newbie_deliveries", "Новичок — первые N доставок", .int),
            PoolSettingField("pool_newbie_cash_limit", "Новичку — заказы с оплатой до", .decimal, suffix: "₽"),
        ]),
        PoolSettingGroup(title: "Поиск курьера", note: nil, fields: [
            PoolSettingField("pool_wave_radius_km", "Сначала — курьерам в радиусе, км", .decimal, suffix: "км"),
            PoolSettingField("pool_wave_seconds", "Через сколько секунд — всем", .int),
            PoolSettingField("pool_search_minutes", "«Никто не взял» через, мин", .int,
                             hint: "Для вызова «забрать сейчас»."),
            PoolSettingField("pool_sched_from_min", "Вызов «на потом» — если забрать позже чем через, мин", .int,
                             hint: "Такой вызов ищет курьера до времени забора, а не заданное выше число минут."),
            PoolSettingField("pool_sched_lead_min", "«Никто не взял» — за столько минут до забора", .int),
            PoolSettingField("pool_sched_max_hours", "Искать не дольше, ч", .int,
                             hint: "Для межгорода на послезавтра и т. п."),
            PoolSettingField("pool_sched_remind", "Напоминать курьерам за 60 и 30 мин до забора, заведению — «курьера пока нет» за 30 мин", .toggle),
            PoolSettingField("pool_max_active", "Заказов у курьера одновременно", .int),
            PoolSettingField("pool_min_fee", "Цена доставки от", .decimal, suffix: "₽"),
            PoolSettingField("pool_max_fee", "Цена доставки до", .decimal, suffix: "₽"),
            PoolSettingField("pool_online_ttl_min", "Снимать с линии без связи через, мин", .int),
        ]),
        PoolSettingGroup(title: "Грузовые машины и межгород",
                         note: "Подсказка цены по городу: цена кузова + ₽ за км + грузчики. Межгород: клиент выбирает водителя — цена по тарифу водителя (₽ за км, его минималка, его цена грузчика); «любой водитель» — подсказка ₽ за км ниже.",
                         fields: [
            PoolSettingField("pool_price_s", "Кузов S", .decimal, suffix: "₽"),
            PoolSettingField("pool_price_m", "Кузов M", .decimal, suffix: "₽"),
            PoolSettingField("pool_price_l", "Кузов L", .decimal, suffix: "₽"),
            PoolSettingField("pool_price_xl", "Фургон XL", .decimal, suffix: "₽"),
            PoolSettingField("pool_price_xxl", "Грузовик XXL", .decimal, suffix: "₽"),
            PoolSettingField("pool_cargo_per_km", "По городу: ₽ за км (грузовые)", .decimal, suffix: "₽"),
            PoolSettingField("pool_loader_price", "Грузчик (если у водителя нет своей цены)", .decimal, suffix: "₽"),
            PoolSettingField("pool_cargo_max_fee", "Наибольшая цена грузовой / межгорода", .decimal, suffix: "₽"),
            PoolSettingField("pool_intercity_enabled", "Межгород включён", .toggle),
            PoolSettingField("pool_intercity_per_km", "Межгород «любому водителю»: подсказка ₽ за км", .decimal, suffix: "₽"),
            PoolSettingField("pool_intercity_wait_min", "Сколько ждать ответа выбранного водителя, мин", .int),
        ]),
        PoolSettingGroup(title: "Правило «только грузы и посылки, пассажиров не перевозим»",
                         note: "Новые курьеры подтверждают правило галочкой в заявке, остальные — кнопкой в веб-версии. Включайте, когда обновятся приложения курьера: старые версии кнопки не знают.",
                         fields: [
            PoolSettingField("pool_rules_required", "Без подтверждения правила курьер не выходит на линию и не берёт заказы", .toggle),
        ]),
        PoolSettingGroup(title: "Посылки от клиентов («Отправить посылку»)", note: nil, fields: [
            PoolSettingField("pool_parcels_enabled", "Клиенты могут вызвать курьера отвезти посылку (людей и животных курьеры не возят)", .toggle),
            PoolSettingField("pool_parcel_base", "Подсказка цены: база", .decimal, hint: "Клиент может предложить больше.", suffix: "₽"),
            PoolSettingField("pool_parcel_per_km", "Подсказка цены: за км", .decimal, hint: "Если клиент указал точку на карте.", suffix: "₽"),
            PoolSettingField("pool_parcel_max_active", "Посылок в пути у клиента одновременно", .int),
            PoolSettingField("pool_parcel_daily_max", "Вызовов курьера клиентом за сутки", .int,
                             hint: "С отменёнными: каждый вызов — push всем курьерам города."),
        ]),
    ]

    static var allFields: [PoolSettingField] { all.flatMap { $0.fields } }
}

/// Загрузка и сохранение настроек: GET/POST /api/admin/pool/settings.
@MainActor
final class PoolSettingsModel: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published var values: [String: String] = [:]
    @Published private(set) var original: [String: String] = [:]
    @Published private(set) var fieldErrors: [String: String] = [:]
    @Published private(set) var refreshError: String?

    private var generation = 0

    var isDirty: Bool { values != original }

    /// Сервис включили или выключили (нужно подтверждение).
    var enabledChange: Bool? {
        let now = values["pool_enabled"] ?? "1"
        let was = original["pool_enabled"] ?? "1"
        return now == was ? nil : now == "1"
    }

    func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    func load() async {
        generation += 1
        let gen = generation
        if state != .loaded { state = .loading }
        do {
            let j = try await API.shared.get("/api/admin/pool/settings")
            guard gen == generation else { return }
            guard j.isObject else {
                if state != .loaded { state = .empty("Сервер не прислал настройки") }
                return
            }
            apply(j)
            refreshError = nil
            state = .loaded
        } catch {
            guard gen == generation else { return }
            if APIError.isCancellation(error) {
                if state == .loading { state = .idle }
                return
            }
            if state == .loaded {
                refreshError = APIError.describe(error)
            } else {
                state = .failed(APIError.describe(error))
            }
        }
    }

    /// Новые значения из ответа сервера.
    private func apply(_ cfg: JSON) {
        var out: [String: String] = [:]
        for f in PoolSettingGroup.allFields {
            let v = f.read(cfg)
            switch f.kind {
            case .toggle:
                if !v.isNull { out[f.key] = v.boolValue ? "1" : "0" }
            case .int:
                if let n = v.int { out[f.key] = String(n) }
            case .decimal:
                if let d = v.decimal { out[f.key] = Fmt.decimalInput(d) }
            case .choice:
                if let s = v.nonEmptyString { out[f.key] = s }
            }
        }
        values = out
        original = out
        fieldErrors = [:]
    }

    /// Сохранить. Ошибки по полям (422) остаются у полей, сообщение уходит в алерт кнопки.
    func save() async throws {
        var body: [String: Any?] = [:]
        var local: [String: String] = [:]
        for f in PoolSettingGroup.allFields {
            let text = (values[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                // Поля нет на старом сервере — не трогаем; очистили — просим ввести.
                if !(original[f.key] ?? "").isEmpty { local[f.key] = "Укажите значение" }
                continue
            }
            switch f.kind {
            case .toggle, .choice:
                body[f.key] = text
            case .int:
                if let n = Int(text) { body[f.key] = String(n) } else { local[f.key] = "Введите целое число" }
            case .decimal:
                if let d = Fmt.parseDecimal(text) {
                    body[f.key] = NSDecimalNumber(decimal: d).stringValue
                } else {
                    local[f.key] = "Число с запятой, не больше двух знаков после неё"
                }
            }
        }
        if !local.isEmpty {
            fieldErrors = local
            throw APIError.validation("Проверьте значения настроек", fields: local)
        }
        do {
            let j = try await API.shared.post("/api/admin/pool/settings", body: body)
            if j.isObject {
                apply(j)
            } else {
                original = values
                fieldErrors = [:]
            }
        } catch {
            if let e = error as? APIError, case .validation = e {
                fieldErrors = e.fieldErrors
            }
            throw error
        }
    }
}

/// Экран «Настройки» раздела «Курьеры Yumurta»: GET/POST /api/admin/pool/settings.
/// Деньги уходят строкой ("12.50"), включение и выключение сервиса — с подтверждением.
struct PoolSettingsView: View {
    @StateObject private var model = PoolSettingsModel()

    var body: some View {
        content
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Загрузка…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.load() })
        case .empty(let text):
            EmptyStateView(title: text ?? "Нет данных", systemImage: "tray")
        case .loaded:
            form
        }
    }

    private var form: some View {
        Form {
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.load() } })
            }
            ForEach(PoolSettingGroup.all) { group in
                Section {
                    ForEach(group.fields) { f in
                        PoolSettingRow(field: f, model: model)
                    }
                } header: {
                    if let t = group.title { Text(t) }
                } footer: {
                    if let n = group.note { Text(n) }
                }
            }
            Section {
                saveButton
            }
        }
        .refreshable { await model.load() }
    }

    private var saveButton: some View {
        ActionButton("Сохранить", systemImage: "checkmark", style: .prominent,
                     confirm: confirmation, successMessage: "Настройки сохранены", fullWidth: true) {
            try await model.save()
        }
        .disabled(!model.isDirty)
    }

    /// Подтверждение — только когда меняется главный переключатель.
    private var confirmation: ConfirmAction? {
        guard let on = model.enabledChange else { return nil }
        if on {
            return ConfirmAction(title: "Включить курьеров Yumurta?",
                                 message: "Заведения смогут вызывать курьеров, курьеры — подавать заявки.",
                                 confirmLabel: "Включить и сохранить")
        }
        return ConfirmAction(title: "Выключить курьеров Yumurta?",
                             message: "Заведения не смогут вызывать курьеров, курьеры — подавать заявки.",
                             confirmLabel: "Выключить и сохранить", destructive: true)
    }
}

/// Строка настройки: элемент ввода, пояснение и ошибка сервера (422) под ним.
struct PoolSettingRow: View {
    let field: PoolSettingField
    @ObservedObject var model: PoolSettingsModel

    private var text: Binding<String> {
        Binding(get: { model.values[field.key] ?? "" }, set: { model.values[field.key] = $0 })
    }

    private var isOn: Binding<Bool> {
        Binding(get: { (model.values[field.key] ?? "0") == "1" },
                set: { model.values[field.key] = $0 ? "1" : "0" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let h = field.hint {
                Text(h)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let e = model.fieldErrors[field.key] {
                Text(e)
                    .font(.caption)
                    .foregroundColor(Brand.red)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .toggle:
            Toggle(field.title, isOn: isOn)
        case .int:
            FormIntField(field.title, text: text)
        case .decimal:
            FormDecimalField(field.title, text: text, suffix: field.suffix)
        case .choice(let options):
            FormPicker(field.title, selection: text, options: options)
        }
    }
}
