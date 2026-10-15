import SwiftUI

/// Лист «причина» с готовыми вариантами (как pickReason на сайте): скрыть товар,
/// отклонить отзыв, заблокировать объявление. Нажатие на вариант подставляет
/// его в поле, текст можно дописать. Используется разделами Товары, Отзывы,
/// Объявления.
///
/// ```
/// .sheet(item: $hideTarget) { p in
///     ModerationReasonSheet(title: "Причина снятия товара", reasons: ProductsFormat.hideReasons,
///                           submitTitle: "Скрыть", destructive: true) { reason in
///         try await API.shared.post("/api/admin/products/\(id)/status", body: ["hide": true, "reason": reason])
///     }
/// }
/// ```
/// Лист сам закрывается после успеха; ошибка сервера показывается внутри.
struct ModerationReasonSheet: View {
    let title: String
    let message: String?
    let reasons: [String]
    let placeholder: String
    let submitTitle: String
    let allowEmpty: Bool
    let destructive: Bool
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    /// - Parameters:
    ///   - title: заголовок листа;
    ///   - message: пояснение (что произойдёт);
    ///   - reasons: готовые варианты;
    ///   - placeholder: подсказка поля;
    ///   - submitTitle: текст кнопки;
    ///   - allowEmpty: можно отправить без причины;
    ///   - destructive: красная кнопка;
    ///   - onSubmit: отправка (бросает — ошибка покажется в листе).
    init(title: String, message: String? = nil, reasons: [String], placeholder: String = "Причина",
         submitTitle: String, allowEmpty: Bool = false, destructive: Bool = true,
         onSubmit: @escaping (String) async throws -> Void) {
        self.title = title
        self.message = message
        self.reasons = reasons
        self.placeholder = placeholder
        self.submitTitle = submitTitle
        self.allowEmpty = allowEmpty
        self.destructive = destructive
        self.onSubmit = onSubmit
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !busy && (allowEmpty || !trimmed.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                if let m = message {
                    Section { Text(m).font(.subheadline).foregroundColor(Brand.muted) }
                }
                if !reasons.isEmpty {
                    Section("Частые причины") {
                        ForEach(reasons, id: \.self) { r in
                            reasonRow(r)
                        }
                    }
                }
                Section("Причина") {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(2...6)
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    submitButton
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func reasonRow(_ r: String) -> some View {
        Button {
            Haptics.tap()
            text = r
        } label: {
            HStack {
                Text(r).foregroundColor(Brand.text)
                Spacer()
                if trimmed == r {
                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                }
            }
        }
    }

    private var submitButton: some View {
        Button(role: destructive ? .destructive : nil) {
            submit()
        } label: {
            HStack {
                Spacer()
                if busy { ProgressView() } else { Text(submitTitle).bold() }
                Spacer()
            }
        }
        .disabled(!canSubmit)
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        let value = trimmed
        let send = onSubmit
        Task { @MainActor in
            do {
                try await send(value)
                Haptics.success()
                busy = false
                dismiss()
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
        }
    }
}

/// Путь картинки из ответа сервера → адрес для AsyncImageView.
/// Сервер отдаёт пути относительно /assets/uploads/ ("products/…webp"),
/// а иногда уже полные ("/assets/uploads/…", https://…).
enum ModerationMedia {
    static func uploadsPath(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("/") { return s }
        return "/assets/uploads/" + s
    }
}
