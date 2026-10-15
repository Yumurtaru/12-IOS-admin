import SwiftUI

/// Раздел «Парсинг» (admin/parser.php): импорт организаций из внешних агрегаторов.
///
/// Шаги как на сайте: источник → город → организации → предпросмотр → «Импортировать».
/// GET  /api/admin/parser/sources                → [{key, name, site}]
/// GET  /api/admin/parser/cities ?source         → [{slug, name}]   (кэш на час)
/// GET  /api/admin/parser/orgs   ?source&city    → [{slug, name, logo, closed}]
/// GET  /api/admin/parser/org    ?source&slug    → {slug, name, logo, cover, address, phone, hours{1..7:{open,close}},
///                                                  categories[{name,count}], products_total, products[первые 60]}
/// POST /api/admin/parser/import {source, slug, city, city_name, status, images, modifiers}
///                                               → {shop_id, products, updated, city_id, name}
struct ParserRootView: View {
    let openId: Int?

    @StateObject private var loader = ObjectLoader(path: "/api/admin/parser/sources")

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var sources: [JSON] { loader.data.array }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Источников нет", retry: { await loader.load() }) {
            List {
                Section {
                    Text("Импорт организаций из внешних агрегаторов доставки. Выберите источник и город — появятся организации; откройте организацию для предпросмотра и нажмите «Импортировать». Создаются магазин, категории, товары (с фото, описанием, ценой и модификаторами), часы работы и адрес; город подставляется из справочника.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                    InfoBanner("Импортируйте только данные, на перенос которых у вас есть право (например, при онбординге тех же заведений на вашу площадку).",
                               systemImage: "exclamationmark.triangle", color: Brand.amber)
                }
                Section("Источник") {
                    if sources.isEmpty {
                        Text("Источников нет").foregroundColor(Brand.muted)
                    }
                    ForEach(sources, id: \.self) { s in
                        NavigationLink {
                            ParserCitiesView(source: s)
                        } label: {
                            ParserSourceRow(source: s)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await loader.load() }
        }
        .navigationTitle("Парсинг")
        .task { await loader.loadIfNeeded() }
    }
}

/// Строка источника: «К порогу (k-porogu.com)».
struct ParserSourceRow: View {
    let source: JSON

    init(source: JSON) {
        self.source = source
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "storefront")
                .foregroundColor(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(source["name"].stringValue)
                    .font(.subheadline.weight(.semibold))
                if let site = source["site"].nonEmptyString {
                    Text(site)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
        }
    }
}

/// Города источника (поиск по названию).
struct ParserCitiesView: View {
    let source: JSON

    @StateObject private var loader: ObjectLoader
    @State private var query = ""

    init(source: JSON) {
        self.source = source
        let key = source["key"].stringValue
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/parser/cities", query: ["source": key]))
    }

    private var sourceKey: String { source["key"].stringValue }

    private var cities: [JSON] {
        let all = loader.data.array
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return all }
        return all.filter { $0["name"].stringValue.lowercased().contains(q) }
    }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Городов нет", retry: { await loader.load() }) {
            List {
                if let e = loader.lastRefreshError {
                    ErrorBanner(message: e, retry: { Task { await loader.load() } })
                }
                if loader.state == .loaded && cities.isEmpty {
                    Text(query.isEmpty ? "Городов нет" : "Город не найден")
                        .foregroundColor(Brand.muted)
                }
                ForEach(cities, id: \.self) { c in
                    NavigationLink {
                        ParserOrgsView(sourceKey: sourceKey, citySlug: c["slug"].stringValue,
                                       cityName: c["name"].stringValue)
                    } label: {
                        Text(c["name"].stringValue)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await loader.load() }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Город")
        .navigationTitle(source["name"].nonEmptyString ?? "Город")
        .task { await loader.loadIfNeeded() }
    }
}

/// Организации города (превью: логотип, открыта/закрыта сейчас).
struct ParserOrgsView: View {
    let sourceKey: String
    let citySlug: String
    let cityName: String

    @StateObject private var loader: ObjectLoader
    @State private var query = ""

    init(sourceKey: String, citySlug: String, cityName: String) {
        self.sourceKey = sourceKey
        self.citySlug = citySlug
        self.cityName = cityName
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/parser/orgs",
                                                         query: ["source": sourceKey, "city": citySlug]))
    }

    private var orgs: [JSON] {
        let all = loader.data.array
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return all }
        return all.filter { $0["name"].stringValue.lowercased().contains(q) }
    }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Организаций не найдено", retry: { await loader.load() }) {
            List {
                if let e = loader.lastRefreshError {
                    ErrorBanner(message: e, retry: { Task { await loader.load() } })
                }
                if loader.state == .loaded {
                    Text(orgsCountText)
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
                ForEach(orgs, id: \.self) { o in
                    NavigationLink {
                        ParserOrgView(sourceKey: sourceKey, slug: o["slug"].stringValue,
                                      citySlug: citySlug, cityName: cityName)
                    } label: {
                        ParserOrgRow(org: o)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await loader.load() }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Название")
        .navigationTitle(cityName)
        .task { await loader.loadIfNeeded() }
    }

    private var orgsCountText: String {
        let total = loader.data.array.count
        if orgs.count == total { return Fmt.plural(total, "организация", "организации", "организаций") }
        return "Найдено " + String(orgs.count) + " из " + String(total)
    }
}

/// Строка организации источника.
struct ParserOrgRow: View {
    let org: JSON

    init(org: JSON) {
        self.org = org
    }

    var body: some View {
        HStack(spacing: 10) {
            AsyncImageView(path: org["logo"].string, size: 44, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(org["name"].stringValue)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if org["closed"].boolValue {
                    StatusBadge("закрыта сейчас", color: Brand.muted)
                } else {
                    StatusBadge("открыта", color: Brand.green)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
