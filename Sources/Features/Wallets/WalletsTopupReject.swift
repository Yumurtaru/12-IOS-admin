import SwiftUI

/// Ответы сервера на отклонение пополнения с платежом ЮKassa (П-62, А316; А516):
/// `POST /api/admin/user-topups/{id}/reject`, `/api/admin/topups/{id}/resolve action=reject`,
/// `/api/admin/topups/{id}/reject` (adminTopupRejectGuard в admin_user_wallets.php):
///  * 409 `errors.yookassa_status` = `succeeded` | `waiting_for_capture` — платёж оплачен или
///    ждёт списания, отклонять нельзя;
///  * 502 `errors.need = "force"` — ЮKassa не ответила; отклонить без проверки — повтор с
///    `"force": true`. 502 без JSON (страница хостинга) — так же: ответа нет ни от ЮKassa,
///    ни от сервера, предлагаем то же с подтверждением (отклоняется только «в ожидании»,
///    уже закрытую заявку сервер второй раз не тронет — 409).
/// Без платежа или без настроенной ЮKassa сервер отвечает как раньше.
enum TopupReject {
    /// Сервер просит подтвердить отклонение без проверки в ЮKassa (или вместо ответа пришла
    /// страница хостинга 502 — деталей нет).
    static func needsForce(_ error: Error) -> Bool {
        guard let e = error as? APIError, e.status == 502 else { return false }
        return e.details["need"].string == "force" || e.details.isNull
    }

    /// Понятный текст отказа «платёж оплачен» (nil — другой ответ).
    static func paidText(_ error: Error) -> String? {
        guard let e = error as? APIError, e.status == 409,
              let st = e.details["yookassa_status"].nonEmptyString else { return nil }
        if st == "waiting_for_capture" {
            return "Платёж в ЮKassa ждёт списания — отклонить нельзя. Деньги у плательщика заблокированы: подтвердите или отмените платёж в кабинете ЮKassa."
        }
        return "Платёж в ЮKassa оплачен — отклонить нельзя. Зачислите по факту («Проверить» / «Зачислить») или верните деньги в кабинете ЮKassa."
    }

    /// Текст ошибки для листа.
    static func describe(_ error: Error) -> String {
        paidText(error) ?? APIError.describe(error)
    }

    /// Строка «Статус в ЮKassa: …» по ответу recheck (`yookassa_status`, `yookassa_unavailable`).
    /// nil — сервер этих полей не прислал (старый сервер).
    static func recheckLine(_ r: JSON) -> String? {
        if r["yookassa_unavailable"].bool == true {
            return "ЮKassa не ответила — статус платежа неизвестен."
        }
        guard let st = r["yookassa_status"].nonEmptyString else { return nil }
        return "Статус в ЮKassa: " + WalletsLabels.yooStatus(st) + "."
    }
}

/// Лист «Отклонить / закрыть заявку» с причиной. Как TextInputSheet, но понимает ответы
/// сервера про ЮKassa: 409 «оплачен» — свой текст, 502 «не ответила» — вопрос «Отклонить
/// без проверки?» и повтор с `force: true`.
struct TopupRejectSheet: View {
    let title: String
    let message: String
    let placeholder: String
    let submitTitle: String
    /// Отправка: (причина, force). Бросает — ошибка покажется в листе.
    let send: (String, Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var busy = false
    @State private var error: String?
    @State private var askForce = false
    @FocusState private var focused: Bool

    init(title: String, message: String, placeholder: String, initial: String = "",
         submitTitle: String, send: @escaping (String, Bool) async throws -> Void) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.submitTitle = submitTitle
        self.send = send
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .focused($focused)
                        .disabled(busy)
                } header: {
                    Text(message)
                } footer: {
                    if trimmed.isEmpty && !placeholder.isEmpty {
                        Text("Пусто — уйдёт «" + placeholder + "».")
                    }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button(role: .destructive) {
                        submit(force: false)
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text(submitTitle).bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
            .onAppear { focused = true }
            .confirmationDialog("ЮKassa не ответила. Отклонить без проверки?", isPresented: $askForce,
                                titleVisibility: .visible) {
                Button("Отклонить без проверки", role: .destructive) { submit(force: true) }
                Button("Не отклонять", role: .cancel) {}
            } message: {
                Text("Сервер не смог узнать статус платежа (не ответила ЮKassa или хостинг). Если человек всё-таки оплатил, заявка закроется как неоплаченная — сначала проверьте платёж в кабинете ЮKassa.")
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func submit(force: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        let reason = trimmed.isEmpty ? placeholder : trimmed
        let work = send
        Task { @MainActor in
            do {
                try await work(reason, force)
                Haptics.success()
                busy = false
                dismiss()
            } catch {
                busy = false
                if APIError.isCancellation(error) { return }
                if !force && TopupReject.needsForce(error) {
                    Haptics.warning()
                    self.error = APIError.describe(error)
                    askForce = true
                    return
                }
                Haptics.error()
                self.error = TopupReject.describe(error)
            }
        }
    }
}
