// Combine — для .dropFirst() у $lastMeta (SwiftUI его не реэкспортирует явно).
import Combine
import SwiftUI

/// Вкладки раздела «Курьеры».
enum CouriersTab: String, CaseIterable, Identifiable, Hashable {
    /// Заявки и курьеры (фильтр по статусу, новые заявки — первыми).
    case couriers
    /// Проблемы с доставкой, о которых сообщили заведения.
    case problems
    /// Жалобы по вызовам: на курьера и курьера на отправителя.
    case complaints

    var id: String { rawValue }

    var title: String {
        switch self {
        case .couriers: return "Курьеры"
        case .problems: return "Проблемы"
        case .complaints: return "Жалобы"
        }
    }

    /// Счётчик «ждут» из Notifier (если сводка раздела ещё не пришла).
    var category: NotifyCategory {
        switch self {
        case .couriers: return .couriers
        case .problems: return .courierProblems
        case .complaints: return .courierComplaints
        }
    }
}

/// Раздел «Курьеры» — «Курьеры Yumurta», как /admin/couriers.php на сайте
/// (routes/courier_pool.php, core/CourierPool.php, ручки /api/admin/pool/*):
///
/// * GET /api/admin/pool/summary — сводка (на проверке, на линии, долг, комиссия);
/// * GET /api/admin/pool/couriers?status=&q=&page= — список, data = массив, meta {page, total, counts};
///   сервер сам ставит заявки «на проверке» первыми;
/// * GET /api/admin/pool/couriers/{user_id} — карточка (CourierDetailView), фото лица и прав —
///   GET …/couriers/{id}/doc/photo|license (только с токеном администратора);
/// * POST …/couriers/{id}/approve|reject|block|unblock {note}, …/adjust, …/cash-limit;
/// * GET /api/admin/pool/problems?status=, POST …/problems/{id}/resolve {action: uphold|void, note};
/// * GET /api/admin/pool/complaints?status=, POST …/complaints/{id}/resolve {action, note};
/// * GET /api/admin/pool/problems/{id}, …/complaints/{id} — карточка по id (волна А92, 404 not_found).
///
/// `openId` без `subtab` — user_id курьера (push pool_courier): его карточка открывается сразу.
/// `subtab` — "problems" / "complaints" (push pool_problem / pool_complaint); вместе с
/// `openId` — id проблемы / жалобы: поверх вкладки сразу открывается её карточка
/// (CourierIssueDetailView); нет такой (404) или сервер старый — остаётся вкладка.
///
/// «Кто видит заказ» (волна А96, GET /api/admin/pool/calls/{id}/visibility, CallVisibilityView):
/// кнопка с глазом в шапке раздела (по номеру заказа), строка в карточках проблем и жалоб,
/// тап по доставке в карточке курьера. Есть ли ручка, проверяется при входе в раздел
/// (CallVisibilitySupport); на старом сервере входов нет.
/// Список вызовов и настройки раздела пока только на сайте.
struct CouriersRootView: View {
    let openId: Int?

    @State private var tab: CouriersTab
    @StateObject private var couriers = PagedListModel(path: "/api/admin/pool/couriers", filters: ["status": "pending"])
    @StateObject private var problems = PagedListModel(path: "/api/admin/pool/problems", searchParam: nil,
                                                       filters: ["status": "open"])
    @StateObject private var complaints = PagedListModel(path: "/api/admin/pool/complaints", searchParam: nil,
                                                         filters: ["status": "open"])
    @StateObject private var summary = ObjectLoader(path: "/api/admin/pool/summary")
    @ObservedObject private var notifier = Notifier.shared
    @State private var deepLinkActive = false
    @State private var deepLinkHandled = false
    /// Лист «Кто видит заказ» по номеру.
    @State private var lookupShown = false
    @ObservedObject private var visibility = CallVisibilitySupport.shared
    /// Вкладка записи из ссылки: .problems / .complaints — openId это id проблемы / жалобы;
    /// nil — openId это user_id курьера (как раньше).
    private let issueTab: CouriersTab?

    /// - Parameters:
    ///   - openId: user_id курьера, а со вкладкой problems/complaints — id записи (deep link / push);
    ///   - subtab: rawValue вкладки (CouriersTab), nil — «Курьеры».
    init(openId: Int? = nil, subtab: String? = nil) {
        self.openId = openId
        let requested = CouriersTab(rawValue: subtab ?? "") ?? .couriers
        let issue: CouriersTab? = openId != nil && requested != .couriers ? requested : nil
        issueTab = issue
        _tab = State(initialValue: openId != nil ? (issue ?? .couriers) : requested)
    }

