import SwiftUI

/// Готовый экран списка поверх PagedListModel: поиск, чипы фильтров, строки,
/// переход к деталям, «потяни, чтобы обновить», догрузка страниц, «Всего: N».
///
/// Экран НЕ содержит NavigationStack (его даёт вкладка/меню) и сам ставит
/// navigationTitle. Кнопки в шапке добавляйте снаружи через `.toolbar`.
///
/// ```
/// struct ShopsRootView: View {
///     @StateObject private var model = PagedListModel(path: "/api/admin/shops")
///     var body: some View {
///         AdminListScreen("Магазины", model: model,
///                         filters: [ListFilter(key: "status", title: "Статус", options: statusOptions)],
///                         row: { ShopRow(shop: $0) },
///                         destination: { ShopDetailView(id: $0.id ?? 0) })
///     }
/// }
/// ```
/// Без перехода к деталям — та же запись без `destination:`.
struct AdminListScreen<Row: View, Destination: View>: View {
    @ObservedObject var model: PagedListModel
    let title: String
    let searchPrompt: String?
    let filters: [ListFilter]
    let emptyText: String
    let header: AnyView?
    let row: (JSON) -> Row
    let destination: ((JSON) -> Destination)?

    /// - Parameters:
    ///   - title: заголовок экрана;
    ///   - model: загрузчик (держите его в @StateObject);
    ///   - searchPrompt: подсказка поиска, nil — без поиска;
    ///   - filters: меню-фильтры над списком;
    ///   - emptyText: текст пустого списка;
    ///   - header: что показать над строками (сводка, очередь и т.п.);
    ///   - row: вид строки по JSON;
    ///   - destination: экран деталей по JSON строки.
    init(_ title: String, model: PagedListModel, searchPrompt: String? = "Поиск",
         filters: [ListFilter] = [], emptyText: String = "Ничего не найдено", header: AnyView? = nil,
         @ViewBuilder row: @escaping (JSON) -> Row,
         @ViewBuilder destination: @escaping (JSON) -> Destination) {
        self.title = title
        self.model = model
        self.searchPrompt = searchPrompt
        self.filters = filters
        self.emptyText = emptyText
        self.header = header
        self.row = row
        self.destination = destination
    }

    var body: some View {
        content
            .navigationTitle(title)
            .modifier(SearchModifier(prompt: searchPrompt, text: $model.searchText))
            .task { await model.loadIfNeeded() }
    }

    private var content: some View {
        List {
            if !filters.isEmpty {
                FilterChipsRow(filters: filters, model: model)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
            }
            if let header = header {
                header
            }
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            stateSection
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
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
            EmptyStateView(title: text ?? emptyText, systemImage: "tray")
                .frame(minHeight: 260)
                .listRowSeparator(.hidden)
        case .loaded:
            rows
            ListFooter(model: model)
        }
    }

    private var rows: some View {
        ForEach(model.items, id: \.stableID) { item in
            rowLink(item)
                .task { await model.loadMoreIfNeeded(current: item) }
        }
    }

    @ViewBuilder
    private func rowLink(_ item: JSON) -> some View {
        if let dest = destination {
            NavigationLink(destination: dest(item)) { row(item) }
        } else {
            row(item)
        }
    }
}

extension AdminListScreen where Destination == EmptyView {
    /// Список без перехода к деталям.
    init(_ title: String, model: PagedListModel, searchPrompt: String? = "Поиск",
         filters: [ListFilter] = [], emptyText: String = "Ничего не найдено", header: AnyView? = nil,
         @ViewBuilder row: @escaping (JSON) -> Row) {
        self.title = title
        self.model = model
        self.searchPrompt = searchPrompt
        self.filters = filters
        self.emptyText = emptyText
        self.header = header
        self.row = row
        self.destination = nil
    }
}

/// Подвал списка: догрузка, ошибка догрузки, «Всего: N».
struct ListFooter: View {
    @ObservedObject var model: PagedListModel

    var body: some View {
        Group {
            if model.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let err = model.loadMoreError {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Label(err + " Нажмите, чтобы повторить.", systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundColor(Brand.red)
                }
            } else if model.hasMore {
                Button("Показать ещё") { Task { await model.loadMore() } }
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

/// Ряд чипов-меню фильтров.
struct FilterChipsRow: View {
    let filters: [ListFilter]
    @ObservedObject var model: PagedListModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { f in
                    FilterChip(filter: f, model: model)
                }
            }
        }
    }
}

/// Один чип-меню фильтра.
struct FilterChip: View {
    let filter: ListFilter
    @ObservedObject var model: PagedListModel

    private var selected: PickerOption? {
        guard let v = model.filter(filter.key) else { return nil }
        return filter.options.first { $0.value == v }
    }

    var body: some View {
        Menu {
            if let all = filter.allLabel {
                Button {
                    model.setFilter(filter.key, nil)
                } label: {
                    if selected == nil { Label(all, systemImage: "checkmark") } else { Text(all) }
                }
            }
            ForEach(filter.options) { opt in
                Button {
                    Haptics.tap()
                    model.setFilter(filter.key, opt.value)
                } label: {
                    if selected?.value == opt.value { Label(opt.label, systemImage: "checkmark") } else { Text(opt.label) }
                }
            }
        } label: {
            chipLabel
        }
    }

    private var chipLabel: some View {
        let active = selected != nil
        let text = selected.map { filter.title + ": " + $0.label } ?? filter.title
        return HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(active ? Brand.accent.opacity(0.15) : Brand.chip)
        .foregroundColor(active ? Brand.accent : Brand.text)
        .clipShape(Capsule())
    }
}

/// .searchable только когда задана подсказка.
private struct SearchModifier: ViewModifier {
    let prompt: String?
    @Binding var text: String

    func body(content: Content) -> some View {
        if let p = prompt {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: p)
        } else {
            content
        }
    }
}
