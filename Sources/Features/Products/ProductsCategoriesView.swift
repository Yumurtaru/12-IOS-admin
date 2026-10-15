import SwiftUI
import UIKit

// Общие категории каталога (categories.shop_id IS NULL).
//
// Товары в общую категорию попадают не напрямую: администратор отмечает,
// какие категории МАГАЗИНОВ в неё входят (им проставляется parent_id), и
// витрина собирает товары из всех вложенных. Поэтому в карточке категории
// есть список «Входят категории магазинов».
//
// GET    /api/admin/categories              → [ {id,name,slug,image,sort_order,is_active,linked,products} ]
// GET    /api/admin/categories/{id}/links   → [ {id,name,parent_id,shop,linked,has_shop_parent,products} ] (q, ≤300)
// POST   /api/admin/categories              {name,image,sort_order,is_active} → {id}
// PUT    /api/admin/categories/{id}         {name?,image?,sort_order?,is_active?,links?:[id]}
// DELETE /api/admin/categories/{id}         (409, если в категории напрямую лежат товары)

/// Список общих категорий.
struct ProductsCategoriesScreen: View {
    @ObservedObject var loader: ObjectLoader
    @State private var pending: ConfirmAction?
    @State private var deleteId: Int?

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            list
        }
        .navigationTitle("Категории")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(destination: ProductsCategoryEditView(category: nil, onSaved: reload)) {
                    Image(systemName: "plus")
                }
            }
        }
        .task { await loader.loadIfNeeded() }
        .confirmAction($pending) { try await performDelete() }
    }

    private var rows: [JSON] { loader.data.array }

    private var list: some View {
        List {
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            Section {
                if rows.isEmpty {
                    EmptyStateView(title: "Общих категорий пока нет", systemImage: "square.grid.2x2",
                                   message: "Нажмите «+», чтобы создать первую.")
                        .frame(minHeight: 220)
                } else {
                    ForEach(rows, id: \.stableID) { c in
                        categoryLink(c)
                    }
                }
            } footer: {
                Text("Общие категории показываются на главной. Товары в них собираются из категорий магазинов, которые вы привяжете в карточке категории.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    private func categoryLink(_ c: JSON) -> some View {
        NavigationLink(destination: ProductsCategoryEditView(category: c, onSaved: reload)) {
            ProductsCategoryRow(category: c)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteId = c.id
                pending = ConfirmAction(title: "Удалить категорию «" + c["name"].stringValue + "»?",
                                        message: "Привязанные категории магазинов просто отвяжутся. Если в категории напрямую лежат товары, удалить нельзя.",
                                        confirmLabel: "Удалить", destructive: true)
            } label: { Label("Удалить", systemImage: "trash") }
        }
    }

    private func reload() async {
        await loader.load()
    }

    private func performDelete() async throws {
        guard let id = deleteId else { return }
        try await API.shared.delete("/api/admin/categories/\(id)")
        await loader.load()
    }
}

/// Строка общей категории.
struct ProductsCategoryRow: View {
    let category: JSON

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(path: ModerationMedia.uploadsPath(category["image"].string), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category["name"].nonEmptyString ?? "Без названия")
                        .font(.subheadline.weight(.semibold))
                    if !category["is_active"].boolValue {
                        StatusBadge("выключена", color: Brand.muted)
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
    }

    private var details: String {
        let linked = category["linked"].intValue
        let products = category["products"].intValue
        let a = Fmt.plural(linked, "категория магазина", "категории магазинов", "категорий магазинов")
        let b = Fmt.plural(products, "товар", "товара", "товаров")
        let sort = "порядок " + category["sort_order"].stringValue
        return a + " · " + b + " · " + sort
    }
}

/// Загрузчик категорий магазинов для привязки к общей категории.
@MainActor
final class ProductsLinksModel: ObservableObject {
    @Published private(set) var items: [JSON] = []
    @Published private(set) var state: LoadState = .idle
    /// Отмеченные категории магазинов (уйдут в PUT links целиком).
    @Published private(set) var selected: Set<Int> = []
    /// Привязки получены с сервера — только тогда можно отправлять links
    /// (иначе пустой набор отвязал бы всё).
    @Published private(set) var baselineLoaded = false
    /// Пользователь менял отметки.
    @Published private(set) var dirty = false
    @Published var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }

    let categoryId: Int
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    init(categoryId: Int) {
        self.categoryId = categoryId
    }

    func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    func load() async {
        generation += 1
        let gen = generation
        if items.isEmpty { state = .loading }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let data = try await API.shared.get("/api/admin/categories/\(categoryId)/links",
                                                query: ["q": q.isEmpty ? nil : q])
            guard gen == generation else { return }
            items = data.array
            if !baselineLoaded && q.isEmpty {
                // Сервер ставит привязанные первыми — берём их как исходный набор.
                var set = Set<Int>()
                for row in items where row["linked"].boolValue {
                    if let id = row.id { set.insert(id) }
                }
                selected = set
                baselineLoaded = true
            }
            state = items.isEmpty ? .empty(nil) : .loaded
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            state = .failed(APIError.describe(error))
        }
    }

    func toggle(_ id: Int) {
        guard baselineLoaded else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        dirty = true
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await self?.load()
        }
    }
}

