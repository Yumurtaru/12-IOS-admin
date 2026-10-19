import SwiftUI

/// Раздел «Журнал» — кто и что сделал в админке (как admin/audit.php).
///
/// GET /api/admin/audit ?page&user&action&entity&from&to&q
///   → {items:[{id, action, entity_type, entity_id, created_at, ip, old_json, new_json, user_id, name}],
///      total, page, pages, actions:[…], entities:[…], admins:[{id, name}]}
/// Списки для фильтров приходят в том же ответе (сервер кеширует их на 10 минут).
/// Страница — 50 записей, новые сверху.
///
/// Deep link: `openId` — номер записи журнала: GET /api/admin/audit/{id} (П-29.4);
/// старый сервер — запись ищется по страницам журнала (двоичным поиском по номерам).
struct AuditRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/audit", searchParam: "q")
    @State private var showPeriod = false
    @State private var deepEntry: JSON = .null
    @State private var showDeep = false
    @State private var deepDone = false
    @State private var deepBusy = false
    @State private var deepError: String?

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Журнал", model: model, searchPrompt: "Имя, IP, номер объекта, текст",
                        filters: filters, emptyText: "Записей нет", header: header,
                        row: { AuditRow(entry: $0) },
                        destination: { AuditEntryView(entry: $0) })
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showPeriod = true
                    } label: {
                        Image(systemName: periodActive ? "calendar.badge.clock" : "calendar")
                    }
                    .accessibilityLabel("Период")
                }
            }
            .sheet(isPresented: $showPeriod) {
                AuditPeriodSheet(model: model)
            }
            .navigationDestination(isPresented: $showDeep) {
                AuditEntryView(entry: deepEntry)
            }
            .overlay(alignment: .bottom) {
                if deepBusy {
                    AuditSearchingBadge(id: openId ?? 0)
                }
            }
            .alert("Запись не открылась", isPresented: deepErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deepError ?? "")
            }
            .task { await openDeepLinkIfNeeded() }
    }

    // MARK: - Фильтры

    private var periodActive: Bool {
        model.filter("from") != nil || model.filter("to") != nil
    }

    /// Фильтры как на сайте: администратор, действие, объект (значения — из ответа сервера).
    private var filters: [ListFilter] {
        let d = model.lastData
        var out: [ListFilter] = []
        let admins = AuditRootView.adminOptions(d["admins"].array)
        if !admins.isEmpty || model.filter("user") != nil {
            out.append(ListFilter(key: "user", title: "Администратор", options: admins, allLabel: "Любой"))
        }
        let actions = AuditRootView.codeOptions(d["actions"].array, label: AuditLabels.action)
        if !actions.isEmpty || model.filter("action") != nil {
            out.append(ListFilter(key: "action", title: "Действие", options: actions, allLabel: "Любое"))
        }
        let entities = AuditRootView.codeOptions(d["entities"].array, label: AuditLabels.entity)
        if !entities.isEmpty || model.filter("entity") != nil {
            out.append(ListFilter(key: "entity", title: "Объект", options: entities, allLabel: "Любой"))
        }
        return out
    }

    private static func adminOptions(_ list: [JSON]) -> [PickerOption] {
        var out: [PickerOption] = []
        for a in list {
            guard let id = a["id"].string else { continue }
            let name = a["name"].nonEmptyString ?? ("#" + id)
            out.append(PickerOption(value: id, label: name))
        }
        return out
    }

    private static func codeOptions(_ list: [JSON], label: (String) -> String) -> [PickerOption] {
        var out: [PickerOption] = []
        for x in list {
            guard let code = x.nonEmptyString else { continue }
            let title = label(code)
            let shown = title == code ? code : title + " (" + code + ")"
            out.append(PickerOption(value: code, label: shown))
        }
        return out
    }

    /// Плашка выбранного периода над списком (с кнопкой «сбросить»).
    private var header: AnyView? {
        guard periodActive else { return nil }
        let from = model.filter("from")
        let to = model.filter("to")
        return AnyView(
            AuditPeriodBadge(from: from, to: to, onEdit: { showPeriod = true }, onClear: {
                model.setFilter("from", nil)
                model.setFilter("to", nil)
            })
            .listRowSeparator(.hidden)
        )
    }

    // MARK: - Deep link

    private var deepErrorShown: Binding<Bool> {
        Binding(get: { deepError != nil }, set: { if !$0 { deepError = nil } })
    }

    private func openDeepLinkIfNeeded() async {
        guard let target = openId, target > 0, !deepDone else { return }
        deepDone = true
        deepBusy = true
        do {
            let found = try await AuditDeepLink.find(id: target)
            deepBusy = false
            if let entry = found {
                deepEntry = entry
                showDeep = true
            } else {
                deepError = "Запись журнала #" + String(target) + " не найдена."
            }
        } catch {
            deepBusy = false
            if !APIError.isCancellation(error) {
                deepError = APIError.describe(error)
            }
        }
    }
}

/// Строка журнала.
struct AuditRow: View {
    let entry: JSON

    init(entry: JSON) {
        self.entry = entry
    }

    private var actionText: String { AuditLabels.action(entry["action"].stringValue) }

    private var objectText: String {
        let type = entry["entity_type"].stringValue
        let id = entry["entity_id"].intValue
        let label = AuditLabels.entity(type)
        if id > 0 { return label + " #" + String(id) }
        return label
    }

    private var whoText: String {
        let name = entry["name"].nonEmptyString ?? "Система"
        if let ip = entry["ip"].nonEmptyString { return name + " · " + ip }
        return name
    }

