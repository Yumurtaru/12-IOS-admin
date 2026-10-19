import SwiftUI

/// Раздел «Поддержка»: обращения пользователей (тикеты) — переписка, ответ,
/// закрытие.
///
/// Ручки: GET /api/admin/support/tickets (status open|answered|closed, q, page; q — номер,
/// тема, имя и телефон автора, текст переписки, П-29.5), GET /api/admin/support/tickets/{id}, POST …/{id}/reply {message},
/// POST …/{id}/close.
///
/// `openId` — id обращения: переписка открывается сразу.
struct SupportRootView: View {
    let openId: Int?

    // Поиск q (П-29.5): сервер ищет по номеру, теме, автору, телефону и тексту переписки.
    @StateObject private var model = PagedListModel(path: "/api/admin/support/tickets", searchParam: "q",
                                                    filters: ["status": "open"])
    @State private var deepLinkActive = false
    @State private var didOpen = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Поддержка", model: model, searchPrompt: "Номер, тема, автор, телефон, текст",
                        filters: [SupportFormat.statusFilter],
                        emptyText: "Обращений нет",
                        row: { item in SupportRow(ticket: item) },
                        destination: { item in SupportTicketView(id: item.id ?? 0, model: model) })
            .navigationDestination(isPresented: $deepLinkActive) {
                SupportTicketView(id: openId ?? 0, model: model)
            }
            .onAppear {
                guard !didOpen else { return }
                didOpen = true
                if openId != nil { deepLinkActive = true }
            }
    }
}

/// Подписи раздела «Поддержка».
enum SupportFormat {
    static let statusFilter = ListFilter(key: "status", title: "Статус", options: [
        PickerOption(value: "open", label: "Открытые"),
        PickerOption(value: "answered", label: "Отвечено"),
        PickerOption(value: "closed", label: "Закрытые"),
    ])

    static func statusLabel(_ s: String?) -> String {
        switch s ?? "" {
        case "open": return "Открыт"
        case "answered": return "Отвечено"
        case "closed": return "Закрыт"
        default: return Fmt.statusLabel(s)
        }
    }

    static func statusColor(_ s: String?) -> Color {
        switch s ?? "" {
        case "open": return Brand.amber
        case "answered": return Brand.blue
        default: return Brand.muted
        }
    }

    /// Строка с новым статусом.
    static func withStatus(_ row: JSON, _ status: String) -> JSON {
        var o = row.object
        o["status"] = .string(status)
        return .object(o)
    }
}

/// Строка обращения: тема, пользователь, последнее сообщение, статус.
struct SupportRow: View {
    let ticket: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(ticket["subject"].nonEmptyString ?? "Без темы")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                StatusBadge(SupportFormat.statusLabel(ticket["status"].string),
                            color: SupportFormat.statusColor(ticket["status"].string))
            }
            if let last = ticket["last_msg"].nonEmptyString {
                Text(last)
                    .font(.caption)
                    .foregroundColor(Brand.text)
                    .lineLimit(2)
            }
            Text(metaLine)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var metaLine: String {
        let name = ticket["user_name"].nonEmptyString ?? "—"
        let phone = ticket["phone"].nonEmptyString.map { " · " + Fmt.phone($0) } ?? ""
        let num: String = "#" + ticket["id"].stringValue
        let when: String = Fmt.date(ticket["created_at"])
        return num + " · " + when + " · " + name + phone
    }
}
