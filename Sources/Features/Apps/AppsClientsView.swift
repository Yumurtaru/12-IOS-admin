import SwiftUI

// MARK: - Модель списка

/// Список клиентов GET /api/admin/app-clients: поиск с задержкой, фильтры, сортировка,
/// подгрузка страниц без дублей. Новый запрос отменяет предыдущий (и первую страницу, и догрузку);
/// ответ устаревшего запроса, даже если он успел прийти, отбрасывается по номеру поколения.
@MainActor
final class AppClientsModel: ObservableObject {
    static let activityOptions: [PickerOption] = [
        PickerOption(value: "active", label: "Активные"),
        PickerOption(value: "sleeping", label: "Спящие"),
        PickerOption(value: "lost", label: "Ушедшие"),
        PickerOption(value: "never", label: "Нет данных"),
    ]
    static let stateOptions: [PickerOption] = [
        PickerOption(value: "installed", label: "Установлено"),
        PickerOption(value: "none", label: "Не установлено"),
        PickerOption(value: "outdated", label: "Устарела"),
        PickerOption(value: "below_min", label: "Ниже минимальной"),
        PickerOption(value: "unknown", label: "Версия неизвестна"),
    ]
    static let platformOptions: [PickerOption] = [
        PickerOption(value: "android", label: "Android"),
        PickerOption(value: "ios", label: "iOS"),
    ]
    static let appOptions: [PickerOption] = [
        PickerOption(value: "client", label: "Покупатель"),
        PickerOption(value: "seller", label: "Продавец"),
        PickerOption(value: "courier", label: "Курьер"),
    ]
    static let sortOptions: [PickerOption] = [
        PickerOption(value: "last_seen", label: "По последнему визиту"),
        PickerOption(value: "created", label: "По регистрации"),
        PickerOption(value: "name", label: "По имени"),
    ]

    @Published private(set) var items: [JSON] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var isLoadingMore = false
    @Published private(set) var loadMoreError: String?
    @Published private(set) var refreshError: String?
    @Published private(set) var total: Int?
    @Published private(set) var hasMore = false
    @Published private(set) var filters: [String: String] = [:]
    @Published private(set) var sort = "last_seen"
    @Published private(set) var dir = "desc"
    /// Текст поиска: уходит параметром `q` через 0,4 с после последнего ввода.
    @Published var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }

    private var page = 1
    private var generation = 0
    private var firstTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    func filter(_ key: String) -> String { filters[key] ?? "" }

    // MARK: Управление

    func loadIfNeeded() async {
        if state == .idle { await startFirst(spinner: true) }
    }

    /// «Повторить» после ошибки.
    func reload() async {
        await startFirst(spinner: items.isEmpty)
    }

    /// Потянули вниз: строки остаются до ответа.
    func refresh() async {
        await startFirst(spinner: false)
    }

    func setFilter(_ key: String, _ value: String) {
        if value.isEmpty { filters[key] = nil } else { filters[key] = value }
        resetAndReload()
    }

    func setSort(_ value: String) {
        guard value != sort else { return }
        sort = value
        resetAndReload()
    }

    func toggleDir() {
        dir = dir == "desc" ? "asc" : "desc"
        resetAndReload()
    }

    /// Догрузить, когда на экране последняя строка.
    func loadMoreIfNeeded(current item: JSON) {
        guard let last = items.last, last.stableID == item.stableID else { return }
        loadMore()
    }

    func loadMore() {
        guard hasMore, !isLoadingMore, state == .loaded else { return }
        isLoadingMore = true
        loadMoreError = nil
        let gen = generation
        let next = page + 1
        moreTask = Task { await self.fetchMore(gen, next) }
    }

    // MARK: Внутреннее

    private func resetAndReload() {
        searchTask?.cancel()
        state = .loading
        items = []
        total = nil
        hasMore = false
        refreshError = nil
        Task { await startFirst(spinner: true) }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await self?.searchFired()
        }
    }

    private func searchFired() async {
        state = .loading
        items = []
        total = nil
        hasMore = false
        refreshError = nil
        await startFirst(spinner: true)
    }

    private func query(page p: Int) -> [String: String?] {
        var q: [String: String?] = [:]
        for (k, v) in filters { q[k] = v }
        q["sort"] = sort
        q["dir"] = dir
        let t = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { q["q"] = String(t.prefix(100)) }
        q["page"] = String(p)
        return q
    }

    private func startFirst(spinner: Bool) async {
        firstTask?.cancel()
        moreTask?.cancel()
        generation += 1
        let gen = generation
        isLoadingMore = false
        loadMoreError = nil
        if spinner { state = .loading }
        let task = Task { await self.fetchFirst(gen) }
        firstTask = task
        await task.value
    }

    private func fetchFirst(_ gen: Int) async {
        do {
            let d = try await API.shared.get("/api/admin/app-clients", query: query(page: 1))
            guard gen == generation else { return }
            let list = d["items"].array
            items = unique(list, existing: [])
            page = 1
            refreshError = nil
            applyPaging(d, received: list.count)
            state = items.isEmpty ? .empty(nil) : .loaded
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            let msg = AppsFmt.errorText(error)
            if items.isEmpty {
                state = .failed(msg)
            } else {
                refreshError = msg
                state = .loaded
            }
        }
    }

    private func fetchMore(_ gen: Int, _ next: Int) async {
        do {
            let d = try await API.shared.get("/api/admin/app-clients", query: query(page: next))
            guard gen == generation else { return }
            let list = d["items"].array
            items.append(contentsOf: unique(list, existing: items))
            page = next
            applyPaging(d, received: list.count)
        } catch {
            if gen == generation && !APIError.isCancellation(error) {
                loadMoreError = AppsFmt.errorText(error)
            }
        }
        if gen == generation { isLoadingMore = false }
    }

    /// Строки без повторов по id (и относительно уже загруженных).
    private func unique(_ list: [JSON], existing: [JSON]) -> [JSON] {
        var seen = Set(existing.map { $0.stableID })
        var out: [JSON] = []
        for row in list where !seen.contains(row.stableID) {
            seen.insert(row.stableID)
            out.append(row)
        }
        return out
    }

    private func applyPaging(_ d: JSON, received: Int) {
        let t = d["total"].int
        total = t
        if received == 0 {
            hasMore = false
        } else if let pages = d["pages"].int {
            hasMore = page < pages
        } else if let t = t {
            hasMore = items.count < t
        } else {
            hasMore = false
        }
    }
}

