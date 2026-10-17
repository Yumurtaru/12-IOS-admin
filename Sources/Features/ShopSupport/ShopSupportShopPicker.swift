import SwiftUI

/// Поиск организаций для переписки: GET /api/admin/shop-support/shops?q= →
/// СПИСОК (data — массив) [{id, name, status, phone, city, has_thread}], не больше 20.
/// Поиск по названию, #номеру и телефону — тот же, что у списка переписок.
@MainActor
final class ShopSupportShopSearch: ObservableObject {
    /// Строка поиска.
    @Published var query = ""
    /// Найденные организации.
    @Published private(set) var results: [JSON] = []
    /// Состояние.
    @Published private(set) var state: LoadState = .idle

    /// Сервер отдаёт не больше стольких строк.
    static let serverLimit = 20

    /// Загрузить по текущей строке. Зовётся из `.task(id: query)`: смена строки
    /// отменяет прежний вызов, пауза 0,35 с — чтобы не слать запрос на каждую букву.
    func load() async {
        if state != .idle {
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        if Task.isCancelled { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if results.isEmpty { state = .loading }
        do {
            let d = try await API.shared.get("/api/admin/shop-support/shops", query: ["q": q.isEmpty ? nil : q])
            if Task.isCancelled { return }
            results = d.array
            state = results.isEmpty ? .empty("Ничего не найдено") : .loaded
        } catch {
            if Task.isCancelled || APIError.isCancellation(error) { return }
            state = .failed(APIError.describe(error))
        }
    }
}

/// Список найденных организаций с поиском. `selectedIds` — отмеченные галочкой
/// (выбор адресатов рассылки), `onTap` — нажатие на строку.
struct ShopSupportShopSearchList: View {
    @ObservedObject var search: ShopSupportShopSearch
    let selectedIds: Set<Int>
    let onTap: (JSON) -> Void

    var body: some View {
        List {
            content
        }
        .listStyle(.plain)
        .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Название, #номер или телефон")
        .task(id: search.query) { await search.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch search.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 30)
                .listRowSeparator(.hidden)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await search.load() })
                .frame(minHeight: 240)
                .listRowSeparator(.hidden)
        case .empty(let text):
            EmptyStateView(title: text ?? "Ничего не найдено", systemImage: "magnifyingglass")
                .frame(minHeight: 240)
                .listRowSeparator(.hidden)
        case .loaded:
            ForEach(search.results, id: \.stableID) { shop in
                Button {
                    onTap(shop)
                } label: {
                    ShopSupportShopPickRow(shop: shop, selected: selectedIds.contains(shop["id"].intValue))
                }
            }
            if search.results.count >= ShopSupportShopSearch.serverLimit {
                Text("Показаны первые " + String(ShopSupportShopSearch.serverLimit) + " — уточните поиск.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                    .listRowSeparator(.hidden)
            }
        }
    }
}

/// Строка организации в поиске.
struct ShopSupportShopPickRow: View {
    let shop: JSON
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shop["name"].nonEmptyString ?? ("Организация #" + shop["id"].stringValue))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                    .lineLimit(1)
                Text(meta)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if shop["has_thread"].boolValue {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Brand.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts: [String] = ["#" + shop["id"].stringValue, ShopsLabels.status(shop["status"].string)]
        if let c = shop["city"].nonEmptyString { parts.append(c) }
        if let p = shop["phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        return parts.joined(separator: " · ")
    }
}

/// «Новое сообщение»: выбрать организацию — после закрытия листа откроется её чат
/// (переписки может ещё не быть — первое сообщение её создаст).
struct ShopSupportShopPicker: View {
    let onPick: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = ShopSupportShopSearch()

    init(onPick: @escaping (Int) -> Void) {
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            ShopSupportShopSearchList(search: search, selectedIds: [], onTap: pick)
                .navigationTitle("Новое сообщение")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отмена") { dismiss() }
                    }
                }
        }
    }

    private func pick(_ shop: JSON) {
        guard let id = shop["id"].int, id > 0 else { return }
        onPick(id)
        dismiss()
    }
}
