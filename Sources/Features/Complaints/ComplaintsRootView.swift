import SwiftUI

/// Раздел «Жалобы»: жалобы пользователей на заказы, магазины, отзывы, ответы
/// продавцов, товары и пользователей. Модератор берёт в работу, решает или
/// отклоняет с резолюцией.
///
/// Ручки: GET /api/admin/complaints (status open|reviewing|resolved|rejected, q, page),
/// GET /api/admin/complaints/{id}, POST /api/admin/complaints/{id}/status
/// {status, resolution, expected_status}.
///
/// `openId` — id жалобы: её карточка открывается сразу.
struct ComplaintsRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/complaints", filters: ["status": "open"])
    @State private var deepLinkActive = false
    @State private var didOpen = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Жалобы", model: model, searchPrompt: "Автор, телефон, текст или номер",
                        filters: [ComplaintsFormat.statusFilter],
                        emptyText: "Жалоб нет",
                        row: { item in ComplaintsRow(complaint: item) },
                        destination: { item in ComplaintsDetailView(id: item.id ?? 0, model: model) })
            .navigationDestination(isPresented: $deepLinkActive) {
                ComplaintsDetailView(id: openId ?? 0, model: model)
            }
            .onAppear {
                guard !didOpen else { return }
                didOpen = true
                if openId != nil { deepLinkActive = true }
            }
    }
}

/// Подписи раздела «Жалобы».
enum ComplaintsFormat {
    static let statusFilter = ListFilter(key: "status", title: "Статус", options: [
        PickerOption(value: "open", label: "Открытые"),
        PickerOption(value: "reviewing", label: "В работе"),
        PickerOption(value: "resolved", label: "Решённые"),
        PickerOption(value: "rejected", label: "Отклонённые"),
    ])

    static func statusLabel(_ s: String?) -> String {
        switch s ?? "" {
        case "open": return "Открыта"
        case "reviewing": return "В работе"
        case "resolved": return "Решена"
        case "rejected": return "Отклонена"
        default: return Fmt.statusLabel(s)
        }
    }

    static func statusColor(_ s: String?) -> Color {
        switch s ?? "" {
        case "open": return Brand.amber
        case "reviewing": return Brand.blue
        case "resolved": return Brand.green
        default: return Brand.muted
        }
    }

    /// Тип объекта жалобы по-русски.
    static func targetType(_ t: String?) -> String {
        switch t ?? "" {
        case "order": return "Заказ"
        case "shop": return "Магазин"
        case "review": return "Отзыв"
        case "review_reply": return "Ответ продавца"
        case "product": return "Товар"
        case "user": return "Пользователь"
        case "": return "—"
        default: return t ?? "—"
        }
    }

    /// Строка с новым статусом.
    static func withStatus(_ row: JSON, _ status: String) -> JSON {
        var o = row.object
        o["status"] = .string(status)
        return .object(o)
    }
}

/// Строка жалобы: причина, объект, автор, дата, статус.
struct ComplaintsRow: View {
    let complaint: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(complaint["reason"].nonEmptyString ?? "Жалоба")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                StatusBadge(ComplaintsFormat.statusLabel(complaint["status"].string),
                            color: ComplaintsFormat.statusColor(complaint["status"].string))
            }
            if let t = complaint["text"].nonEmptyString {
                Text(t)
                    .font(.caption)
                    .foregroundColor(Brand.text)
                    .lineLimit(2)
            }
            Text(targetText)
                .font(.caption)
                .foregroundColor(Brand.muted)
            Text(authorText)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var targetText: String {
        let type = ComplaintsFormat.targetType(complaint["target_type"].string)
        let tid = complaint["target_id"].intValue
        let num = tid > 0 ? " #" + String(tid) : ""
        return "#" + complaint["id"].stringValue + " · " + type + num
    }

    private var authorText: String {
        let name = complaint["author"].nonEmptyString ?? "—"
        let phone = complaint["author_phone"].nonEmptyString.map { " · " + Fmt.phone($0) } ?? ""
        return Fmt.date(complaint["created_at"]) + " · " + name + phone
    }
}
