import SwiftUI

/// Раздел «Администраторы» (staff в admin.js): список администраторов площадки,
/// назначение нового (поиск пользователя) и снятие роли.
///
/// GET    /api/admin/staff          → {items:[{id,name,phone,email,status,created_at,last_action,actions}], me, bootstrap_email}
/// GET    /api/admin/staff/search?q (от 2 знаков) → [{id,name,phone,email,account_type,is_admin}] (до 10)
/// POST   /api/admin/staff          {user_id}
/// DELETE /api/admin/staff/{id}     — сервер не даёт снять роль с себя и последнего админа (409, текст покажем).
/// `openId` — открыть карточку пользователя с этим id.
struct StaffRootView: View {
    let openId: Int?

    @StateObject private var loader = ObjectLoader(path: "/api/admin/staff")
    @State private var showAdd = false
    @State private var pending: ConfirmAction?
    @State private var pendingRevokeId: Int?
    @State private var deepLinkShown = false
    @State private var deepLinkHandled = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var items: [JSON] { loader.data["items"].array }
    private var me: Int { loader.data["me"].intValue }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            list
        }
        .navigationTitle("Администраторы")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("Назначить", systemImage: "person.badge.plus")
                }
            }
        }
        .task { await loader.loadIfNeeded() }
        .sheet(isPresented: $showAdd) {
            StaffAddSheet(onGranted: { reload() })
        }
        .confirmAction($pending) {
            try await revokePending()
        }
        .navigationDestination(isPresented: $deepLinkShown) {
            UserDetailView(id: openId ?? 0)
        }
        .onAppear { openDeepLinkOnce() }
    }

    private var list: some View {
        List {
            if let err = loader.lastRefreshError {
                ErrorBanner(message: err, retry: { reload() })
                    .listRowSeparator(.hidden)
            }
            if let email = loader.data["bootstrap_email"].nonEmptyString {
                Section {
                    InfoBanner("Аварийный вход настроен на почту " + email
                               + " — этот человек входит в панель, даже если его нет в списке.")
                }
            }
            Section {
                if items.isEmpty {
                    Text("Администраторов нет")
                        .foregroundColor(Brand.muted)
                } else {
                    ForEach(items, id: \.stableID) { u in
                        staffRow(u)
                    }
                }
            } header: {
                Text(Fmt.plural(items.count, "администратор", "администратора", "администраторов"))
            } footer: {
                Text("Свайп влево по строке — снять роль. Снять роль с себя и с последнего администратора нельзя.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    @ViewBuilder
    private func staffRow(_ u: JSON) -> some View {
        let isMe = (u.id ?? -1) == me
        NavigationLink(destination: UserDetailView(id: u.id ?? 0)) {
            StaffRow(user: u, isMe: isMe)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isMe {
                Button(role: .destructive) {
                    askRevoke(u)
                } label: {
                    Label("Снять роль", systemImage: "person.badge.minus")
                }
            }
        }
        .contextMenu {
            if !isMe {
                Button(role: .destructive) {
                    askRevoke(u)
                } label: {
                    Label("Снять роль администратора", systemImage: "person.badge.minus")
                }
            }
        }
    }

    private func askRevoke(_ u: JSON) {
        let fallback = "#" + u["id"].stringValue
        let name = u["name"].nonEmptyString ?? u["email"].nonEmptyString ?? fallback
        pendingRevokeId = u.id
        pending = ConfirmAction(title: "Снять роль администратора?",
                                message: "Пользователь «" + name + "» потеряет доступ к панели.",
                                confirmLabel: "Снять роль", destructive: true)
    }

    private func revokePending() async throws {
        guard let uid = pendingRevokeId else { return }
        try await API.shared.delete("/api/admin/staff/" + String(uid), body: [:])
        pendingRevokeId = nil
        await loader.load()
    }

    private func reload() {
        let l = loader
        Task { await l.load() }
    }

    private func openDeepLinkOnce() {
        guard !deepLinkHandled, openId != nil else { return }
        deepLinkHandled = true
        deepLinkShown = true
    }
}

/// Строка администратора: имя, «это вы», контакты, число действий, последнее действие.
struct StaffRow: View {
    let user: JSON
    let isMe: Bool

    init(user: JSON, isMe: Bool) {
        self.user = user
        self.isMe = isMe
    }

    private var contacts: String {
        var parts: [String] = []
        if let e = user["email"].nonEmptyString { parts.append(e) }
        if let p = user["phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        return parts.joined(separator: " · ")
    }

    private var activity: String {
        let n = user["actions"].intValue
        let count = Fmt.plural(n, "действие", "действия", "действий")
        guard let last = user["last_action"].nonEmptyString else { return count }
        return count + " · последнее " + Fmt.date(last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(user["name"].nonEmptyString ?? "—")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if isMe {
                    StatusBadge("это вы", color: Brand.blue)
                }
                Spacer(minLength: 4)
                if user["status"].string == "blocked" {
                    StatusBadge(status: "blocked")
                }
            }
            if !contacts.isEmpty {
                Text(contacts)
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
            }
            Text(activity)
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }
}

/// Лист «Назначить администратора»: поиск пользователя (от 2 знаков) и назначение.
struct StaffAddSheet: View {
    let onGranted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [JSON] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var searched = false
    @State private var generation = 0
    @State private var searchTask: Task<Void, Never>?

    init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Имя, телефон или почта", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { scheduleSearch(delay: 0) }
                } footer: {
                    Text("Назначенный получит полный доступ к панели площадки.")
                }
                resultsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Назначить администратора")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onChange(of: query) { _ in
                scheduleSearch(delay: 400_000_000)
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if trimmed.count < 2 {
                Text("Введите хотя бы два знака")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else if searching {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let err = searchError {
                ErrorBanner(message: err, retry: { scheduleSearch(delay: 0) })
            } else if searched && results.isEmpty {
                Text("Никого не нашли")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(results, id: \.stableID) { u in
                    StaffCandidateRow(user: u) {
                        try await grant(u)
                    }
                }
            }
        }
    }

    private func scheduleSearch(delay: UInt64) {
        searchTask?.cancel()
        let q = trimmed
        guard q.count >= 2 else {
            results = []
            searched = false
            searchError = nil
            searching = false
            return
        }
        generation += 1
        let gen = generation
        searchTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            if Task.isCancelled { return }
            await runSearch(q, gen: gen)
        }
    }

    @MainActor
    private func runSearch(_ q: String, gen: Int) async {
        searching = true
        searchError = nil
        do {
            let data = try await API.shared.get("/api/admin/staff/search", query: ["q": q])
            guard gen == generation else { return }
            results = data.array
            searched = true
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            searchError = APIError.describe(error)
        }
        searching = false
    }

    private func grant(_ u: JSON) async throws {
        guard let uid = u.id else { return }
        try await API.shared.post("/api/admin/staff", body: ["user_id": uid])
        onGranted()
        dismiss()
    }
}

/// Найденный пользователь с кнопкой «Назначить» (или пометкой «уже администратор»).
struct StaffCandidateRow: View {
    let user: JSON
    let grant: () async throws -> Void

    init(user: JSON, grant: @escaping () async throws -> Void) {
        self.user = user
        self.grant = grant
    }

    private var name: String {
        let fallback = "#" + user["id"].stringValue
        return user["name"].nonEmptyString ?? user["email"].nonEmptyString ?? fallback
    }

    private var contacts: String {
        var parts: [String] = []
        if let e = user["email"].nonEmptyString { parts.append(e) }
        if let p = user["phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !contacts.isEmpty {
                    Text(contacts).font(.caption).foregroundColor(Brand.muted).lineLimit(1)
                }
                Text(UsersLabels.accountType(user["account_type"].string))
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
            Spacer(minLength: 6)
            if user["is_admin"].boolValue {
                Text("уже администратор")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            } else {
                ActionButton("Назначить", style: .prominent,
                             confirm: ConfirmAction(title: "Назначить администратора?",
                                                    message: "Пользователь «" + name + "» получит полный доступ к панели площадки.",
                                                    confirmLabel: "Назначить")) {
                    try await grant()
                }
            }
        }
    }
}