// MARK: - Вкладка «Клиенты»

struct AppsClientsView: View {
    @ObservedObject var model: AppClientsModel

    var body: some View {
        List {
            chipsRow
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            stateSection
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Имя, телефон, почта, id")
        .task { await model.loadIfNeeded() }
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                AppsFilterChip(title: "Активность", options: AppClientsModel.activityOptions,
                               selected: model.filter("activity"), allLabel: "Все",
                               onSelect: { model.setFilter("activity", $0) })
                AppsFilterChip(title: "Приложение", options: AppClientsModel.stateOptions,
                               selected: model.filter("app_state"), allLabel: "Все",
                               onSelect: { model.setFilter("app_state", $0) })
                AppsFilterChip(title: "Платформа", options: AppClientsModel.platformOptions,
                               selected: model.filter("platform"), allLabel: "Все",
                               onSelect: { model.setFilter("platform", $0) })
                AppsFilterChip(title: "Какое", options: AppClientsModel.appOptions,
                               selected: model.filter("app"), allLabel: "Все",
                               onSelect: { model.setFilter("app", $0) })
                AppsFilterChip(title: "Сортировка", options: AppClientsModel.sortOptions,
                               selected: model.sort, allLabel: nil,
                               onSelect: { model.setSort($0) })
                Button {
                    Haptics.tap()
                    model.toggleDir()
                } label: {
                    Image(systemName: model.dir == "desc" ? "arrow.down" : "arrow.up")
                        .padding(8)
                        .background(Brand.chip)
                        .foregroundColor(Brand.text)
                        .clipShape(Circle())
                }
                .accessibilityLabel(model.dir == "desc" ? "Порядок: по убыванию" : "Порядок: по возрастанию")
            }
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.reload() })
                .frame(minHeight: 260)
                .listRowSeparator(.hidden)
        case .empty(let text):
            EmptyStateView(title: text ?? "Клиентов с такими условиями нет", systemImage: "iphone")
                .frame(minHeight: 260)
                .listRowSeparator(.hidden)
        case .loaded:
            ForEach(model.items, id: \.stableID) { item in
                NavigationLink(destination: AppClientDetailView(client: item)) {
                    AppClientRow(client: item)
                }
                .task { model.loadMoreIfNeeded(current: item) }
            }
            AppsClientsFooter(model: model)
        }
    }
}

/// Подвал списка: догрузка, ошибка догрузки, «Всего».
struct AppsClientsFooter: View {
    @ObservedObject var model: AppClientsModel

    var body: some View {
        Group {
            if model.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let err = model.loadMoreError {
                Button {
                    model.loadMore()
                } label: {
                    Label(err + " Нажмите, чтобы повторить.", systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundColor(Brand.red)
                }
            } else if model.hasMore {
                Button("Показать ещё") { model.loadMore() }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
            } else if let t = model.total {
                Text("Всего: " + Fmt.number(t))
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                    .frame(maxWidth: .infinity)
            }
        }
        .listRowSeparator(.hidden)
        .padding(.vertical, 6)
    }
}

// MARK: - Строка

/// Значок «приложение · платформа версия» с цветом состояния версии.
struct AppsAppChip: View {
    let app: JSON

    private var text: String {
        let title = AppsFmt.appTitle(app["app"].string)
        let platform = AppsFmt.platformTitle(app["platform"].string)
        let version = app["version"].nonEmptyString ?? "версия ?"
        return title + " · " + platform + " " + version
    }

