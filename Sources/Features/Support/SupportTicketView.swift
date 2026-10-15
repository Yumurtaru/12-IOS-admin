import SwiftUI

/// Переписка по обращению: сообщения пузырями, ответ снизу, «Закрыть обращение».
///
/// Ответ уходит человеку в ленту уведомлений (и в Telegram, если обращение
/// пришло оттуда). Сервер возвращает delivered:false, если уведомление не
/// дошло (аккаунт заблокирован или шаблон выключен) — показываем предупреждение.
struct SupportTicketView: View {
    let id: Int
    let model: PagedListModel?

    @StateObject private var loader: ObjectLoader
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @State private var notice: String?
    @State private var showInfo = false
    @State private var pendingClose: ConfirmAction?
    @FocusState private var inputFocused: Bool

    init(id: Int, model: PagedListModel? = nil) {
        self.id = id
        self.model = model
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/support/tickets/\(id)"))
    }

    private var t: JSON { loader.data }
    private var status: String { t["status"].stringValue }
    private var messages: [JSON] { t["messages"].array }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            thread
        }
        .navigationTitle("Обращение #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await loader.loadIfNeeded() }
        .sheet(isPresented: $showInfo) { infoSheet }
        .confirmAction($pendingClose) { try await closeTicket() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showInfo = true
                } label: { Label("Сведения и пользователь", systemImage: "info.circle") }
                if status != "closed" {
                    Button(role: .destructive) {
                        pendingClose = ConfirmAction(title: "Закрыть обращение?",
                                                     message: "Если человек напишет снова, обращение откроется само.",
                                                     confirmLabel: "Закрыть")
                    } label: { Label("Закрыть обращение", systemImage: "checkmark.circle") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .disabled(loader.data.isNull)
        }
    }

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    SupportTicketHeader(ticket: t)
                    if let e = loader.lastRefreshError {
                        ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    }
                    if messages.isEmpty {
                        Text("Сообщений нет")
                            .font(.subheadline)
                            .foregroundColor(Brand.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                    ForEach(Array(messages.enumerated()), id: \.offset) { pair in
                        SupportBubble(message: pair.element, userName: t["user_name"].nonEmptyString ?? "Клиент")
                    }
                    if let n = notice {
                        InfoBanner(n, systemImage: "exclamationmark.bubble", color: Brand.amber)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .background(Brand.bg)
            .refreshable { await loader.load() }
            .onChange(of: messages.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .safeAreaInset(edge: .bottom) { composer }
        }
    }

    // MARK: - Ввод ответа

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let e = sendError {
                ErrorBanner(message: e, dismiss: { sendError = nil })
            }
            if status == "closed" {
                Text("Обращение закрыто. Ответ откроет переписку снова для человека.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ответ клиенту…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Brand.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Brand.bg)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Brand.border), alignment: .top)
    }

    private var sendButton: some View {
        Button(action: send) {
            Group {
                if sending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
            }
            .frame(width: 34, height: 34)
        }
        .foregroundColor(canSend ? Brand.accent : Brand.muted)
        .disabled(!canSend)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        let tid = id
        let m = model
        Task { @MainActor in
            do {
                let r = try await API.shared.post("/api/admin/support/tickets/\(tid)/reply", body: ["message": text])
                Haptics.success()
                draft = ""
                if r["delivered"].bool == false {
                    notice = "Ответ сохранён в переписке, но уведомление до человека не дошло (аккаунт заблокирован или шаблон «Ответ поддержки» выключен)."
                } else {
                    notice = nil
                }
                m?.update(id: tid) { row in
                    row = SupportFormat.withStatus(row, "answered")
                }
                await loader.load()
                Task { await Notifier.shared.refresh(force: true) }
            } catch {
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    sendError = APIError.describe(error)
                }
            }
            sending = false
        }
    }

    // MARK: - Сведения и закрытие

    private var infoSheet: some View {
        NavigationStack {
            SupportTicketInfo(ticket: t, onClose: { try await closeTicket() })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { showInfo = false }
                    }
                }
        }
    }

    private func closeTicket() async throws {
        try await API.shared.post("/api/admin/support/tickets/\(id)/close")
        let tid = id
        model?.update(id: tid) { row in
            row = SupportFormat.withStatus(row, "closed")
        }
        await loader.load()
        Task { await Notifier.shared.refresh(force: true) }
    }
}