/// Создание / правка общей категории.
struct ProductsCategoryEditView: View {
    let category: JSON?
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var image: String
    @State private var sortText: String
    @State private var isActive: Bool
    @State private var pickPhoto = false
    @State private var uploading = false
    @State private var uploadError: String?
    @StateObject private var links: ProductsLinksModel

    init(category: JSON?, onSaved: @escaping () async -> Void) {
        self.category = category
        self.onSaved = onSaved
        let c = category ?? .null
        _name = State(initialValue: c["name"].stringValue)
        _image = State(initialValue: c["image"].stringValue)
        _sortText = State(initialValue: c["sort_order"].string ?? "0")
        _isActive = State(initialValue: category == nil ? true : c["is_active"].boolValue)
        _links = StateObject(wrappedValue: ProductsLinksModel(categoryId: c.id ?? 0))
    }

    private var categoryId: Int? { category?.id }
    private var isNew: Bool { categoryId == nil }

    var body: some View {
        Form {
            mainSection
            imageSection
            if !isNew {
                ProductsLinksSection(links: links)
                deleteSection
            } else {
                Section {
                    Text("Категории магазинов можно будет привязать после создания.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
            }
        }
        .navigationTitle(isNew ? "Новая категория" : "Категория")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ActionButton("Сохранить", style: .plain) { try await save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || uploading)
            }
        }
        .sheet(isPresented: $pickPhoto) {
            ImagePicker(onPick: { img in upload(img) }, onFail: { msg in uploadError = msg })
        }
        .task {
            if !isNew { await links.loadIfNeeded() }
        }
    }

    private var mainSection: some View {
        Section("Основное") {
            FormTextField("Название", text: $name, prompt: "Например: Продукты")
            FormIntField("Порядок", text: $sortText)
            FormToggle("Включена", isOn: $isActive, subtitle: "Выключенная не показывается на главной")
            if let slug = category?["slug"].nonEmptyString {
                KVRow("Адрес", slug, copyable: true)
            }
        }
    }

