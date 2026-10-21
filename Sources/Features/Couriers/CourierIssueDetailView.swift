import SwiftUI

/// Карточка проблемы с доставкой или жалобы по id — для push pool_problem / pool_complaint
/// (волна А92, ответ на П-45 №2):
///
/// * GET /api/admin/pool/problems/{id} — объект той же формы, что строка списка «Проблем»
///   (CourierPool::problemView); GET /api/admin/pool/complaints/{id} — как строка «Жалоб»
///   (complaintView). Нет такой записи — 404 not_found.
/// * Показываем ту же карточку, что во вкладке (CourierProblemCard / CourierComplaintCard), и те же
///   решения: POST …/problems/{id}/resolve {action: uphold|void, note},
///   POST …/complaints/{id}/resolve {action: dismiss|warn|block|close_call|resolve, note}.
///
/// 404 (записи нет или сервер старый, без ручки по id) — `onMissing`: экран закрывается,
/// остаётся вкладка «Проблемы» / «Жалобы» раздела, как было до А92.
struct CourierIssueDetailView: View {
    /// Что открыто.
    enum Kind {
        case problem, complaint
    }

    let kind: Kind
    let id: Int
    /// После решения или изменения курьера — обновить вкладку под карточкой и сводку.
    let onChanged: () -> Void
    /// Записи нет (404) — вернуться к вкладке.
    let onMissing: () -> Void

    @State private var item: JSON = .null
    @State private var state: LoadState = .idle
    /// Ошибка повторной загрузки (на экране прежние данные).
    @State private var refreshError: String?
    @State private var target: CourierIssueTarget?
    @State private var missingHandled = false

    init(kind: Kind, id: Int, onChanged: @escaping () -> Void, onMissing: @escaping () -> Void) {
        self.kind = kind
        self.id = id
        self.onChanged = onChanged
        self.onMissing = onMissing
    }

    private var base: String {
        (kind == .problem ? "/api/admin/pool/problems/" : "/api/admin/pool/complaints/") + String(id)
    }

    var body: some View {
        List {
            if let err = refreshError {
                ErrorBanner(message: err, retry: { Task { await load() } })
                    .listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind == .problem ? "Проблема с доставкой" : "Жалоба")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            if state == .idle { await load() }
        }
        .sheet(item: $target) { t in
            resolveSheet(t)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await load() })
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .empty:
            EmptyStateView(title: kind == .problem ? "Проблема не найдена" : "Жалоба не найдена",
                           systemImage: "questionmark.circle")
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .loaded:
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        switch kind {
        case .problem:
            CourierProblemCard(problem: item, onCourierChanged: onChanged) { action in
                target = CourierIssueTarget(itemId: id, action: action, suggestion: nil)
            }
        case .complaint:
            CourierComplaintCard(complaint: item, onCourierChanged: onChanged) { action in
                target = CourierIssueTarget(itemId: id, action: action,
                                            suggestion: CourierComplaintsScreen.suggestion(item, action))
            }
        }
    }

    /// Загрузить запись. 404 при первой загрузке — к вкладке (onMissing), один раз.
    private func load() async {
        if item.isNull { state = .loading }
        do {
            let j = try await API.shared.get(base)
            guard j.isObject else {
                if item.isNull { state = .empty(nil) }
                return
            }
            item = j
            refreshError = nil
            state = .loaded
        } catch {
            if APIError.isCancellation(error) { return }
            let text = APIError.describe(error)
            if item.isNull {
                state = .failed(text)
                if let e = error as? APIError, e.status == 404, !missingHandled {
                    missingHandled = true
                    onMissing()
                }
            } else {
                refreshError = text
            }
        }
    }

    // MARK: - Решения (те же листы и тексты, что во вкладках «Проблемы» и «Жалобы»)

    @ViewBuilder
    private func resolveSheet(_ t: CourierIssueTarget) -> some View {
        switch kind {
        case .problem: problemSheet(t)
        case .complaint: complaintSheet(t)
        }
    }

    private func problemSheet(_ t: CourierIssueTarget) -> some View {
        let uphold = t.action == "uphold"
        let title = uphold ? "Оставить возмещение" : "Снять с курьера"
        let message = uphold
            ? "Сумма возмещения остаётся долгом курьера перед заведением. Курьеру придёт уведомление."
            : "Запись о возмещении снимется с курьера, его долг уменьшится. Курьеру придёт уведомление."
        return CourierReasonSheet(title: title, message: message, placeholder: "Комментарий — курьер увидит",
                                  submitTitle: title, allowEmpty: true, destructive: uphold,
                                  confirm: ConfirmAction(title: title + "?",
                                                         message: "Решение по проблеме изменить будет нельзя.",
                                                         confirmLabel: title, destructive: uphold)) { note in
            try await resolve(t, note: note)
        }
    }

    private func complaintSheet(_ t: CourierIssueTarget) -> some View {
        let title = CourierIssuesFormat.actionTitle(t.action)
        let danger = t.action == "block" || t.action == "close_call"
        let reasons: [String] = t.suggestion.map { [$0] } ?? []
        return CourierReasonSheet(title: title, message: CourierIssuesFormat.actionMessage(t.action),
                                  reasons: reasons,
                                  placeholder: t.action == "warn" ? "Текст предупреждения" : "Комментарий",
                                  initial: t.suggestion ?? "",
                                  submitTitle: title, allowEmpty: true, destructive: danger,
                                  confirm: ConfirmAction(title: title + "?",
                                                         message: "Жалоба закроется, решение изменить будет нельзя.",
                                                         confirmLabel: title, destructive: danger)) { note in
            try await resolve(t, note: note)
        }
    }

    /// POST …/{id}/resolve. Ответ — запись целиком: показываем её; 409 (уже решил другой
    /// администратор, вызов уже закрыт) — перечитываем запись и показываем текст ошибки в листе.
    private func resolve(_ t: CourierIssueTarget, note: String) async throws {
        let res: JSON
        do {
            res = try await API.shared.post(base + "/resolve", body: ["action": t.action, "note": note])
        } catch {
            if let e = error as? APIError, e.status == 409 {
                Task { await load() }
                onChanged()
            }
            throw error
        }
        if res.isObject && res.id != nil {
            item = res
        } else {
            Task { await load() }
        }
        onChanged()
        Task { await Notifier.shared.refresh(force: true) }
    }
}