    var body: some View {
        let state = app["state"].string
        HStack(spacing: 4) {
            if AppsFmt.isOutdated(state) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
            }
            Text(text).lineLimit(2)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(AppsFmt.stateColor(state))
        .background(AppsFmt.stateColor(state).opacity(0.15))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text + ", " + AppsFmt.stateTitle(state))
    }
}

struct AppClientRow: View {
    let client: JSON

    private let maxChips = 3

    var body: some View {
        let apps = client["apps"].array
        let activity = client["activity"].string
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.personName(client["name"].string, hidden: false))
                    .font(.headline)
                    .foregroundColor(Brand.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                StatusBadge(AppsFmt.activityTitle(activity), color: AppsFmt.activityColor(activity))
            }
            if let phone = client["phone"].nonEmptyString {
                Text(phone).font(.subheadline).foregroundColor(Brand.muted)
            }
            Text(AppsFmt.seen(daysSince: client["days_since"].int, lastSeen: client["last_seen_at"].string))
                .font(.footnote)
                .foregroundColor(Brand.muted)
            if apps.isEmpty {
                Text(client["has_app"].boolValue ? "Приложение есть, данных об устройстве нет" : "Без приложения")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(Array(apps.prefix(maxChips).enumerated()), id: \.offset) { pair in
                    AppsAppChip(app: pair.element)
                }
                if apps.count > maxChips {
                    Text("и ещё " + String(apps.count - maxChips))
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Детали клиента

/// Карточка клиента: данные, активность на сайте и в приложении, все устройства.
/// Данные берутся из строки списка (отдельной ручки деталей у контракта нет).
struct AppClientDetailView: View {
    let client: JSON

    private var apps: [JSON] { client["apps"].array }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header
                infoCard
                activityCard
                devicesCard
                if let id = client.id {
                    NavigationLink(destination: UserDetailView(id: id)) {
                        Label("Открыть карточку пользователя", systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Клиент")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        let activity = client["activity"].string
        return SectionCard {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.personName(client["name"].string, hidden: false))
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 4)
                StatusBadge(AppsFmt.activityTitle(activity), color: AppsFmt.activityColor(activity))
            }
            Text(AppsFmt.seen(daysSince: client["days_since"].int, lastSeen: client["last_seen_at"].string))
                .font(.subheadline)
                .foregroundColor(Brand.muted)
        }
    }

    private var infoCard: some View {
        SectionCard("О клиенте") {
            KVRow("ID", client["id"].string, copyable: true)
            KVRow("Телефон", client["phone"].nonEmptyString)
            KVRow("Почта", client["email"].nonEmptyString)
            KVRow("Статус", Fmt.statusLabel(client["status"].string))
            KVRow("Зарегистрирован", AppsFmt.whenWithExact(client["created_at"].string))
            KVRow("Push включён", Fmt.yesNo(client["push_enabled"].bool))
            KVRow("Уведомления разрешены", Fmt.yesNo(client["notify_allowed"].bool))
        }
    }

    private var activityCard: some View {
        SectionCard("Активность") {
            KVRow("Последний визит", AppsFmt.whenWithExact(client["last_seen_at"].string))
            KVRow("На сайте", AppsFmt.whenWithExact(client["last_web_at"].string))
            KVRow("В приложении", AppsFmt.whenWithExact(client["last_app_at"].string))
        }
    }

    private var devicesCard: some View {
        SectionCard("Устройства (" + String(apps.count) + ")") {
            if apps.isEmpty {
                let text = client["has_app"].boolValue
                    ? "Приложение у клиента есть (включены push), но устройство не сообщило версию."
                    : "Данных об установке приложения нет."
                Text(text).font(.subheadline).foregroundColor(Brand.muted)
            } else {
                ForEach(Array(apps.enumerated()), id: \.offset) { pair in
                    AppsDeviceBlock(device: pair.element)
                }
            }
        }
    }
}

/// Одно установленное приложение клиента.
struct AppsDeviceBlock: View {
    let device: JSON

    var body: some View {
        let state = device["state"].string
        let build = device["build"].nonEmptyString
        let version = device["version"].nonEmptyString
        let versionText = version.map { v in build.map { v + " (сборка " + $0 + ")" } ?? v }
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text(AppsFmt.appTitle(device["app"].string) + " · " + AppsFmt.platformTitle(device["platform"].string))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                StatusBadge(AppsFmt.stateTitle(state), color: AppsFmt.stateColor(state))
            }
            KVRow("Версия", versionText)
            KVRow("ОС", device["os_version"].nonEmptyString)
            KVRow("Модель", device["device_model"].nonEmptyString)
            KVRow("Первый раз", AppsFmt.whenWithExact(device["first_seen"].string))
            KVRow("Последний раз", AppsFmt.whenWithExact(device["last_seen"].string))
        }
    }
}
