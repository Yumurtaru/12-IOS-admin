import SwiftUI

/// Лист выбора города (только включённые) с поиском — для баннеров и других форм.
///
/// ```
/// .sheet(isPresented: $pickCity) {
///     CitiesPickerSheet(allowAll: true) { id, name in cityId = id; cityName = name }
/// }
/// ```
/// `onPick(nil, nil)` — выбран вариант «Все города» (если `allowAll`).
struct CitiesPickerSheet: View {
    let allowAll: Bool
    let onPick: (Int?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PagedListModel(path: "/api/admin/cities", filters: ["active": "1"])

    init(allowAll: Bool = true, onPick: @escaping (Int?, String?) -> Void) {
        self.allowAll = allowAll
        self.onPick = onPick
    }

    private var header: AnyView? {
        guard allowAll else { return nil }
        return AnyView(allRow)
    }

    var body: some View {
        NavigationStack {
            AdminListScreen("Город", model: model, searchPrompt: "Найти город",
                            emptyText: "Ничего не найдено", header: header) { city in
                cityButton(city)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private var allRow: some View {
        Button {
            onPick(nil, nil)
            dismiss()
        } label: {
            Label("Все города", systemImage: "globe")
                .foregroundColor(Brand.accent)
        }
    }

    private func cityButton(_ city: JSON) -> some View {
        Button {
            onPick(city.id, city["name"].string)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(city["name"].stringValue)
                    .foregroundColor(Brand.text)
                if let region = city["region"].nonEmptyString {
                    Text(region)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
