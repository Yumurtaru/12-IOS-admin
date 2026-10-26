import SwiftUI

/// Раздел «Розыгрыши» (как /admin/giveaways.php сайта, волна А104, routes/admin_giveaways.php).
///
///  * «Участники» — GET /api/admin/giveaways/participants?q=&page=&city_id=&exclude_staff=1:
///    {items:[{id, name, phone, email, created_at, city}], total, page, pages} и — на первой
///    странице без поиска — cities [{id, name, cnt}], no_city, all (участников под фильтр);
///  * «Провести розыгрыш» — лист GiveawayDrawSheet (POST /api/admin/giveaways/draw);
///  * «История» — GET /api/admin/giveaways?page= → карточка GET /api/admin/giveaways/{id}.
///
/// «Скрыть номера» (включается при каждом входе в раздел, не запоминается) действует на все экраны раздела:
/// видно имя и последние 5 цифр телефона, почта и id скрыты (Fmt.maskPhone).
/// Поиск идёт на сервере — по телефону ищется и при скрытых номерах.
///
/// `openId` — id розыгрыша (его карточка открывается сразу); `subtab` "history" — вкладка «История».
struct GiveawaysRootView: View {
    let openId: Int?

    /// Новый при каждом входе в раздел — номера снова скрыты (GiveawaysPrivacy).
    @StateObject private var privacy = GiveawaysPrivacy()
    @State private var tab: GiveawaysTab
    @State private var deepLinkShown = false
    @State private var deepLinkHandled = false
    @State private var drawShown = false
    // Модели живут здесь, чтобы при переключении вкладок данные не терялись.
    // Как на сервере: по умолчанию exclude_staff=1 (сотрудники организаций не участвуют).
    @StateObject private var participants = PagedListModel(path: "/api/admin/giveaways/participants",
                                                           filters: ["exclude_staff": "1"])
    @StateObject private var history = PagedListModel(path: "/api/admin/giveaways", searchParam: nil)
    /// Сводка участников с первой страницы без поиска (при поиске сервер её не присылает).
    @State private var stats = GiveawayParticipantsStats()

    init(openId: Int? = nil, subtab: String? = nil) {
        self.openId = openId
        let t = GiveawaysTab(rawValue: subtab ?? "") ?? (openId != nil ? .history : .participants)
        _tab = State(initialValue: t)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Вкладка", selection: $tab) {
                ForEach(GiveawaysTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            GiveawaysPrivacyToggle(privacy: privacy)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            content
        }
        .background(Brand.bg)
        .navigationTitle(AdminSection.giveaways.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Провести") { drawShown = true }
                    .accessibilityLabel("Провести розыгрыш")
            }
        }
        .sheet(isPresented: $drawShown) {
            GiveawayDrawSheet(privacy: privacy, cities: stats.cities, noCity: stats.noCity,
                              cityId: participants.filter("city_id").flatMap { Int($0) },
                              excludeStaff: participants.filter("exclude_staff") != "0",
                              onDrawn: { drawn() })
        }
        .navigationDestination(isPresented: $deepLinkShown) {
            GiveawayDetailView(id: openId ?? 0, privacy: privacy, onChanged: { historyChanged() })
        }
        .onReceive(participants.$lastData) { data in
            stats.absorb(data)
        }
        .onAppear {
            if openId != nil && !deepLinkHandled {
                deepLinkHandled = true
                deepLinkShown = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .participants:
            AdminListScreen(AdminSection.giveaways.title, model: participants,
                            searchPrompt: "Поиск: имя, телефон, почта",
                            filters: participantFilters,
                            emptyText: participants.searchText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? "Участников нет — нет покупателей под условия"
                                : "Никого не нашли по запросу",
                            header: AnyView(participantsHeader)) { row in
                GiveawayParticipantRow(person: row, hidden: privacy.hidePhones)
            }
        case .history:
            AdminListScreen(AdminSection.giveaways.title, model: history, searchPrompt: nil,
                            emptyText: "Розыгрышей ещё не было") { row in
                GiveawayHistoryRow(item: row, hidden: privacy.hidePhones)
            } destination: { row in
                GiveawayDetailView(id: row.id ?? 0, privacy: privacy, onChanged: { historyChanged() })
            }
        }
    }

    // MARK: - Участники

    private var participantFilters: [ListFilter] {
        [
            ListFilter(key: "city_id", title: "Город", options: cityOptions, allLabel: "Все города"),
            ListFilter(key: "exclude_staff", title: "Сотрудники", options: [
                PickerOption(value: "1", label: "Без сотрудников"),
                PickerOption(value: "0", label: "Вместе с сотрудниками"),
            ], allLabel: nil),
        ]
    }

    /// Города с числом участников; выбранный город, которого нет в списке, — тоже в списке.
    private var cityOptions: [PickerOption] {
        var out = stats.cities.map { c in
            PickerOption(value: String(c.id), label: c.name + " — " + Fmt.number(c.count))
        }
        if let sel = participants.filter("city_id"), !out.contains(where: { $0.value == sel }) {
            let name = stats.cityNames[Int(sel) ?? 0] ?? ("Город #" + sel)
            out.append(PickerOption(value: sel, label: name))
        }
        return out
    }