    var body: some View {
        Group {
            switch tab {
            case .couriers:
                CouriersListScreen(model: couriers, summary: summary)
            case .problems:
                CourierProblemsScreen(model: problems, summary: summary, couriers: couriers)
            case .complaints:
                CourierComplaintsScreen(model: complaints, summary: summary, couriers: couriers)
            }
        }
        .safeAreaInset(edge: .top) { tabPicker }
        .navigationDestination(isPresented: $deepLinkActive) { deepLinkDestination }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if visibility.showsEntry {
                    Button {
                        lookupShown = true
                    } label: {
                        Label("Кто видит вызов", systemImage: "eye")
                    }
                    .accessibilityLabel("Кто видит вызов")
                    .accessibilityHint("Ввести номер вызова или заказа и посмотреть, каким курьерам он виден")
                }
            }
        }
        .sheet(isPresented: $lookupShown) {
            CallVisibilityLookupSheet()
        }
        .onAppear(perform: appeared)
    }

    @ViewBuilder
    private var deepLinkDestination: some View {
        switch issueTab {
        case .problems:
            CourierIssueDetailView(kind: .problem, id: openId ?? 0,
                                   onChanged: { issueChanged(problems) }, onMissing: { deepLinkActive = false })
        case .complaints:
            CourierIssueDetailView(kind: .complaint, id: openId ?? 0,
                                   onChanged: { issueChanged(complaints) }, onMissing: { deepLinkActive = false })
        default:
            CourierDetailView(id: openId ?? 0, onChanged: { changed() })
        }
    }

    private var tabPicker: some View {
        Picker("Раздел", selection: $tab) {
            ForEach(CouriersTab.allCases) { t in
                Text(segmentTitle(t)).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Brand.bg)
    }

    /// «Курьеры · 3»: число — из сводки раздела, пока её нет — из опроса Notifier.
    private func segmentTitle(_ t: CouriersTab) -> String {
        let n = waiting(t)
        return n > 0 ? t.title + " · " + String(n) : t.title
    }

    private func waiting(_ t: CouriersTab) -> Int {
        let d = summary.data
        guard d.isObject else { return notifier.count(t.category) }
        switch t {
        case .couriers: return d["pending"].intValue
        case .problems: return d["open_problems"].intValue
        case .complaints: return d["open_complaints"].intValue
        }
    }

    private func appeared() {
        // На вкладке «Курьеры» сводку запросит сам список, когда загрузится (onReceive
        // lastMeta) — здесь не дублируем. Другие вкладки — сводка для чисел в сегментах.
        if tab != .couriers { Task { await summary.loadIfNeeded() } }
        // Есть ли на сервере «Кто видит заказ» (А96) — один раз за запуск.
        Task { await CallVisibilitySupport.shared.probeIfNeeded() }
        if openId != nil && !deepLinkHandled {
            deepLinkHandled = true
            deepLinkActive = true
        }
    }

    /// После решения в карточке, открытой по push/ссылке: список, сводка и счётчики.
    /// Эта карточка открыта через navigationDestination(isPresented:), а не строкой
    /// списка, поэтому обновление списка её не закрывает.
    private func changed() {
        Task {
            await couriers.refresh()
            await summary.load()
        }
    }

    /// После решения в карточке проблемы / жалобы, открытой по push: вкладка под ней,
    /// сводка, а если блокировали курьера — и вкладка «Курьеры» (если её уже загружали).
    /// Карточка открыта через navigationDestination(isPresented:) — обновление списков её не закрывает.
    private func issueChanged(_ list: PagedListModel) {
        Task {
            await list.refresh()
            if couriers.state != .idle { await couriers.refresh() }
            await summary.load()
        }
    }
}

/// Подписи и справочники раздела «Курьеры» (как core/CourierPool.php и admin-pool.js).
enum CouriersFormat {
    /// Фильтр статуса: новые заявки — первыми; "" — все (сервер всё равно ставит заявки сверху).
    static let statusChips: [PickerOption] = [
        PickerOption(value: "pending", label: "Новые заявки"),
        PickerOption(value: "approved", label: "Одобрены"),
        PickerOption(value: "blocked", label: "Заблокированы"),
        PickerOption(value: "rejected", label: "Отклонены"),
        PickerOption(value: "", label: "Все"),
    ]

