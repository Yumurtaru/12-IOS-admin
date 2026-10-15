import SwiftUI

/// Раздел «Пользователи»: поиск по имени/телефону/почте, фильтр по типу
/// аккаунта (как на сайте), переход в карточку.
///
/// GET /api/admin/users?q=&type=&page= → {items, total, page, pages}, по 50 строк.
/// `openId` — сразу открыть карточку пользователя (уведомление/ссылка).
struct UsersRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/users")
    @State private var deepLinkShown = false
    @State private var deepLinkHandled = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Пользователи", model: model, searchPrompt: "Имя, телефон, email",
                        filters: UsersRootView.filters, emptyText: "Пользователей нет",
                        row: { UsersRow(user: $0) },
                        destination: { item in usersDetail(item) })
            .navigationDestination(isPresented: $deepLinkShown) {
                UserDetailView(id: openId ?? 0, onChanged: { reloadList() })
            }
            .onAppear { openDeepLinkOnce() }
    }

    // Замыкания, а не ссылки на методы: метод View изолирован на MainActor,
    // и его передача как `() -> Void` даёт предупреждение/ошибку изоляции в новом Xcode.
    private func usersDetail(_ item: JSON) -> UserDetailView {
        UserDetailView(id: item.id ?? 0, onChanged: { reloadList() })
    }

    private func reloadList() {
        let m = model
        Task { await m.refresh() }
    }

    private func openDeepLinkOnce() {
        guard !deepLinkHandled, openId != nil else { return }
        deepLinkHandled = true
        deepLinkShown = true
    }

    /// Типы аккаунта — как в выпадающем списке сайта (users.php).
    static let filters: [ListFilter] = [
        ListFilter(key: "type", title: "Тип", options: [
            PickerOption(value: "client", label: "Клиенты"),
            PickerOption(value: "seller", label: "Продавцы"),
            PickerOption(value: "kafe", label: "Кафе"),
            PickerOption(value: "service", label: "Услуги"),
        ], allLabel: "Все типы"),
    ]
}

/// Подписи типов аккаунта (как ATYPE в admin.js).
enum UsersLabels {
    static func accountType(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "client": return "Клиент"
        case "seller": return "Продавец"
        case "kafe": return "Кафе"
        case "service": return "Услуги"
        case "admin": return "Админ"
        case "": return "—"
        default: return c
        }
    }

    /// Подписи ролей (ROLE_LBL в admin.js).
    static func role(_ slug: String?, name: String?) -> String {
        switch slug ?? "" {
        case "admin": return "Админ"
        case "seller": return "Продавец"
        case "courier": return "Курьер"
        case "manager": return "Менеджер"
        default:
            if let n = name, !n.isEmpty { return n }
            return slug ?? "—"
        }
    }

    /// Статус пользователя по-русски.
    static func status(_ code: String?) -> String {
        switch code ?? "" {
        case "active": return "Активен"
        case "blocked": return "Заблокирован"
        default: return Fmt.statusLabel(code)
        }
    }
}

/// Строка списка пользователей: имя, контакты, тип, бонусы, статус.
struct UsersRow: View {
    let user: JSON

    init(user: JSON) {
        self.user = user
    }

    private var title: String {
        user["name"].nonEmptyString ?? ("Пользователь #" + user["id"].stringValue)
    }

    private var contacts: String {
        var parts: [String] = []
        if let p = user["phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        if let e = user["email"].nonEmptyString { parts.append(e) }
        return parts.joined(separator: " · ")
    }

    private var meta: String {
        let type = UsersLabels.accountType(user["account_type"].string)
        let bonus = "бонусы " + Fmt.money(user["bonus_balance"])
        return type + " · " + bonus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                StatusBadge(status: user["status"].string, label: UsersLabels.status(user["status"].string))
            }
            if !contacts.isEmpty {
                Text(contacts)
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
            }
            HStack {
                Text(meta)
                Spacer()
                Text(Fmt.day(user["created_at"].string))
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 4)
    }
}