    private var participantsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let all = stats.all {
                    Text("Участников: ").foregroundColor(Brand.muted)
                        + Text(GiveawaysFormat.people(all)).fontWeight(.semibold)
                } else {
                    Text("Участников: …").foregroundColor(Brand.muted)
                }
                Spacer()
            }
            .font(.subheadline)
            if participants.filter("city_id") != nil && stats.noCity > 0 {
                Text("У " + Fmt.plural(stats.noCity, "покупателя", "покупателей", "покупателей")
                     + " город не указан — в розыгрыш по городу они не попадут.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text("Участвуют зарегистрированные покупатели. Владельцы организаций, заявки на проверке и администраторы не участвуют.")
                .font(.caption)
                .foregroundColor(Brand.muted)
            Button {
                drawShown = true
            } label: {
                Label("Провести розыгрыш", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    // MARK: - Обновления

    /// Розыгрыш проведён (или мог пройти) — история устарела.
    private func drawn() {
        Task { await history.refresh() }
    }

    /// В карточке отметили «Вручено» / уведомили — строка истории устарела.
    private func historyChanged() {
        Task { if history.state != .idle { await history.refresh() } }
    }
}

/// Сводка участников: города с числом участников, «без города», всего под фильтр.
/// Сервер присылает её только на первой странице без поиска — здесь она запоминается.
struct GiveawayParticipantsStats {
    struct City: Hashable {
        let id: Int
        let name: String
        let count: Int
    }

    private(set) var cities: [City] = []
    private(set) var cityNames: [Int: String] = [:]
    private(set) var noCity = 0
    private(set) var all: Int?

    init() {}

    /// Взять из data ответа участников то, что есть (нет полей — прежние значения).
    mutating func absorb(_ data: JSON) {
        guard data.isObject else { return }
        if data["cities"].isArray {
            cities = data["cities"].array.compactMap { c in
                guard let id = c["id"].int, id > 0 else { return nil }
                return City(id: id, name: c["name"].nonEmptyString ?? ("Город #" + String(id)), count: c["cnt"].intValue)
            }
            for c in cities { cityNames[c.id] = c.name }
        }
        if let n = data["no_city"].int { noCity = n }
        if let a = data["all"].int { all = a }
    }
}

/// Строка участника.
struct GiveawayParticipantRow: View {
    let person: JSON
    let hidden: Bool

    init(person: JSON, hidden: Bool) {
        self.person = person
        self.hidden = hidden
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            GiveawayPersonText(person: person, idKey: "id", hidden: hidden)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let c = person["city"].nonEmptyString {
                    Text(c).font(.caption).foregroundColor(Brand.text).lineLimit(1)
                }
                if person["created_at"].nonEmptyString != nil {
                    Text("с " + Fmt.day(person["created_at"].string))
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Строка истории: приз, дата, участники, город, «вручено X из Y» и победители.
struct GiveawayHistoryRow: View {
    let item: JSON
    let hidden: Bool

    init(item: JSON, hidden: Bool) {
        self.item = item
        self.hidden = hidden
    }

    private static let previewLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item["prize"].nonEmptyString ?? "Приз")
                .font(.body.weight(.semibold))
                .foregroundColor(Brand.text)
            if let t = item["title"].nonEmptyString {
                Text(t).font(.subheadline).foregroundColor(Brand.text)
            }
            Text(metaText)
                .font(.caption)
                .foregroundColor(Brand.muted)
            winnersPreview
        }
        .padding(.vertical, 4)
    }

    private var metaText: String {
        var parts = [Fmt.date(item["created_at"].string),
                     "участников " + Fmt.number(item["participants"].intValue)]
        if let c = item["city"].nonEmptyString { parts.append(c) }
        parts.append("вручено " + String(item["given"].intValue) + " из " + String(item["winners_count"].intValue))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var winnersPreview: some View {
        let ws = item["winners"].array
        if !ws.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(ws.prefix(GiveawayHistoryRow.previewLimit).enumerated()), id: \.offset) { pair in
                    winnerLine(pair.element)
                }
                if ws.count > GiveawayHistoryRow.previewLimit {
                    Text("и ещё " + Fmt.plural(ws.count - GiveawayHistoryRow.previewLimit, "победитель", "победителя", "победителей"))
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
        }
    }

    private func winnerLine(_ w: JSON) -> some View {
        let given = w["given_at"].nonEmptyString != nil
        var text = String(w["place"].intValue) + ". " + Fmt.personName(w["name"].string, hidden: hidden)
        if let p = Fmt.contactPhone(w["phone"].string, hidden: hidden) { text += " · " + p }
        if !hidden, let e = w["email"].nonEmptyString { text += " · " + e }
        return HStack(spacing: 6) {
            Image(systemName: given ? "checkmark.circle.fill" : "circle")
                .foregroundColor(given ? Brand.green : Brand.muted)
                .font(.caption)
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(Brand.text)
                .lineLimit(1)
        }
    }
}
