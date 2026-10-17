import SwiftUI

/// Раздел «Сообщения продавцам» — переписки организаций с поддержкой площадки
/// (как /admin/shop-support.php на сайте, волна А66).
///
/// Ручки: GET /api/admin/shop-support/threads?filter=unread|open|closed&q=&page= →
/// {items:[{shop_id, shop_name, shop_status, city, phone, status, last_message_at,
/// last_side, last_preview, unread, seller_read}], total, page, pages, unread_threads}.
/// «+» — новое сообщение любой организации (поиск /shops), мегафон — рассылка.
///
/// `openId` — id организации: её чат открывается сразу (push `shop_support`,
/// уведомление о единственной непрочитанной переписке). `subtab == "unread"` —
/// список сразу с фильтром «Непрочитанные».
struct ShopSupportRootView: View {
    let openId: Int?

    @StateObject private var model: PagedListModel
    @State private var chatShopId: Int?
    @State private var chatActive = false
    @State private var didOpen = false
    @State private var showPicker = false
    @State private var pickedId: Int?
    @State private var showBroadcast = false

    init(openId: Int? = nil, subtab: String? = nil) {
        self.openId = openId
        let filters: [String: String] = subtab == "unread" ? ["filter": "unread"] : [:]
        _model = StateObject(wrappedValue: PagedListModel(path: "/api/admin/shop-support/threads",
                                                          itemsKey: "items", filters: filters))
    }

    var body: some View {
        list
            .navigationTitle("Сообщения продавцам")
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Название, #номер или телефон")
            .toolbar { toolbarContent }
            .task { await model.loadIfNeeded() }
            .onAppear(perform: appeared)
            .navigationDestination(isPresented: $chatActive) { chatDestination }
            .sheet(isPresented: $showPicker, onDismiss: openPicked) {
                ShopSupportShopPicker { id in pickedId = id }
            }
            // После рассылки у адресатов появились переписки — обновляем список.
            .sheet(isPresented: $showBroadcast, onDismiss: { Task { await model.refresh() } }) {
                ShopSupportBroadcastView()
            }
    }

    @ViewBuilder
    private var chatDestination: some View {
        if let sid = chatShopId {
            ShopSupportChatView(shopId: sid).id(sid)
        } else {
            EmptyView()
        }
    }

    /// Первое появление — переход по ссылке; возврат из чата — тихо обновить список
    /// (непрочитанное и последняя реплика поменялись).
    private func appeared() {
        if !didOpen {
            didOpen = true
            if let id = openId, id > 0 {
                chatShopId = id
                chatActive = true
            }
            return
        }
        if model.state != .idle && model.state != .loading {
            Task { await model.refresh() }
        }
    }

