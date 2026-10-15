import SwiftUI

/// Вкладки раздела «Заявки магазинов».
enum RegistrationsTab: String, CaseIterable, Identifiable, Hashable {
    /// Заявки на регистрацию организаций (auth_seller.php).
    case registrations
    /// Организации, ждущие публикации (второй шаг одобрения).
    case publish
    /// Лицензионные документы организаций на проверке.
    case documents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .registrations: return "Заявки"
        case .publish: return "Публикация"
        case .documents: return "Лицензии"
        }
    }

    /// Счётчик «ждут» из Notifier для подписи сегмента.
    var category: NotifyCategory {
        switch self {
        case .registrations: return .registrations
        case .publish: return .publish
        case .documents: return .documents
        }
    }
}

/// Раздел «Заявки магазинов»: три сегмента — заявки на регистрацию
/// (GET /api/admin/registrations: одобрить / запросить данные / отклонить),
/// публикация организаций (GET /api/admin/publish-requests: опубликовать /
/// на доработку) и лицензии (GET/PUT /api/admin/documents).
///
/// `openId` — id заявки на регистрацию: её карточка открывается сразу.
struct RegistrationsRootView: View {
    let openId: Int?

    @State private var tab: RegistrationsTab
    @StateObject private var regModel = PagedListModel(path: "/api/admin/registrations", searchParam: nil,
                                                        filters: ["status": "pending"], perPage: ("per", 50))
    @StateObject private var publishModel = PagedListModel(path: "/api/admin/publish-requests", searchParam: nil)
    @StateObject private var docsModel = PagedListModel(path: "/api/admin/documents", searchParam: nil,
                                                         filters: ["status": "pending"])
    @ObservedObject private var notifier = Notifier.shared
    @State private var openDeepLink = false
    @State private var deepLinkHandled = false

    /// - Parameters:
    ///   - openId: id заявки на регистрацию (deep link);
    ///   - initialTab: какой сегмент открыть.
    init(openId: Int? = nil, initialTab: RegistrationsTab = .registrations) {
        self.openId = openId
        _tab = State(initialValue: openId != nil ? .registrations : initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $tab) {
                ForEach(RegistrationsTab.allCases) { t in
                    Text(segmentTitle(t)).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            content
        }
        .navigationTitle(AdminSection.registrations.title)
        .navigationDestination(isPresented: $openDeepLink) {
            RegistrationDetailView(id: openId ?? 0, initial: nil, model: regModel)
        }
        .onAppear {
            if openId != nil && !deepLinkHandled {
                deepLinkHandled = true
                openDeepLink = true
            }
        }
    }

    private func segmentTitle(_ t: RegistrationsTab) -> String {
        let n = notifier.count(t.category)
        return n > 0 ? t.title + " · " + String(n) : t.title
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .registrations:
            RegistrationsListView(model: regModel)
        case .publish:
            PublishRequestsView(model: publishModel)
        case .documents:
            DocumentsModerationView(model: docsModel)
        }
    }
}

/// Список заявок на регистрацию с фильтром статуса (счётчики — из ответа counts).
struct RegistrationsListView: View {
    @ObservedObject var model: PagedListModel

    init(model: PagedListModel) {
        self.model = model
    }

    /// Сколько заявок в статусе (data.counts = [{status, n}]).
    private func count(_ status: String) -> Int? {
        for c in model.lastData["counts"].array where c["status"].string == status {
            return c["n"].int
        }
        return nil
    }

    private func option(_ status: String) -> PickerOption {
        let base = ShopsLabels.registrationStatus(status)
        guard let n = count(status) else { return PickerOption(value: status, label: base) }
        return PickerOption(value: status, label: base + " (" + String(n) + ")")
    }

    private var filters: [ListFilter] {
        let opts = ["pending", "more_info_needed", "approved", "rejected"].map { option($0) }
        return [ListFilter(key: "status", title: "Статус", options: opts, allLabel: "Все")]
    }

    private var emptyText: String {
        if model.filter("status") == "pending" { return "Новых заявок нет. Остальные — в фильтре «Статус»." }
        return "Заявок нет"
    }

    var body: some View {
        AdminListScreen(AdminSection.registrations.title, model: model, searchPrompt: nil, filters: filters,
                        emptyText: emptyText,
                        row: { RegistrationRow(reg: $0) },
                        destination: { reg in RegistrationDetailView(id: reg.id ?? 0, initial: reg, model: model) })
    }
}

/// Строка заявки: название, тип, заявитель, город, дата, статус.
struct RegistrationRow: View {
    let reg: JSON

    init(reg: JSON) {
        self.reg = reg
    }

    private var meta: String {
        var parts: [String] = [ShopsLabels.registrationType(reg["shop_type"].string)]
        if let c = reg["city_name"].nonEmptyString { parts.append(c) }
        if let inn = reg["inn"].nonEmptyString { parts.append("ИНН " + inn) }
        return parts.joined(separator: " · ")
    }

    private var owner: String {
        var parts: [String] = []
        if let n = reg["owner_name"].nonEmptyString { parts.append(n) }
        if let p = reg["owner_phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(reg["shop_name"].nonEmptyString ?? "Без названия")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                StatusBadge(status: reg["status"].string, label: ShopsLabels.registrationStatus(reg["status"].string))
            }
            Text(meta)
                .font(.caption)
                .foregroundColor(Brand.muted)
            if !owner.isEmpty {
                Text(owner)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(Fmt.date(reg["created_at"].string))
                .font(.caption2)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 3)
    }
}
