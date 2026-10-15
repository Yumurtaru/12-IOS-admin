import SwiftUI

/// Выбор организации из лёгкого списка GET /api/admin/shops/options
/// ([{id, name}], без заблокированных, до 1000, по алфавиту) с поиском по
/// названию на телефоне. Для разделов, где нужно выбрать магазин (выплаты,
/// рассылки, отчёты):
///
/// ```
/// NavigationLink(destination: ShopsOptionsPicker(selectedId: shopId) { id, name in
///     shopId = id; shopName = name
/// }) { Text(shopName.isEmpty ? "Выбрать магазин" : shopName) }
/// ```
/// После выбора экран закрывается сам.
struct ShopsOptionsPicker: View {
    let selectedId: Int?
    let onPick: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [JSON] = []
    @State private var state: LoadState = .idle
    @State private var query = ""

    init(selectedId: Int? = nil, onPick: @escaping (Int, String) -> Void) {
        self.selectedId = selectedId
        self.onPick = onPick
    }

    private var filtered: [JSON] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return items }
        return items.filter { $0["name"].stringValue.lowercased().contains(q) }
    }

    var body: some View {
        AsyncContent(state: state, emptyText: "Организаций нет", retry: { await load() }) {
            List {
                ForEach(filtered, id: \.stableID) { shop in
                    row(shop)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Организация")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название")
        .task { if state == .idle { await load() } }
    }

    private func row(_ shop: JSON) -> some View {
        let sid = shop.id ?? 0
        let name = shop["name"].stringValue
        return Button {
            Haptics.tap()
            onPick(sid, name)
            dismiss()
        } label: {
            HStack {
                Text(name).foregroundColor(Brand.text)
                Spacer()
                if sid == selectedId {
                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                }
            }
        }
    }

    private func load() async {
        if items.isEmpty { state = .loading }
        do {
            let data = try await API.shared.get("/api/admin/shops/options")
            items = data.array
            state = items.isEmpty ? .empty(nil) : .loaded
        } catch {
            if APIError.isCancellation(error) { return }
            state = items.isEmpty ? .failed(APIError.describe(error)) : .loaded
        }
    }
}
