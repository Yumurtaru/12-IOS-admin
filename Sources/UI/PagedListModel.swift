import SwiftUI

/// Постраничный загрузчик списка с поиском и фильтрами.
///
/// Понимает все формы ответов админки:
///   * `{items:[…], total, page, pages}` (большинство /api/admin/*),
///   * `{items:[…], total, page, per, pages, counts}` (регистрации),
///   * `{items:[…]}` без страниц (user-topups), объект с `has_more`,
///   * страницы в `meta` (`meta.total/pages/page`), * простой массив `[…]`.
/// Элементы ищутся в `itemsKey`, а если он не задан — в data (массив) либо
/// в data.items / data.rows / data.list / data.data.
///
/// ```
/// @StateObject private var model = PagedListModel(path: "/api/admin/shops")
/// // фильтр «Статус»: model.setFilter("status", "active")  (nil — «Все»)
/// // поиск: model.searchText = "пекарня" (уходит как q, с задержкой 0,4 с)
/// ```
/// Поздние ответы старых запросов (сменили фильтр, пока грузилось) отбрасываются.
@MainActor
final class PagedListModel: ObservableObject {
    /// Загруженные строки (всех страниц), без дублей по id.
    @Published private(set) var items: [JSON] = []
    /// Состояние первой страницы.
    @Published private(set) var state: LoadState = .idle
    /// Идёт догрузка следующей страницы.
    @Published private(set) var isLoadingMore = false
    /// Ошибка догрузки (список при этом остаётся).
    @Published private(set) var loadMoreError: String?
    /// Ошибка обновления при уже показанном списке.
    @Published private(set) var refreshError: String?
    /// Всего записей по данным сервера (nil — сервер не сообщил).
    @Published private(set) var total: Int?
    /// Есть ли ещё страницы.
    @Published private(set) var hasMore = false
    /// Поле data ответа ПЕРВОЙ страницы целиком — для counts, stats, total_paid и т.п.
    @Published private(set) var lastData: JSON = .null
    /// Поле meta ответа первой страницы.
    @Published private(set) var lastMeta: JSON = .null
    /// Значения фильтров: имя параметра запроса → значение. Менять через setFilter.
    @Published private(set) var filters: [String: String] = [:]
    /// Текст поиска (уходит параметром `searchParam` с задержкой).
    @Published var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }

    /// Путь списка, например "/api/admin/shops".
    let path: String
    /// Ключ массива внутри data (nil — автоопределение).
    let itemsKey: String?
    /// Имя параметра поиска (nil — поиска нет).
    let searchParam: String?
    /// Имя параметра страницы.
    let pageParam: String
    /// Постоянные параметры запроса (не фильтры).
    var baseQuery: [String: String]
    /// Параметр и значение размера страницы, если ручка его принимает (["per": "50"]).
    let perPage: (param: String, value: Int)?

    private var page = 1
    private var generation = 0
    private var searchTask: Task<Void, Never>?

    /// - Parameters:
    ///   - path: путь GET-списка;
    ///   - itemsKey: где лежит массив в data (nil — автоматически);
    ///   - searchParam: имя параметра поиска ("q"), nil — без поиска;
    ///   - pageParam: имя параметра страницы ("page");
    ///   - baseQuery: постоянные параметры;
    ///   - filters: начальные значения фильтров;
    ///   - perPage: размер страницы, если ручка его принимает.
    init(path: String, itemsKey: String? = nil, searchParam: String? = "q", pageParam: String = "page",
         baseQuery: [String: String] = [:], filters: [String: String] = [:],
         perPage: (param: String, value: Int)? = nil) {
        self.path = path
        self.itemsKey = itemsKey
        self.searchParam = searchParam
        self.pageParam = pageParam
        self.baseQuery = baseQuery
        self.filters = filters
        self.perPage = perPage
    }

    // MARK: - Управление

    /// Загрузить первую страницу, если ещё не загружали.
    func loadIfNeeded() async {
        if state == .idle { await reload() }
    }

    /// Загрузить заново с первой страницы (спиннер, если строк ещё нет).
    func reload() async {
        await loadFirstPage(showSpinner: items.isEmpty)
    }

    /// Обновить «потянув вниз»: строки остаются на экране до ответа.
    func refresh() async {
        await loadFirstPage(showSpinner: false)
    }

    /// Установить фильтр (nil или "" — снять) и перезагрузить.
    func setFilter(_ key: String, _ value: String?) {
        let v = value ?? ""
        if v.isEmpty { filters[key] = nil } else { filters[key] = v }
        items = []
        Task { await reload() }
    }

    /// Значение фильтра или nil.
    func filter(_ key: String) -> String? { filters[key] }

    /// Догрузить, если показана последняя строка.
    func loadMoreIfNeeded(current item: JSON) async {
        guard let last = items.last, last.stableID == item.stableID else { return }
        await loadMore()
    }

    /// Догрузить следующую страницу.
    func loadMore() async {
        guard hasMore, !isLoadingMore, state == .loaded else { return }
        isLoadingMore = true
        loadMoreError = nil
        let gen = generation
        let nextPage = page + 1
        do {
            let res = try await API.shared.getResult(path, query: query(page: nextPage))
            guard gen == generation else { return }
            let newItems = extractItems(res.data)
            appendUnique(newItems)
            page = nextPage
            updatePaging(data: res.data, meta: res.meta, received: newItems.count)
        } catch {
            if gen == generation && !APIError.isCancellation(error) {
                loadMoreError = APIError.describe(error)
            }
        }
        if gen == generation { isLoadingMore = false }
    }

    /// Заменить строку с тем же id (после действия над объектом).
    func replace(_ item: JSON) {
        guard let idx = items.firstIndex(where: { $0.stableID == item.stableID }) else { return }
        items[idx] = item
    }

    /// Убрать строку по id (удалили / ушла из фильтра).
    func remove(id: Int) {
        let key = String(id)
        items.removeAll { $0.stableID == key }
        if let t = total { total = max(0, t - 1) }
        if items.isEmpty && state == .loaded { state = .empty(nil) }
    }

    /// Изменить строку по id на месте: `model.update(id: 5) { $0 = newJSON }`.
    func update(id: Int, _ change: (inout JSON) -> Void) {
        let key = String(id)
        guard let idx = items.firstIndex(where: { $0.stableID == key }) else { return }
        var row = items[idx]
        change(&row)
        items[idx] = row
    }

    // MARK: - Внутреннее

    private func query(page p: Int) -> [String: String?] {
        var q: [String: String?] = [:]
        for (k, v) in baseQuery { q[k] = v }
        for (k, v) in filters { q[k] = v }
        if let sp = searchParam {
            let t = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { q[sp] = t }
        }
        q[pageParam] = String(p)
        if let pp = perPage { q[pp.param] = String(pp.value) }
        return q
    }

    private func loadFirstPage(showSpinner: Bool) async {
        generation += 1
        let gen = generation
        if showSpinner { state = .loading }
        isLoadingMore = false
        loadMoreError = nil
        do {
            let res = try await API.shared.getResult(path, query: query(page: 1))
            guard gen == generation else { return }
            let list = extractItems(res.data)
            items = []
            appendUnique(list)
            page = 1
            lastData = res.data
            lastMeta = res.meta
            refreshError = nil
            updatePaging(data: res.data, meta: res.meta, received: list.count)
            state = items.isEmpty ? .empty(nil) : .loaded
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            let msg = APIError.describe(error)
            if items.isEmpty {
                state = .failed(msg)
            } else {
                refreshError = msg
                state = .loaded
            }
        }
    }

    private func extractItems(_ data: JSON) -> [JSON] {
        if let k = itemsKey { return data[k].array }
        if data.isArray { return data.array }
        for k in ["items", "rows", "list", "data"] where data[k].isArray {
            return data[k].array
        }
        return []
    }

    private func appendUnique(_ list: [JSON]) {
        var seen = Set(items.map { $0.stableID })
        for row in list where !seen.contains(row.stableID) {
            seen.insert(row.stableID)
            items.append(row)
        }
    }

    private func updatePaging(data: JSON, meta: JSON, received: Int) {
        let src = data.isObject ? data : .null
        let t = src["total"].int ?? meta["total"].int
        total = t
        let pages = src["pages"].int ?? meta["pages"].int ?? meta["last_page"].int
        if received == 0 {
            hasMore = false
        } else if let pages = pages {
            hasMore = page < pages
        } else if let more = src["has_more"].bool ?? meta["has_more"].bool {
            hasMore = more
        } else if let t = t {
            hasMore = items.count < t
        } else {
            hasMore = false
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await self?.reload()
        }
    }
}

