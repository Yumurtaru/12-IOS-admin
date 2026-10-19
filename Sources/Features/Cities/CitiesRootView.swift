import SwiftUI

/// Раздел «Города»: поиск по названию и региону, фильтры, включение/отключение
/// прямо в списке, правка (название, регион, активность), добавление и удаление
/// пустого города.
///
/// Сервер: GET/POST /api/admin/cities, PUT/DELETE /api/admin/cities/{id}.
/// Список постраничный ({items,total,page,pages}, по 50, по алфавиту).
/// `openId` — id города: берём его из GET /api/admin/cities/{id} (П-29.4; старый
/// сервер — ищем по страницам списка) и открываем правку.
struct CitiesRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/cities")
    @State private var editing: CitiesEditTarget?
    @State private var pendingDelete: ConfirmAction?
    @State private var deleteTarget: JSON = .null
    @State private var deepLinkStarted = false
    @State private var deepLinkNote: String?

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var filters: [ListFilter] {
        [
            ListFilter(key: "active", title: "Статус", options: [
                PickerOption(value: "1", label: "Включённые"),
                PickerOption(value: "0", label: "Отключённые"),
            ]),
            ListFilter(key: "with_shops", title: "Магазины", options: [
                PickerOption(value: "1", label: "Есть магазины"),
            ]),
        ]
    }

    private var header: AnyView? {
        guard let note = deepLinkNote else { return nil }
        return AnyView(InfoBanner(note).listRowSeparator(.hidden))
    }

    var body: some View {
        AdminListScreen("Города", model: model, searchPrompt: "Город или регион", filters: filters,
                        emptyText: "Городов нет", header: header) { city in
            cityRow(city)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = CitiesEditTarget(city: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Добавить город")
            }
        }
        .sheet(item: $editing) { target in
            CitiesEditorSheet(city: target.city, onSaved: { updated in
                handleSaved(updated)
            }, onDeleted: { id in
                model.remove(id: id)
            })
        }
        .confirmAction($pendingDelete) {
            try await performDelete()
        }
        .task { await openDeepLinkIfNeeded() }
    }

    private func cityRow(_ city: JSON) -> some View {
        CitiesRow(city: city, onEdit: {
            editing = CitiesEditTarget(city: city)
        }, onChanged: { updated in
            model.replace(updated)
        })
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                askDelete(city)
            } label: {
                Label("Удалить", systemImage: "trash")
            }
            Button {
                editing = CitiesEditTarget(city: city)
            } label: {
                Label("Изменить", systemImage: "pencil")
            }
            .tint(Brand.blue)
        }
    }

    private func askDelete(_ city: JSON) {
        deleteTarget = city
        let name = city["name"].stringValue
        pendingDelete = ConfirmAction(
            title: "Удалить город «" + name + "»?",
            message: "Удалить можно только город без магазинов, пользователей, вакансий, баннеров и заявок. Занятый город лучше отключить.",
            confirmLabel: "Удалить",
            destructive: true)
    }

    private func performDelete() async throws {
        guard let id = deleteTarget.id else { return }
        try await API.shared.delete("/api/admin/cities/" + String(id))
        model.remove(id: id)
    }

    private func handleSaved(_ updated: JSON?) {
        if let u = updated {
            model.replace(u)
        } else {
            Task { await model.refresh() }
        }
    }

    /// Переход по ссылке: город по id, без ручки на сервере — по страницам списка.
    private func openDeepLinkIfNeeded() async {
        guard let id = openId, !deepLinkStarted else { return }
        deepLinkStarted = true
        do {
            if let city = try await CitiesLookup.find(id: id) {
                editing = CitiesEditTarget(city: city)
            } else {
                deepLinkNote = "Город #" + String(id) + " не найден — возможно, его удалили."
            }
        } catch {
            if !APIError.isCancellation(error) {
                deepLinkNote = "Не удалось открыть город #" + String(id) + ": " + APIError.describe(error)
            }
        }
    }
}

/// Что редактируем в листе: nil — новый город.
struct CitiesEditTarget: Identifiable {
    let id = UUID()
    let city: JSON?
}

/// Поиск города по id: GET /api/admin/cities/{id}, иначе в постраничном списке (до 60 страниц по 50).
enum CitiesLookup {
    static func find(id: Int) async throws -> JSON? {
        // П-29.4: одна строка по id (как в списке). Старый сервер такой ручки
        // не знает — тогда, как раньше, листаем страницы списка.
        if let one = try? await API.shared.get("/api/admin/cities/" + String(id)), one.id == id {
            return one
        }
        var page = 1
        while page <= 60 {
            let data = try await API.shared.get("/api/admin/cities", query: ["page": String(page)])
            for c in data["items"].array where c.id == id {
                return c
            }
            let pages = data["pages"].int ?? 1
            if page >= pages { return nil }
            page += 1
        }
        return nil
    }

    /// Копия строки с заменой полей.
    static func with(_ row: JSON, _ changes: [String: JSON]) -> JSON {
        var obj = row.object
        for (k, v) in changes { obj[k] = v }
        return .object(obj)
    }
}

/// Строка города: название, регион, счётчики и переключатель «Активен».
private struct CitiesRow: View {
    let city: JSON
    let onEdit: () -> Void
    let onChanged: (JSON) -> Void

    @State private var active: Bool
    @State private var busy = false
    @State private var error: String?

