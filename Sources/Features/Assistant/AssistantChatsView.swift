import SwiftUI

/// Переписки с помощником: GET /api/admin/assistant/chats?filter=&q=&page= →
/// {items, total, page, pages}. Фильтры сайта: bad (не помогло), handed (переданы человеку),
/// offtopic (вне темы), client / seller / guest. Поиск — по тексту сообщений.
struct AssistantChatsView: View {
    @StateObject private var model = PagedListModel(path: "/api/admin/assistant/chats")

    private let filters: [ListFilter] = [
        ListFilter(key: "filter", title: "Фильтр", options: [
            PickerOption(value: "bad", label: "Не помогло"),
            PickerOption(value: "handed", label: "Переданы человеку"),
            PickerOption(value: "offtopic", label: "Вне темы"),
            PickerOption(value: "client", label: "Покупатели"),
            PickerOption(value: "seller", label: "Организации"),
            PickerOption(value: "guest", label: "Гости"),
        ]),
    ]

    var body: some View {
        AdminListScreen("Переписки с помощником", model: model,
                        searchPrompt: "Поиск по тексту переписки",
                        filters: filters,
                        emptyText: "Переписок пока нет. Когда покупатели и организации начнут спрашивать помощника, разговоры появятся здесь.",
                        row: { AssistantChatRow(chat: $0) },
                        destination: { AssistantChatView(id: $0.id ?? 0) })
    }
}

/// Строка списка переписок.
struct AssistantChatRow: View {
    let chat: JSON

    init(chat: JSON) {
        self.chat = chat
    }

    private var who: String {
        let name = chat["shop_name"].nonEmptyString ?? chat["user_name"].nonEmptyString
        return AssistantFmt.joined([AssistantFmt.audience(chat["audience"].string), name ?? ""])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(who)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(Fmt.date(chat["updated_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(chat["title"].stringValue)
                .font(.subheadline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(Fmt.plural(chat["msg_count"].intValue, "сообщение", "сообщения", "сообщений"))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if chat["likes"].intValue > 0 {
                    Label(String(chat["likes"].intValue), systemImage: "hand.thumbsup")
                        .font(.caption)
                        .foregroundColor(Brand.green)
                }
                if chat["dislikes"].intValue > 0 {
                    Label(String(chat["dislikes"].intValue), systemImage: "hand.thumbsdown")
                        .font(.caption)
                        .foregroundColor(Brand.red)
                }
                Spacer()
                if chat["status"].string == "handed" {
                    StatusBadge("Передан человеку", color: Brand.blue)
                } else {
                    StatusBadge("Ответил помощник", color: Brand.muted)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Одна переписка целиком: GET /api/admin/assistant/chats/{id} → поля чата и messages[].
struct AssistantChatView: View {
    let id: Int
    @StateObject private var loader: ObjectLoader

    init(id: Int) {
        self.id = id
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/assistant/chats/" + String(id)))
    }

    private var c: JSON { loader.data }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            List {
                if let e = loader.lastRefreshError {
                    Section {
                        ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    }
                }
                headerSection
                Section("Сообщения") {
                    ForEach(c["messages"].array, id: \.stableID) { m in
                        AssistantMessageRow(message: m)
                    }
                }
            }
            .refreshable { await loader.load() }
        }
        .navigationTitle("Переписка #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadIfNeeded() }
    }

    private var headerSection: some View {
        let tokens = Fmt.number(c["tokens_in"].intValue) + " / " + Fmt.number(c["tokens_out"].intValue)
        return Section {
            KVRow("Кто", AssistantFmt.audience(c["audience"].string))
            KVRow("Организация", c["shop_name"].string)
            KVRow("Пользователь", c["user_name"].string)
            KVRow("Начата", Fmt.date(c["created_at"]))
            KVRow("Токены: вход / ответ", tokens)
            KVRow("Статус", c["status"].string == "handed" ? "Передан человеку" : "Ответил помощник")
            if c["status"].string == "handed" {
                KVRow("Передано", handoffText)
            }
        }
    }

    private var handoffText: String {
        if c["handoff_kind"].string == "shop_support" { return "в «Сообщения продавцам»" }
        if let ref = c["handoff_ref"].nonEmptyString { return "обращение #" + ref }
        return "человеку"
    }
}

/// Одно сообщение переписки: вопрос или ответ помощника, оценка, статьи-источники.
struct AssistantMessageRow: View {
    let message: JSON

    init(message: JSON) {
        self.message = message
    }

    private var isUser: Bool { message["role"].string == "user" }

    private var meta: String {
        var parts: [String] = []
        if isUser {
            parts.append("Вопрос")
        } else {
            parts.append("Помощник")
            if let m = message["model"].nonEmptyString { parts.append(m) }
            if let ms = message["ms"].double, ms > 0 { parts.append(AssistantFmt.seconds(ms)) }
        }
        parts.append(Fmt.time(message["created_at"].string))
        let rating = message["rating"].int ?? 0
        if rating == 1 { parts.append("помогло") }
        if rating == -1 { parts.append("не помогло") }
        if message["off_topic"].boolValue { parts.append("вне темы") }
        return AssistantFmt.joined(parts)
    }

    private var sources: String {
        let titles = message["sources"].array.compactMap { $0["title"].nonEmptyString }
        return titles.isEmpty ? "" : "Статьи: " + titles.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message["body"].stringValue)
                .font(.subheadline)
                .textSelection(.enabled)
            Text(meta)
                .font(.caption)
                .foregroundColor(Brand.muted)
            if !sources.isEmpty {
                Text(sources)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(isUser ? Brand.accent.opacity(0.08) : nil)
    }
}
