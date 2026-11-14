import SwiftUI

/// Раздел «Почта» — адреса, на которые письма не доходят (как /admin/email-health на сайте).
///
///  * GET  /api/admin/email-health?q=&page= → {summary:{suppressed, users_bad, unverified},
///    items:[{email, reason bounce|manual, detail, hits, created_at, updated_at, user_id, user_name}],
///    total, page, per_page}; страниц (`pages`) сервер не присылает — «Показать ещё» считается по total;
///  * POST /api/admin/email-health/bounces {text} — текст письма о недоставке → {added:[{email, user_id, user_name}]};
///  * POST /api/admin/email-health/suppress {email} — «Заблокировать адрес» (на него больше не пишем);
///  * POST /api/admin/email-health/unsuppress {email} — «Разблокировать» (письма снова уходят).
/// Адреса показываются так, как их хранит сервер: это служебный список, а не профиль человека.
struct EmailHealthRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/email-health")
    @State private var bounceText = ""
    @State private var oneEmail = ""
    @State private var resultNote: String?

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var summary: JSON { model.lastData["summary"] }

    var body: some View {
        content
            .navigationTitle("Почта")
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Поиск по адресу")
            .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let msg) = model.state {
            ErrorStateView(message: msg, retry: { await model.reload() })
        } else if model.lastData.isNull {
            ProgressView("Загрузка…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if let err = model.refreshError {
                Section {
                    ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                }
            }
            summarySection
            addSection
            rowsSection
            Section {
                ListFooter(model: model)
            }
        }
        .refreshable { await model.refresh() }
    }

    // MARK: - Сводка

    private var summarySection: some View {
        Section {
            KVRow("В списке «не доходят»", Fmt.number(summary["suppressed"].intValue))
            KVRow("Из них у пользователей", Fmt.number(summary["users_bad"].intValue))
            KVRow("Почта не подтверждена", Fmt.number(summary["unverified"].intValue))
        } header: {
            Text("Сводка")
        } footer: {
            Text("На адреса из списка площадка больше не пишет; в профиле человек видит «Письма на эту почту не доходят — укажите другую». Уведомления на неподтверждённую почту не уходят.")
        }
    }

    // MARK: - Добавление

    private var addSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("Текст письма «Mail Delivery System» / «Недоставленное сообщение»")
                TextEditor(text: $bounceText)
                    .frame(minHeight: 110)
            }
            ActionButton("Найти адреса и добавить", systemImage: "envelope.open", style: .bordered,
                         confirm: ConfirmAction(title: "Заблокировать найденные адреса?",
                                                message: "Адреса из письма попадут в список «не доходят», площадка перестанет на них писать.",
                                                confirmLabel: "Найти и заблокировать", destructive: true),
                         fullWidth: true) {
                try await addFromBounce()
            }
            .disabled(bounceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            TextField("или адрес вручную", text: $oneEmail)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ActionButton("Заблокировать адрес", systemImage: "envelope.badge.shield.half.filled", style: .bordered,
                         confirm: ConfirmAction(title: "Заблокировать адрес?",
                                                message: "Письма на этот адрес больше не будут уходить, а у человека в профиле появится «почта не работает».",
                                                confirmLabel: "Заблокировать", destructive: true),
                         fullWidth: true) {
                try await addOne()
            }
            .disabled(oneEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let n = resultNote {
                Text(n)
                    .font(.footnote)
            }
        } header: {
            Text("Письмо о недоставке")
        } footer: {
            Text("Скопируйте письмо о недоставке целиком — адреса найдутся сами. Можно добавить и один адрес вручную.")
        }
    }

    private func addFromBounce() async throws {
        let text = bounceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let res = try await API.shared.post("/api/admin/email-health/bounces", body: ["text": text])
        let added = res["added"].array
        let names = added.map { item -> String in
            let email = item["email"].stringValue
            guard let uid = item["user_id"].int else { return email }
            return email + " (пользователь #" + String(uid) + " " + item["user_name"].stringValue + ")"
        }
        resultNote = "Добавлено: " + names.joined(separator: ", ")
        bounceText = ""
        await model.refresh()
    }

    private func addOne() async throws {
        let email = oneEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return }
        let res = try await API.shared.post("/api/admin/email-health/suppress", body: ["email": email])
        resultNote = "Заблокирован адрес: " + (res["email"].nonEmptyString ?? email)
        oneEmail = ""
        await model.refresh()
    }

    // MARK: - Список

    private var rowsSection: some View {
        Section {
            if model.items.isEmpty {
                Text("Список пуст")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(model.items, id: \.stableID) { item in
                    EmailHealthRow(item: item) {
                        let email = item["email"].stringValue
                        try await API.shared.post("/api/admin/email-health/unsuppress", body: ["email": email])
                        resultNote = "Разблокирован: " + email + " — письма снова будут уходить"
                        await model.refresh()
                    }
                    .task { await model.loadMoreIfNeeded(current: item) }
                }
            }
        } header: {
            Text("Адреса, на которые не доходят письма")
        }
    }
}

/// Строка списка: адрес, человек, причина, число отказов, дата и «Разблокировать».
struct EmailHealthRow: View {
    let item: JSON
    let onUnblock: () async throws -> Void

    init(item: JSON, onUnblock: @escaping () async throws -> Void) {
        self.item = item
        self.onUnblock = onUnblock
    }

    private var reasonText: String {
        switch item["reason"].string ?? "" {
        case "bounce": return "отказ сервера"
        case "manual": return "вручную"
        default: return item["reason"].string ?? "—"
        }
    }

    private var userText: String? {
        guard let uid = item["user_id"].int else { return nil }
        let name = item["user_name"].stringValue
        return name.isEmpty ? "Пользователь #" + String(uid) : "Пользователь #" + String(uid) + " " + name
    }

    private var info: String {
        let hits = "отказов: " + Fmt.number(item["hits"].intValue)
        return AssistantFmt.joined([reasonText, hits, Fmt.date(item["updated_at"])])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item["email"].stringValue)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
            if let u = userText {
                Text(u)
                    .font(.footnote)
            }
            Text(info)
                .font(.caption)
                .foregroundColor(Brand.muted)
            if let d = item["detail"].nonEmptyString {
                Text(d)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            ActionButton("Разблокировать", systemImage: "envelope.badge", style: .plain,
                         confirm: ConfirmAction(title: "Разблокировать адрес?",
                                                message: item["email"].stringValue + ": письма на него снова будут уходить.",
                                                confirmLabel: "Разблокировать"),
                         action: onUnblock)
        }
        .padding(.vertical, 2)
    }
}