    init(city: JSON, onEdit: @escaping () -> Void, onChanged: @escaping (JSON) -> Void) {
        self.city = city
        self.onEdit = onEdit
        self.onChanged = onChanged
        _active = State(initialValue: city["is_active"].boolValue)
    }

    private var countsText: String {
        let shops = Fmt.plural(city["shops"].intValue, "магазин", "магазина", "магазинов")
        let users = Fmt.plural(city["users"].intValue, "пользователь", "пользователя", "пользователей")
        return shops + " · " + users
    }

    var body: some View {
        HStack(spacing: 12) {
            info
                .contentShape(Rectangle())
                .onTapGesture { onEdit() }
            if busy {
                ProgressView()
            }
            Toggle("Активен", isOn: toggleBinding)
                .labelsHidden()
                .disabled(busy)
        }
        .padding(.vertical, 2)
        .onChange(of: city["is_active"].boolValue) { v in
            active = v
        }
        .alert("Не получилось", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(city["name"].stringValue)
                    .font(.body.weight(.medium))
                    .foregroundColor(active ? Brand.text : Brand.muted)
                if !active {
                    StatusBadge("Отключён", color: Brand.muted)
                }
            }
            if let region = city["region"].nonEmptyString {
                Text(region)
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            }
            Text(countsText)
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: { active }, set: { setActive($0) })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    }

    private func setActive(_ value: Bool) {
        guard !busy, let id = city.id else { return }
        // Ответ проверяем: при отказе сервера переключатель возвращается назад,
        // иначе админ думал бы, что город отключён, а он продолжал работать.
        active = value
        busy = true
        let row = city
        let done = onChanged
        Task { @MainActor in
            do {
                try await API.shared.put("/api/admin/cities/" + String(id), body: ["is_active": value ? 1 : 0])
                Haptics.success()
                done(CitiesLookup.with(row, ["is_active": .number(value ? 1 : 0)]))
            } catch {
                active = !value
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
            busy = false
        }
    }
}

/// Лист добавления/правки города.
struct CitiesEditorSheet: View {
    let city: JSON?
    let onSaved: (JSON?) -> Void
    let onDeleted: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var region: String
    @State private var active: Bool
    @State private var busy = false
    @State private var error: String?

    /// - Parameters:
    ///   - city: строка списка (nil — новый город);
    ///   - onSaved: после сохранения — обновлённая строка (nil — создан новый, обновите список);
    ///   - onDeleted: после удаления — id.
    init(city: JSON?, onSaved: @escaping (JSON?) -> Void, onDeleted: @escaping (Int) -> Void) {
        self.city = city
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _name = State(initialValue: city?["name"].stringValue ?? "")
        _region = State(initialValue: city?["region"].stringValue ?? "")
        _active = State(initialValue: city?["is_active"].bool ?? true)
    }

    private var cityId: Int? { city?.id }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormTextField("Название", text: $name, prompt: "Миллерово")
                    FormTextField("Регион", text: $region, prompt: "Ростовская область")
                    if cityId != nil {
                        FormToggle("Активен", isOn: $active,
                                   subtitle: "Отключённый город пропадает из выбора, данные сохраняются")
                    }
                } footer: {
                    if cityId == nil {
                        Text("Новый город сразу включён.")
                    }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                if let c = city {
                    statsSection(c)
                    deleteSection(c)
                }
            }
            .navigationTitle(cityId == nil ? "Новый город" : "Город")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(cityId == nil ? "Добавить" : "Сохранить") { save() }
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func statsSection(_ c: JSON) -> some View {
        Section("Сейчас в городе") {
            KVRow("Магазинов", c["shops"].string)
            KVRow("Пользователей", c["users"].string)
            KVRow("ID", c["id"].string, copyable: true)
        }
    }

    private func deleteSection(_ c: JSON) -> some View {
        let title = "Удалить город «" + c["name"].stringValue + "»?"
        let confirm = ConfirmAction(
            title: title,
            message: "Удалить можно только пустой город. Если в нём есть магазины или пользователи — отключите его.",
            confirmLabel: "Удалить",
            destructive: true)
        return Section {
            ActionButton("Удалить город", systemImage: "trash", role: .destructive, style: .plain,
                         confirm: confirm, fullWidth: true) {
                guard let id = c.id else { return }
                try await API.shared.delete("/api/admin/cities/" + String(id))
                onDeleted(id)
                dismiss()
            }
        }
    }

    private func save() {
        guard !busy else { return }
        let n = trimmedName
        guard !n.isEmpty else {
            error = "Введите название"
            return
        }
        let r = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let act = active
        let id = cityId
        let original = city
        busy = true
        error = nil
        Task { @MainActor in
            do {
                if let id = id {
                    let body: [String: Any?] = ["name": n, "region": r, "is_active": act ? 1 : 0]
                    try await API.shared.put("/api/admin/cities/" + String(id), body: body)
                    let regionJSON: JSON = r.isEmpty ? .null : .string(r)
                    let changes: [String: JSON] = ["name": .string(n), "region": regionJSON,
                                                   "is_active": .number(act ? 1 : 0)]
                    onSaved(CitiesLookup.with(original ?? .object([:]), changes))
                } else {
                    try await API.shared.post("/api/admin/cities", body: ["name": n, "region": r])
                    onSaved(nil)
                }
                Haptics.success()
                busy = false
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