/// Фильтр-меню для AdminListScreen: параметр запроса и варианты значений.
///
/// ```
/// ListFilter(key: "status", title: "Статус", options: [
///     PickerOption(value: "active", label: "Активные"),
///     PickerOption(value: "blocked", label: "Заблокированные"),
/// ])
/// ```
struct ListFilter: Identifiable {
    /// Имя параметра запроса.
    let key: String
    /// Подпись чипа, когда ничего не выбрано.
    let title: String
    /// Варианты.
    let options: [PickerOption]
    /// Подпись варианта «без фильтра» (nil — варианта нет, выбор обязателен).
    var allLabel: String? = "Все"

    var id: String { key }

    /// - Parameters:
    ///   - key: параметр запроса;
    ///   - title: подпись чипа;
    ///   - options: варианты;
    ///   - allLabel: подпись «без фильтра» (nil — нельзя снять).
    init(key: String, title: String, options: [PickerOption], allLabel: String? = "Все") {
        self.key = key
        self.title = title
        self.options = options
        self.allLabel = allLabel
    }
}

/// Вариант выбора: значение для сервера и подпись для человека.
struct PickerOption: Hashable, Identifiable {
    /// Значение (уходит на сервер).
    let value: String
    /// Подпись.
    let label: String

    var id: String { value }

    init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}