    /// CourierPool::STATUS_LABELS.
    static func statusLabel(_ s: String?) -> String {
        switch s ?? "" {
        case "pending": return "На проверке"
        case "approved": return "Одобрен"
        case "rejected": return "Отклонён"
        case "blocked": return "Заблокирован"
        default: return Fmt.statusLabel(s)
        }
    }

    /// Подпись статуса из ответа сервера (status_label), иначе своя.
    static func statusLabel(of row: JSON) -> String {
        row["status_label"].nonEmptyString ?? statusLabel(row["status"].string)
    }

    /// Частые причины отказа по заявке (курьер увидит текст в приложении).
    static let rejectReasons: [String] = [
        "Фото лица не видно или не совпадает с правами",
        "Водительское удостоверение не читается",
        "Срок действия водительского удостоверения истёк",
        "ФИО в заявке не совпадает с правами",
        "Неполные данные о машине: марка, цвет, госномер",
    ]

    /// Частые причины блокировки.
    static let blockReasons: [String] = [
        "Нарушение правил: сервис только для грузов и посылок, пассажиров не перевозим",
        "Не сдаёт выручку заведениям",
        "Повторные жалобы заведений и клиентов",
        "Документы оказались чужими или поддельными",
    ]

    /// «Кузов M, до 700 кг · Межгород, 25 ₽/км».
    static func vehicleLine(_ v: JSON) -> String {
        var parts: [String] = []
        if let label = v["vehicle_label"].nonEmptyString {
            if let kg = v["max_kg"].int, kg > 0 {
                parts.append(label + ", до " + Fmt.number(kg) + " кг")
            } else {
                parts.append(label)
            }
        }
        if v["service_area"].stringValue != "city", let area = v["service_area_label"].nonEmptyString {
            if v["km_price"].decimal != nil {
                parts.append(area + ", " + perKm(v["km_price"]))
            } else {
                parts.append(area)
            }
        }
        return parts.joined(separator: " · ")
    }

    /// «25 ₽/км».
    static func perKm(_ j: JSON) -> String {
        j.decimal == nil ? "—" : Fmt.money(j) + "/км"
    }

    /// «★ 4,8 (12)» или nil, если оценок нет.
    static func rating(_ row: JSON) -> String? {
        guard let r = row["rating"].decimal else { return nil }
        let n = row["rating_count"].intValue
        return "★ " + Fmt.number(r) + (n > 0 ? " (" + String(n) + ")" : "")
    }

    /// Действие журнала (adminAudit в CourierPool) по-русски.
    static func auditAction(_ a: String?) -> String {
        switch a ?? "" {
        case "approve": return "Одобрен"
        case "reject": return "Отклонён"
        case "block": return "Заблокирован"
        case "unblock": return "Разблокирован"
        case "adjust": return "Поправка расчёта"
        // Волна А92 (П-45 №3): POST …/couriers/{id}/cash-limit пишет в журнал.
        case "cash_limit": return "Лимит наличных"
        default: return a ?? "—"
        }
    }

    /// Цвет действия журнала.
    static func auditColor(_ a: String?) -> Color {
        switch a ?? "" {
        case "approve", "unblock": return Brand.green
        case "reject", "block": return Brand.red
        default: return Brand.blue
        }
    }
}

/// Вкладка «Курьеры»: статусы-чипы с числами, сводка, поиск, список.
struct CouriersListScreen: View {
    @ObservedObject var model: PagedListModel
    @ObservedObject var summary: ObjectLoader
    /// В открытой карточке что-то изменили — обновить список, когда вернёмся.
    /// Сразу нельзя: строки без id (ключ — хэш JSON), обновлённая строка сменит
    /// ключ или выпадет из фильтра, и NavigationLink закроет карточку.
    @State private var needsRefresh = false

    init(model: PagedListModel, summary: ObjectLoader) {
        self.model = model
        self.summary = summary
    }

    private var emptyText: String {
        if model.filter("status") == "pending" {
            return "Новых заявок курьеров нет. Курьеры подают заявку в приложении курьера или на сайте /courier/pool."
        }
        return "Курьеров не найдено"
    }

    var body: some View {
        AdminListScreen("Курьеры", model: model, searchPrompt: "Имя, телефон или госномер",
                        emptyText: emptyText,
                        header: AnyView(CouriersListHeader(model: model, summary: summary)),
                        row: { CourierRow(courier: $0) },
                        destination: { c in
                            CourierDetailView(id: c["user_id"].intValue, onChanged: { changed() })
                        })
            .onReceive(model.$lastMeta.dropFirst()) { _ in
                // Список перезагрузился (первая загрузка, фильтр, поиск, «потянуть») —
                // сводку тоже. dropFirst — без запроса на текущее значение при подписке.
                Task { await summary.load() }
            }
            .onAppear {
                guard needsRefresh else { return }
                needsRefresh = false
                // Сводка обновится сама — по новому lastMeta.
                Task { await model.refresh() }
            }
    }