    private var imageSection: some View {
        Section {
            if let p = ModerationMedia.uploadsPath(image) {
                AsyncImageView(path: p, height: 140, cornerRadius: 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            FormTextField("Путь к картинке", text: $image, prompt: "categories/…webp", autocapitalize: false)
            Button {
                uploadError = nil
                pickPhoto = true
            } label: {
                HStack {
                    if uploading { ProgressView() } else { Image(systemName: "photo") }
                    Text(uploading ? "Загрузка…" : "Загрузить из галереи")
                }
            }
            .disabled(uploading)
            if let e = uploadError {
                Text(e).font(.caption).foregroundColor(Brand.red)
            }
        } header: {
            Text("Картинка")
        } footer: {
            Text("JPG, PNG или WebP. Пустое поле — без картинки.")
        }
    }

    private var deleteSection: some View {
        Section {
            ActionButton("Удалить категорию", systemImage: "trash", role: .destructive, style: .plain,
                         confirm: ConfirmAction(title: "Удалить категорию «" + name + "»?",
                                                message: "Привязанные категории магазинов отвяжутся. Если в категории напрямую лежат товары, сервер не даст удалить.",
                                                confirmLabel: "Удалить", destructive: true)) {
                try await remove()
            }
        }
    }

    private func upload(_ img: UIImage) {
        guard let data = ImageDownscaler.jpeg(img) else {
            uploadError = "Не удалось подготовить фото"
            return
        }
        uploading = true
        uploadError = nil
        Task { @MainActor in
            do {
                let r = try await API.shared.upload("/api/admin/upload", fileData: data, fileName: "category.jpg",
                                                    mime: "image/jpeg", query: ["dir": "categories"])
                if let p = r["path"].nonEmptyString {
                    image = p
                } else {
                    uploadError = "Сервер не вернул путь к файлу"
                }
            } catch {
                if !APIError.isCancellation(error) { uploadError = APIError.describe(error) }
            }
            uploading = false
        }
    }

    private func requestBody(withLinks: Bool) -> [String: Any?] {
        let trimmedImage = image.trimmingCharacters(in: .whitespacesAndNewlines)
        var b: [String: Any?] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "image": trimmedImage,
            "sort_order": Int(sortText.trimmingCharacters(in: .whitespaces)) ?? 0,
            "is_active": isActive,
        ]
        if withLinks {
            b["links"] = links.selected.sorted()
        }
        return b
    }

    private func save() async throws {
        if let id = categoryId {
            let withLinks = links.baselineLoaded && links.dirty
            try await API.shared.put("/api/admin/categories/\(id)", body: requestBody(withLinks: withLinks))
        } else {
            try await API.shared.post("/api/admin/categories", body: requestBody(withLinks: false))
        }
        await onSaved()
        dismiss()
    }

    private func remove() async throws {
        guard let id = categoryId else { return }
        try await API.shared.delete("/api/admin/categories/\(id)")
        await onSaved()
        dismiss()
    }
}

/// Секция «Входят категории магазинов»: поиск и отметки.
struct ProductsLinksSection: View {
    @ObservedObject var links: ProductsLinksModel

    var body: some View {
        Section {
            TextField("Поиск: категория или магазин", text: $links.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            content
        } header: {
            Text("Входят категории магазинов (" + String(links.selected.count) + ")")
        } footer: {
            Text("Отмеченные категории магазинов войдут в эту общую. Категорию, у которой есть свой родитель внутри магазина, привязать нельзя. Изменения сохраняются кнопкой «Сохранить».")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch links.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
        case .failed(let msg):
            ErrorBanner(message: msg, retry: { Task { await links.load() } })
        case .empty:
            Text("Ничего не найдено").foregroundColor(Brand.muted)
        case .loaded:
            ForEach(links.items, id: \.stableID) { row in
                ProductsLinkRow(row: row,
                                isOn: links.selected.contains(row.id ?? -1),
                                enabled: links.baselineLoaded && !row["has_shop_parent"].boolValue) {
                    if let id = row.id { links.toggle(id) }
                }
            }
        }
    }
}

/// Одна категория магазина с отметкой.
struct ProductsLinkRow: View {
    let row: JSON
    let isOn: Bool
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isOn ? Brand.accent : Brand.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row["name"].nonEmptyString ?? "—")
                        .foregroundColor(enabled ? Brand.text : Brand.muted)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
                Spacer()
            }
        }
        .disabled(!enabled)
    }

    private var subtitle: String {
        let shop = row["shop"].nonEmptyString ?? "—"
        let n = Fmt.plural(row["products"].intValue, "товар", "товара", "товаров")
        if row["has_shop_parent"].boolValue {
            return shop + " · " + n + " · вложена в категорию магазина"
        }
        return shop + " · " + n
    }
}
