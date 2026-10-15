import SwiftUI

// Категории доски объявлений и цены размещения.
// Пустая цена / срок / лимит фото у категории — «как у родителя», у корневой —
// «как в общих настройках» (ads_default_price). Поэтому рядом со своим
// значением показываем то, что реально применится (eff_*).

/// Дерево категорий доски.
struct AdsCategoriesScreen: View {
    @ObservedObject var loader: ObjectLoader
    @State private var pending: ConfirmAction?
    @State private var deleteId: Int?

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            list
        }
        .navigationTitle("Категории доски")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: editor(nil)) {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await loader.loadIfNeeded() }
        .confirmAction($pending) { try await performDelete() }
    }

    private var roots: [JSON] { loader.data["categories"].array }

    private var list: some View {
        List {
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            Section {
                Text(defaultsText)
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
            if roots.isEmpty {
                EmptyStateView(title: "Категорий нет", systemImage: "square.grid.2x2",
                               message: "Нажмите «+», чтобы добавить.")
                    .frame(minHeight: 200)
            }
            ForEach(roots, id: \.stableID) { root in
                Section {
                    categoryLink(root, child: false)
                    ForEach(root["children"].array, id: \.stableID) { kid in
                        categoryLink(kid, child: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    private var defaultsText: String {
        let d = loader.data
        let price = Fmt.money(d["default_price"])
        let days = d["default_days"].stringValue
        let grace = d["grace_days"].stringValue
        return "Цена по умолчанию для всей доски — " + price + ", срок " + days
            + " дней, удаление через " + grace
            + " дней после истечения (меняется в «Настройках»). Пустая цена у категории — «как у родителя»."
    }

    private func editor(_ c: JSON?) -> some View {
        AdsCategoryEditView(category: c, roots: roots, defaults: loader.data) {
            await loader.load()
        }
    }

    @ViewBuilder
    private func categoryLink(_ c: JSON, child: Bool) -> some View {
        let canDelete = child || c["ads_total"].intValue == 0
        NavigationLink(destination: editor(c)) {
            AdsCategoryRow(category: c, child: child)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDelete {
                Button(role: .destructive) {
                    ask(c)
                } label: { Label("Удалить", systemImage: "trash") }
            }
        }
    }

    private func ask(_ c: JSON) {
        deleteId = c.id
        pending = ConfirmAction(title: "Удалить категорию «" + c["name"].stringValue + "»?",
                                message: "Категорию с объявлениями или подкатегориями сервер удалить не даст — её можно только выключить.",
                                confirmLabel: "Удалить", destructive: true)
    }

    private func performDelete() async throws {
        guard let id = deleteId else { return }
        try await API.shared.delete("/api/admin/ads/categories/\(id)")
        await loader.load()
    }
}

/// Строка категории доски.
struct AdsCategoryRow: View {
    let category: JSON
    let child: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if child {
                    Text("└").foregroundColor(Brand.muted)
                }
                Text(category["name"].nonEmptyString ?? "—")
                    .font(child ? Font.subheadline : Font.subheadline.weight(.semibold))
                if !category["is_active"].boolValue {
                    StatusBadge("выключена", color: Brand.muted)
                }
            }
            Text(priceLine)
                .font(.caption)
                .foregroundColor(Brand.text)
            Text(countsLine)
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
        .padding(.leading, child ? 12 : 0)
    }

    private var priceLine: String {
        let price = Fmt.money(category["eff_price"])
        let inherit = category["price"].isNull ? " (наследует)" : ""
        let days = category["eff_days"].stringValue + " дн"
        let photos = "фото до " + category["eff_photos"].stringValue
        return price + inherit + " · " + days + " · " + photos
    }

    private var countsLine: String {
        let slug = category["slug"].stringValue
        let act = category["ads_active"].stringValue
        let all = category["ads_total"].stringValue
        return slug + " · активно " + act + " из " + all
    }
}

/// Создание / правка категории доски.
struct AdsCategoryEditView: View {
    let category: JSON?
    let roots: [JSON]
    let defaults: JSON
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var slug: String
    @State private var parentId: String
    @State private var price: String
    @State private var days: String
    @State private var photos: String
    @State private var icon: String
    @State private var sortText: String
    @State private var isActive: Bool
    @State private var allowPrice: Bool
    @State private var savedInfo: String?

    init(category: JSON?, roots: [JSON], defaults: JSON, onSaved: @escaping () async -> Void) {
        self.category = category
        self.roots = roots
        self.defaults = defaults
        self.onSaved = onSaved
        let c = category ?? .null
        let isNew = category == nil
        _name = State(initialValue: c["name"].stringValue)
        _slug = State(initialValue: c["slug"].stringValue)
        _parentId = State(initialValue: c["parent_id"].string ?? "")
        _price = State(initialValue: AdsCategoryEditView.priceText(c["price"]))
        _days = State(initialValue: c["days_valid"].string ?? "")
        _photos = State(initialValue: c["max_photos"].string ?? "")
        _icon = State(initialValue: c["icon"].stringValue)
        _sortText = State(initialValue: c["sort_order"].string ?? "0")
        _isActive = State(initialValue: isNew ? true : c["is_active"].boolValue)
        _allowPrice = State(initialValue: isNew ? true : c["allow_price"].boolValue)
    }

    /// "1500.00" → "1500,00" для поля ввода; null → "" (наследуется).
    static func priceText(_ j: JSON) -> String {
        guard let d = j.decimal else { return "" }
        return Fmt.decimalInput(d)
    }

    private var categoryId: Int? { category?.id }
    private var isNew: Bool { categoryId == nil }
    private var wasActive: Bool { category?["is_active"].boolValue ?? false }

    var body: some View {
        Form {
            mainSection
            tariffSection
            optionsSection
            if !isNew { deleteSection }
        }
        .navigationTitle(isNew ? "Новая категория" : "Категория")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { saveButton }
        }
        .alert(savedInfo ?? "", isPresented: savedShown) {
            Button("OK", role: .cancel) { dismiss() }
        }
    }

    private var savedShown: Binding<Bool> {
        Binding(get: { savedInfo != nil }, set: { if !$0 { savedInfo = nil } })
    }

    private var saveButton: some View {
        let deactivating = !isNew && wasActive && !isActive
        let confirm: ConfirmAction? = deactivating
            ? ConfirmAction(title: "Выключить категорию?",
                            message: "Активные объявления этой категории и её подкатегорий уйдут в архив. Оплаченный срок сохранится: когда категорию включат, авторы опубликуют их снова бесплатно.",
                            confirmLabel: "Выключить и сохранить", destructive: true)
            : nil
        return ActionButton("Сохранить", style: .plain, confirm: confirm) {
            try await save()
        }
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var mainSection: some View {
        Section("Основное") {
            FormTextField("Название", text: $name, prompt: "Например: Автомобили")
            FormTextField("Адрес (латиницей, для ссылок)", text: $slug, prompt: "заполнится само", autocapitalize: false)
            parentField
        }
    }

    @ViewBuilder
    private var parentField: some View {
        if isNew {
            FormPicker("Внутри категории", selection: $parentId, options: parentOptions)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                KVRow("Внутри категории", parentName)
                Text("Переносить категорию между разделами нельзя: у объявлений внутри поменялась бы цена.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
    }

    private var parentOptions: [PickerOption] {
        var out = [PickerOption(value: "", label: "— корневая категория —")]
        for r in roots {
            guard let id = r.id else { continue }
            out.append(PickerOption(value: String(id), label: r["name"].stringValue))
        }
        return out
    }

    private var parentName: String {
        guard let pid = Int(parentId) else { return "— корневая —" }
        let found = roots.first { $0.id == pid }
        return found?["name"].nonEmptyString ?? ("#" + String(pid))
    }

    private var tariffSection: some View {
        Section {
            FormDecimalField("Цена размещения", text: $price, suffix: "₽", prompt: "как у родителя")
            FormIntField("Срок, дней", text: $days, prompt: defaults["default_days"].string ?? "30")
            FormIntField("Фото, максимум", text: $photos, prompt: "8")
        } header: {
            Text("Тариф")
        } footer: {
            Text(tariffFooter)
        }
    }

    private var tariffFooter: String {
        let def = Fmt.money(defaults["default_price"])
        var t = "Пустое поле — брать у родительской категории, а у корневой — из общих настроек (" + def + ")."
        if let c = category {
            let effPrice: String = Fmt.money(c["eff_price"])
            let effDays: String = c["eff_days"].stringValue
            let effPhotos: String = c["eff_photos"].stringValue
            t += " Сейчас применяется: " + effPrice + ", " + effDays + " дн, фото до " + effPhotos + "."
        }
        return t
    }

    private var optionsSection: some View {
        Section {
            FormTextField("Иконка", text: $icon, prompt: "car, house, briefcase…", autocapitalize: false)
            FormIntField("Порядок", text: $sortText)
            FormToggle("Категория включена", isOn: $isActive)
            FormToggle("Показывать поле «Цена»", isOn: $allowPrice,
                       subtitle: "Снимите для «Отдам даром» и услуг")
        }
    }

    private var deleteSection: some View {
        Section {
            ActionButton("Удалить категорию", systemImage: "trash", role: .destructive, style: .plain,
                         confirm: ConfirmAction(title: "Удалить категорию «" + name + "»?",
                                                message: "Категорию с объявлениями или подкатегориями сервер удалить не даст — её можно только выключить.",
                                                confirmLabel: "Удалить", destructive: true)) {
                try await remove()
            }
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Тело как у сайта: пустые цена/срок/фото уходят пустой строкой = «наследовать».
    private func requestBody() -> [String: Any?] {
        var b: [String: Any?] = [
            "name": trimmed(name),
            "slug": trimmed(slug),
            "price": trimmed(price),
            "days_valid": trimmed(days),
            "max_photos": trimmed(photos),
            "icon": trimmed(icon),
            "sort_order": Int(trimmed(sortText)) ?? 0,
            "is_active": isActive,
            "allow_price": allowPrice,
        ]
        if isNew { b["parent_id"] = Int(parentId) ?? 0 }
        return b
    }

    private func save() async throws {
        if let id = categoryId {
            let r = try await API.shared.put("/api/admin/ads/categories/\(id)", body: requestBody())
            await onSaved()
            let archived = r["archived_ads"].intValue
            if archived > 0 {
                savedInfo = "Сохранено. В архив ушло " + Fmt.plural(archived, "объявление", "объявления", "объявлений")
                return
            }
        } else {
            try await API.shared.post("/api/admin/ads/categories", body: requestBody())
            await onSaved()
        }
        dismiss()
    }

    private func remove() async throws {
        guard let id = categoryId else { return }
        try await API.shared.delete("/api/admin/ads/categories/\(id)")
        await onSaved()
        dismiss()
    }
}