    private func changed() {
        needsRefresh = true
    }
}

/// Шапка списка: чипы статусов (числа — meta.counts ответа) и строка сводки.
struct CouriersListHeader: View {
    @ObservedObject var model: PagedListModel
    @ObservedObject var summary: ObjectLoader

    init(model: PagedListModel, summary: ObjectLoader) {
        self.model = model
        self.summary = summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CouriersStatusChips(model: model)
            CouriersSummaryLine(data: summary.data)
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

/// Чипы «Новые заявки · 3 · Одобрены · 12 · …» (meta.counts — по всей базе, не по фильтру).
struct CouriersStatusChips: View {
    @ObservedObject var model: PagedListModel

    init(model: PagedListModel) {
        self.model = model
    }

    private var current: String { model.filter("status") ?? "" }

    private func count(_ status: String) -> Int? {
        let counts = model.lastMeta["counts"]
        guard counts.isObject else { return nil }
        if status.isEmpty {
            var sum = 0
            for (_, v) in counts.object { sum += v.intValue }
            return sum
        }
        return counts[status].int ?? 0
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CouriersFormat.statusChips) { opt in
                    chip(opt)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ opt: PickerOption) -> some View {
        let selected = current == opt.value
        let n = count(opt.value)
        let text = n.map { opt.label + " · " + String($0) } ?? opt.label
        let urgent = opt.value == "pending" && (n ?? 0) > 0
        let fg: Color = selected ? Brand.accent : (urgent ? Brand.amber : Brand.text)
        return Button {
            Haptics.tap()
            model.setFilter("status", opt.value.isEmpty ? nil : opt.value)
        } label: {
            Text(text)
                .font(.subheadline.weight(urgent ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Brand.accent.opacity(0.15) : Brand.chip)
                .foregroundColor(fg)
                .clipShape(Capsule())
        }
        .buttonStyle(.borderless)
    }
}

/// Строка сводки GET /api/admin/pool/summary: на линии, вызовы, долг курьеров.
struct CouriersSummaryLine: View {
    let data: JSON

    var body: some View {
        if data.isObject && data["ready"].bool != false {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity)
                Text(money)
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
        }
    }

    private var activity: String {
        "Одобрено " + Fmt.number(data["approved"].intValue)
            + " · на линии " + Fmt.number(data["online"].intValue)
            + " · активных вызовов " + Fmt.number(data["active_calls"].intValue)
            + " · доставлено сегодня " + Fmt.number(data["delivered_today"].intValue)
    }

    private var money: String {
        "Курьеры должны заведениям " + Fmt.money(data["couriers_debt"])
            + " · комиссия к получению " + Fmt.money(data["platform_due"])
    }
}

/// Строка курьера: ФИО, статус, телефон и город, машина, дата заявки, долг.
struct CourierRow: View {
    let courier: JSON

    init(courier: JSON) {
        self.courier = courier
    }

    private var contact: String {
        var parts: [String] = []
        if let p = courier["phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        if let c = courier["city"].nonEmptyString { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    private var car: String {
        var parts: [String] = []
        if let c = courier["car"].nonEmptyString { parts.append(c) }
        let v = CouriersFormat.vehicleLine(courier["vehicle"])
        if !v.isEmpty { parts.append(v) }
        return parts.joined(separator: " · ")
    }

    private var bottom: String {
        var parts: [String] = ["Заявка " + Fmt.date(courier["submitted_at"])]
        if courier["status"].stringValue == "approved" {
            parts.append("доставок " + Fmt.number(courier["deliveries_count"].intValue))
            if let r = CouriersFormat.rating(courier) { parts.append(r) }
        }
        if let debt = courier["debt"].decimal, debt > 0 {
            parts.append("долг " + Fmt.money(debt))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(courier["full_name"].nonEmptyString ?? "Без имени")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if courier["online"].boolValue {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundColor(Brand.green)
                }
                Spacer(minLength: 6)
                StatusBadge(status: courier["status"].string, label: CouriersFormat.statusLabel(of: courier))
            }
            if !contact.isEmpty {
                Text(contact)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if !car.isEmpty {
                Text(car)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(2)
            }
            Text(bottom)
                .font(.caption2)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 3)
    }
}