/// Шапка переписки: тема, статус, пользователь, кнопка закрытия.
struct SupportTicketHeader: View {
    let ticket: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(ticket["subject"].nonEmptyString ?? "Без темы")
                    .font(.headline)
                Spacer()
                StatusBadge(SupportFormat.statusLabel(ticket["status"].string),
                            color: SupportFormat.statusColor(ticket["status"].string))
            }
            Text(line)
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var line: String {
        let name = ticket["user_name"].nonEmptyString ?? "—"
        let phone = ticket["phone"].nonEmptyString.map { " · " + Fmt.phone($0) } ?? ""
        return name + phone + " · создано " + Fmt.date(ticket["created_at"])
    }
}

/// Пузырь сообщения: клиент слева, поддержка справа.
struct SupportBubble: View {
    let message: JSON
    let userName: String

    private var fromUser: Bool { message["from_user"].boolValue }

    var body: some View {
        HStack {
            if !fromUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 3) {
                Text(fromUser ? userName : "Поддержка")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(fromUser ? Brand.muted : Color.white.opacity(0.85))
                Text(message["message"].stringValue)
                    .font(.subheadline)
                    .foregroundColor(fromUser ? Brand.text : Color.white)
                    .textSelection(.enabled)
                Text(Fmt.date(message["created_at"]))
                    .font(.caption2)
                    .foregroundColor(fromUser ? Brand.muted : Color.white.opacity(0.75))
            }
            .padding(10)
            .background(fromUser ? Brand.card : Brand.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if fromUser { Spacer(minLength: 40) }
        }
    }
}

/// Сведения об обращении и пользователе + «Закрыть обращение».
struct SupportTicketInfo: View {
    let ticket: JSON
    let onClose: () async throws -> Void

    var body: some View {
        List {
            Section("Обращение") {
                KVRow("Номер", "#" + ticket["id"].stringValue, copyable: true)
                KVRow("Тема", ticket["subject"].string)
                KVRow("Статус", SupportFormat.statusLabel(ticket["status"].string))
                KVRow("Создано", Fmt.date(ticket["created_at"]))
            }
            Section("Пользователь") {
                userRow
                phoneRow
                KVRow("Почта", ticket["email"].string, copyable: true)
            }
            if ticket["status"].string != "closed" {
                Section {
                    ActionButton("Закрыть обращение", systemImage: "checkmark.circle", role: .destructive,
                                 style: .plain,
                                 confirm: ConfirmAction(title: "Закрыть обращение?",
                                                        message: "Если человек напишет снова, обращение откроется само.",
                                                        confirmLabel: "Закрыть"),
                                 successMessage: "Обращение закрыто") {
                        try await onClose()
                    }
                }
            }
            Section { JSONInspectorView(ticket) }
        }
        .navigationTitle("Сведения")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var userRow: some View {
        let name = ticket["user_name"].nonEmptyString ?? "—"
        if let uid = ticket["user_id"].int, uid > 0 {
            NavigationLink(destination: UserDetailView(id: uid)) { KVRow("Имя", name) }
        } else {
            KVRow("Имя", name)
        }
    }

    @ViewBuilder
    private var phoneRow: some View {
        let phone = ticket["phone"].stringValue
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) { KVRow("Телефон", Fmt.phone(phone)) }
        } else {
            KVRow("Телефон", phone.isEmpty ? nil : phone)
        }
    }
}