    private var detailsPreview: String? {
        guard let s = entry["new_json"].nonEmptyString else { return nil }
        return String(s.prefix(160))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(actionText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Fmt.date(entry["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(objectText)
                .font(.subheadline)
                .foregroundColor(Brand.text)
            Text(whoText)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
            if let p = detailsPreview {
                Text(p)
                    .font(.caption2.monospaced())
                    .foregroundColor(Brand.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Плашка «Период: с … по …».
struct AuditPeriodBadge: View {
    let from: String?
    let to: String?
    let onEdit: () -> Void
    let onClear: () -> Void

    init(from: String?, to: String?, onEdit: @escaping () -> Void, onClear: @escaping () -> Void) {
        self.from = from
        self.to = to
        self.onEdit = onEdit
        self.onClear = onClear
    }

    private var text: String {
        var parts: [String] = []
        if let f = from { parts.append("с " + Fmt.day(f)) }
        if let t = to { parts.append("по " + Fmt.day(t)) }
        return "Период: " + parts.joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundColor(Brand.accent)
            Button(action: onEdit) {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(Brand.text)
            }
            .buttonStyle(.borderless)
            Spacer()
            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Brand.muted)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Сбросить период")
        }
        .padding(10)
        .background(Brand.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Выбор периода журнала («С даты» / «По дату», как на сайте).
struct AuditPeriodSheet: View {
    @ObservedObject var model: PagedListModel
    @Environment(\.dismiss) private var dismiss

    @State private var useFrom: Bool
    @State private var useTo: Bool
    @State private var fromDate: Date
    @State private var toDate: Date

    init(model: PagedListModel) {
        self.model = model
        let f = model.filter("from").flatMap { Fmt.parseDate($0) }
        let t = model.filter("to").flatMap { Fmt.parseDate($0) }
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        _useFrom = State(initialValue: f != nil)
        _useTo = State(initialValue: t != nil)
        _fromDate = State(initialValue: f ?? weekAgo)
        _toDate = State(initialValue: t ?? Date())
    }

    private var invalid: Bool {
        useFrom && useTo && Fmt.ymd(fromDate) > Fmt.ymd(toDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("С даты", isOn: $useFrom)
                    if useFrom {
                        FormDateField("С даты", date: $fromDate)
                    }
                }
                Section {
                    Toggle("По дату", isOn: $useTo)
                    if useTo {
                        FormDateField("По дату", date: $toDate)
                    }
                } footer: {
                    if invalid {
                        Text("Начало периода позже конца.").foregroundColor(Brand.red)
                    } else {
                        Text("Даты по московскому времени, включительно.")
                    }
                }
                Section {
                    Button("Сбросить период", role: .destructive) {
                        useFrom = false
                        useTo = false
                    }
                }
            }
            .navigationTitle("Период")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Показать") { apply() }
                        .disabled(invalid)
                }
            }
        }
    }

    private func apply() {
        let f: String? = useFrom ? Fmt.ymd(fromDate) : nil
        let t: String? = useTo ? Fmt.ymd(toDate) : nil
        if model.filter("from") != f { model.setFilter("from", f) }
        if model.filter("to") != t { model.setFilter("to", t) }
        dismiss()
    }
}

/// «Ищу запись #N…» поверх списка при открытии по ссылке.
struct AuditSearchingBadge: View {
    let id: Int

    init(id: Int) {
        self.id = id
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("Ищу запись #" + String(id) + "…")
                .font(.footnote)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.card)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.bottom, 16)
    }
}

/// Поиск записи журнала по номеру: GET /api/admin/audit/{id} (П-29.4). Старый
/// сервер без этой ручки — журнал отдаётся страницами по 50 строк от новых к
/// старым (ORDER BY id DESC), поэтому двоичный поиск по страницам: на 10 000
/// страниц хватает ~14 запросов.
enum AuditDeepLink {
    static func find(id: Int) async throws -> JSON? {
        // П-29.4: сначала одна запись по id; не вышло — прежний поиск по страницам.
        if let one = try? await API.shared.get("/api/admin/audit/" + String(id)), one.id == id {
            return one
        }
        let first = try await page(1)
        if let hit = match(first, id: id) { return hit }
        let firstItems = first["items"].array
        guard let top = firstItems.first?.id else { return nil }
        if id > top { return nil }
        let pages = max(1, first["pages"].int ?? 1)
        // Между верхней записью и искомой не больше (top - id) строк,
        // значит, нужная страница не дальше этой.
        let guess = 1 + (top - id) / 50
        var lo = 2
        var hi = min(pages, guess + 1)
        var steps = 0
        while lo <= hi && steps < 20 {
            steps += 1
            let mid = (lo + hi) / 2
            let d = try await page(mid)
            if let hit = match(d, id: id) { return hit }
            let ids = d["items"].array.compactMap { $0.id }
            guard let maxId = ids.max(), let minId = ids.min() else {
                hi = mid - 1
                continue
            }
            if id > maxId {
                hi = mid - 1
            } else if id < minId {
                lo = mid + 1
            } else {
                // Номер в диапазоне страницы, но записи нет — её удалили.
                return nil
            }
        }
        return nil
    }

    private static func page(_ n: Int) async throws -> JSON {
        try await API.shared.get("/api/admin/audit", query: ["page": String(n)])
    }

    private static func match(_ data: JSON, id: Int) -> JSON? {
        data["items"].array.first { $0.id == id }
    }
}