    /// Организацию выбрали в «Новом сообщении» — открываем её чат после закрытия листа.
    private func openPicked() {
        guard let id = pickedId else { return }
        pickedId = nil
        chatShopId = id
        chatActive = true
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showBroadcast = true
            } label: { Image(systemName: "megaphone") }
            .accessibilityLabel("Рассылка организациям")
            Button {
                showPicker = true
            } label: { Image(systemName: "square.and.pencil") }
            .accessibilityLabel("Новое сообщение")
        }
    }

    // MARK: - Список

    private var list: some View {
        List {
            ShopSupportFilterChips(model: model)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
            unreadHeader
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
    private var unreadHeader: some View {
        let n = model.lastData["unread_threads"].intValue
        if n > 0 {
            Text("С непрочитанным: " + Fmt.plural(n, "переписка", "переписки", "переписок"))
                .font(.footnote.weight(.semibold))
                .foregroundColor(Brand.accent)
                .listRowSeparator(.hidden)
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
        case .empty:
            EmptyStateView(title: emptyTitle, systemImage: "bubble.left.and.bubble.right",
                           message: "Чтобы написать организации, нажмите «Новое сообщение» вверху.")
                .frame(minHeight: 260)
                .listRowSeparator(.hidden)
        case .loaded:
            rows
            ListFooter(model: model)
        }
    }

    private var emptyTitle: String {
        switch model.filter("filter") ?? "" {
        case "unread": return "Непрочитанных нет"
        case "open": return "Открытых переписок нет"
        case "closed": return "Решённых переписок нет"
        default: return "Переписок пока нет"
        }
    }

    // id строки — shop_id (одна переписка на организацию): строка не теряет
    // NavigationLink при обновлении списка, открытый чат не закрывается.
    private var threadItems: [ShopSupportThreadItem] {
        var seen = Set<Int>()
        var out: [ShopSupportThreadItem] = []
        for j in model.items {
            guard let sid = j["shop_id"].int, !seen.contains(sid) else { continue }
            seen.insert(sid)
            out.append(ShopSupportThreadItem(id: sid, json: j))
        }
        return out
    }

    private var rows: some View {
        ForEach(threadItems) { t in
            NavigationLink(destination: ShopSupportChatView(shopId: t.id)) {
                ShopSupportThreadRow(thread: t.json)
            }
            .task { await model.loadMoreIfNeeded(current: t.json) }
        }
    }
}

/// Строка списка с устойчивым id (shop_id).
struct ShopSupportThreadItem: Identifiable {
    let id: Int
    let json: JSON
}

/// Чипы фильтра: Все / Непрочитанные / Открытые / Закрытые (параметр filter).
struct ShopSupportFilterChips: View {
    @ObservedObject var model: PagedListModel

    private static let options: [PickerOption] = [
        PickerOption(value: "", label: "Все"),
        PickerOption(value: "unread", label: "Непрочитанные"),
        PickerOption(value: "open", label: "Открытые"),
        PickerOption(value: "closed", label: "Решённые"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ShopSupportFilterChips.options) { o in
                    chip(o)
                }
            }
        }
    }

    private func chip(_ o: PickerOption) -> some View {
        let active = (model.filter("filter") ?? "") == o.value
        return Button {
            guard !active else { return }
            Haptics.tap()
            model.setFilter("filter", o.value)
        } label: {
            Text(o.label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? Brand.accent.opacity(0.15) : Brand.chip)
                .foregroundColor(active ? Brand.accent : Brand.text)
                .clipShape(Capsule())
        }
        .buttonStyle(.borderless)
    }
}

/// Строка переписки: организация, время, последняя реплика, город, непрочитанное.
struct ShopSupportThreadRow: View {
    let thread: JSON

    private var unread: Int { thread["unread"].intValue }
    private var lastIsOurs: Bool { thread["last_side"].string == "admin" }
    private var titleFont: Font { unread > 0 ? Font.subheadline.weight(.bold) : Font.subheadline.weight(.semibold) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                previewLine
                metaLine
            }
            if unread > 0 {
                Text(String(unread))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundColor(.white)
                    .background(Brand.accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 3)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(thread["shop_name"].nonEmptyString ?? ("Организация #" + thread["shop_id"].stringValue))
                .font(titleFont)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(ShopSupportFmt.time(thread["last_message_at"].string))
                .font(.caption)
                .foregroundColor(unread > 0 ? Brand.accent : Brand.muted)
        }
    }

    private var previewLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if lastIsOurs {
                // Галочка: прочитала ли организация наше последнее сообщение.
                Image(systemName: thread["seller_read"].boolValue ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundColor(Brand.muted)
                Text("Вы:").foregroundColor(Brand.muted)
            }
            Text(thread["last_preview"].nonEmptyString ?? "—")
                .foregroundColor(Brand.text)
                .lineLimit(2)
        }
        .font(.caption)
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(meta)
                .font(.caption2)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
            if thread["status"].string == "closed" {
                StatusBadge("Решён", color: Brand.green)
            }
            if let st = thread["shop_status"].nonEmptyString, st != "active" {
                StatusBadge(ShopsLabels.status(st), color: ShopsLabels.statusColor(st))
            }
        }
    }

    private var meta: String {
        var parts: [String] = ["#" + thread["shop_id"].stringValue]
        if let c = thread["city"].nonEmptyString { parts.append(c) }
        if let p = thread["phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        return parts.joined(separator: " · ")
    }
}
