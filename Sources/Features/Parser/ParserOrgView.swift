import SwiftUI

/// Предпросмотр организации источника и импорт её в базу (модалка preview() сайта).
///
/// Импорт с фото и модификаторами идёт 1–3 минуты, а обычный запрос ждёт ответа 30 с,
/// поэтому POST /api/admin/parser/import уходит долгим запросом (DatabaseLongCall, 5 минут).
/// Сервер ставит ignore_user_abort — даже если связь оборвётся, импорт доработает.
struct ParserOrgView: View {
    let sourceKey: String
    let slug: String
    let citySlug: String
    let cityName: String

    @StateObject private var loader: ObjectLoader
    @State private var status = "paused"
    @State private var images = true
    @State private var modifiers = true
    @State private var importing = false
    @State private var importError: String?
    @State private var result: JSON = .null
    @State private var askImport = false

    init(sourceKey: String, slug: String, citySlug: String, cityName: String) {
        self.sourceKey = sourceKey
        self.slug = slug
        self.citySlug = citySlug
        self.cityName = cityName
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/parser/org",
                                                         query: ["source": sourceKey, "slug": slug]))
    }

    private var org: JSON { loader.data }

    private static let statusOptions: [PickerOption] = [
        PickerOption(value: "paused", label: "На паузе (проверить)"),
        PickerOption(value: "active", label: "Активна"),
        PickerOption(value: "pending", label: "На модерации"),
    ]

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            List {
                if let e = loader.lastRefreshError {
                    Section { ErrorBanner(message: e, retry: { Task { await loader.load() } }) }
                }
                headerSection
                resultSection
                importSection
                categoriesSection
                productsSection
                Section {
                    JSONInspectorView(org)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loader.load() }
        }
        .navigationTitle(org["name"].nonEmptyString ?? "Предпросмотр")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(importTitle, isPresented: $askImport, titleVisibility: .visible) {
            Button("Импортировать") { runImport() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(importSummary)
        }
        .task { await loader.loadIfNeeded() }
    }

    private var importTitle: String {
        let name: String = org["name"].nonEmptyString ?? slug
        return "Импортировать «" + name + "»?"
    }

    // MARK: - Секции

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                AsyncImageView(path: org["logo"].string, size: 64, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(org["name"].stringValue)
                        .font(.headline)
                    Text(placeText)
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
            }
            .padding(.vertical, 4)
            if let phone = org["phone"].nonEmptyString {
                KVRow("Телефон", Fmt.phone(phone), copyable: true)
            }
            KVRow("Часы", hoursText)
            KVRow("Товаров всего", Fmt.number(org["products_total"]))
        }
    }

    private var placeText: String {
        var parts: [String] = [cityName]
        if let a = org["address"].nonEmptyString { parts.append(a) }
        return parts.joined(separator: " · ")
    }

    /// «Пн 09:00–21:00, Вт …» (ключи 1..7 — дни недели, как на сайте).
    private var hoursText: String {
        let days = ["", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        var h = org["hours"].object
        if h.isEmpty {
            // PHP отдаёт массив вместо объекта, если ключи идут подряд с 0.
            for (i, v) in org["hours"].array.enumerated() { h[String(i)] = v }
        }
        if h.isEmpty { return "—" }
        let keys = h.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        var parts: [String] = []
        for k in keys {
            let i = Int(k) ?? 0
            let name = (i >= 1 && i <= 7) ? days[i] : k
            let v = h[k] ?? .null
            if v.isNull { continue }
            parts.append(name + " " + v["open"].stringValue + "–" + v["close"].stringValue)
        }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var resultSection: some View {
        if !result.isNull {
            Section {
                InfoBanner(resultText, systemImage: "checkmark.circle.fill", color: Brand.green)
                if let shopId = result["shop_id"].int, shopId > 0 {
                    NavigationLink {
                        ShopDetailView(id: shopId)
                    } label: {
                        Label("Открыть магазин #" + String(shopId), systemImage: "building.2")
                    }
                }
            }
        }
    }

    private var resultText: String {
        let verb = result["updated"].boolValue ? "Обновлено: " : "Импортировано: "
        let name = result["name"].nonEmptyString ?? org["name"].stringValue
        let count: String = Fmt.plural(result["products"].intValue, "товар", "товара", "товаров")
        var text: String = verb + name + " (" + count + ")"
        if result["city_id"].isNull {
            text += ". Город «" + cityName + "» не найден в справочнике — задайте его в карточке магазина."
        }
        return text
    }

    private var importSection: some View {
        Section {
            FormPicker("Статус после импорта", selection: $status, options: ParserOrgView.statusOptions)
            KVRow("Город", cityName)
            Toggle("Скачивать фото (логотип, обложка, фото товаров)", isOn: $images)
            Toggle("Импортировать модификаторы (медленнее)", isOn: $modifiers)
            if let e = importError {
                ErrorBanner(message: e, dismiss: { importError = nil })
            }
            Button {
                askImport = true
            } label: {
                HStack {
                    Spacer()
                    if importing {
                        ProgressView()
                        Text("Импорт…")
                    } else {
                        Image(systemName: "square.and.arrow.down")
                        Text(result.isNull ? "Импортировать" : "Импортировать ещё раз").bold()
                    }
                    Spacer()
                }
            }
            .disabled(importing || loader.state != .loaded)
        } header: {
            Text("Импорт")
        } footer: {
            Text(importing
                 ? "Идёт импорт. Не закрывайте экран — с фото и модификаторами это 1–3 минуты."
                 : "С фото и модификаторами импорт может занять 1–3 минуты. Повторный импорт той же организации обновит её.")
        }
    }

    @ViewBuilder
    private var categoriesSection: some View {
        let cats = org["categories"].array
        if !cats.isEmpty {
            Section("Категории (" + String(cats.count) + ")") {
                ForEach(cats, id: \.self) { c in
                    HStack {
                        Text(c["name"].stringValue)
                        Spacer()
                        Text(Fmt.number(c["count"]))
                            .foregroundColor(Brand.muted)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private var productsSection: some View {
        let items = org["products"].array
        if !items.isEmpty {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    ParserProductRow(product: pair.element)
                }
            } header: {
                Text("Товары")
            } footer: {
                if org["products_total"].intValue > items.count {
                    Text(shownText(items.count))
                }
            }
        }
    }

    private func shownText(_ shown: Int) -> String {
        let total: String = Fmt.number(org["products_total"])
        return "Показаны первые " + String(shown) + " из " + total + "."
    }

    // MARK: - Импорт

    private var importSummary: String {
        let st = ParserOrgView.statusOptions.first { $0.value == status }?.label ?? status
        var parts: [String] = ["Статус: " + st, "город: " + cityName]
        parts.append(images ? "с фото" : "без фото")
        parts.append(modifiers ? "с модификаторами" : "без модификаторов")
        return "Будут созданы магазин, категории и товары. " + parts.joined(separator: ", ") + "."
    }

    private func runImport() {
        guard !importing else { return }
        importing = true
        importError = nil
        let payload: [String: Any?] = [
            "source": sourceKey, "slug": slug, "city": citySlug, "city_name": cityName,
            "status": status, "images": images, "modifiers": modifiers,
        ]
        Task { @MainActor in
            do {
                let res = try await DatabaseLongCall.json("POST", "/api/admin/parser/import", body: payload,
                                                          timeout: 330, refreshVia: "/api/admin/parser/sources")
                importing = false
                result = res.result.data
                Haptics.success()
            } catch {
                importing = false
                if APIError.isCancellation(error) { return }
                Haptics.error()
                importError = ParserOrgView.describe(error)
            }
        }
    }

    /// Обрыв связи на долгом импорте ≠ провал: сервер доводит импорт до конца сам.
    private static func describe(_ error: Error) -> String {
        if let e = error as? APIError, e == .offline {
            return "Ответ не дождались — связь прервалась или сервер долго работал. Импорт мог завершиться на сервере: через пару минут проверьте раздел «Магазины» и только потом повторяйте."
        }
        return APIError.describe(error)
    }
}

/// Товар в предпросмотре: название, категория, цена.
struct ParserProductRow: View {
    let product: JSON

    init(product: JSON) {
        self.product = product
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product["name"].stringValue)
                    .font(.subheadline)
                if let c = product["category_name"].nonEmptyString {
                    Text(c)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            Spacer(minLength: 8)
            MoneyText(product["price"])
                .font(.subheadline)
        }
    }
}
