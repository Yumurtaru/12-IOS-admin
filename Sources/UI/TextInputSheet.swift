import SwiftUI

/// Лист ввода одного текста с отправкой: причина отказа, ответ в поддержку,
/// код 2FA, пароль для опасной операции.
///
/// ```
/// @State private var askReason = false
/// .sheet(isPresented: $askReason) {
///     TextInputSheet(title: "Причина отказа", message: "Текст увидит продавец",
///                    placeholder: "Например: нет лицензии", multiline: true,
///                    submitTitle: "Отклонить", minLength: 5, destructive: true) { text in
///         try await API.shared.post("/api/admin/registrations/\(id)/reject", body: ["reason": text])
///         await loader.load()
///     }
/// }
/// ```
/// Лист сам закрывается после успеха; ошибка сервера показывается внутри, текст не теряется.
struct TextInputSheet: View {
    let title: String
    let message: String?
    let placeholder: String
    let multiline: Bool
    let secure: Bool
    let keyboard: UIKeyboardType
    let submitTitle: String
    let minLength: Int
    let destructive: Bool
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    /// - Parameters:
    ///   - title: заголовок листа;
    ///   - message: пояснение над полем;
    ///   - placeholder: подсказка в поле;
    ///   - initial: начальный текст;
    ///   - multiline: многострочное поле;
    ///   - secure: скрытый ввод (пароль);
    ///   - keyboard: клавиатура (.numberPad для кода);
    ///   - submitTitle: текст кнопки;
    ///   - minLength: минимум символов (после обрезки пробелов);
    ///   - destructive: красная кнопка;
    ///   - onSubmit: отправка (бросает — ошибка покажется в листе).
    init(title: String, message: String? = nil, placeholder: String = "", initial: String = "",
         multiline: Bool = false, secure: Bool = false, keyboard: UIKeyboardType = .default,
         submitTitle: String = "Отправить", minLength: Int = 1, destructive: Bool = false,
         onSubmit: @escaping (String) async throws -> Void) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.multiline = multiline
        self.secure = secure
        self.keyboard = keyboard
        self.submitTitle = submitTitle
        self.minLength = minLength
        self.destructive = destructive
        self.onSubmit = onSubmit
        _text = State(initialValue: initial)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { trimmed.count >= minLength && !busy }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field
                } header: {
                    if let m = message { Text(m) }
                } footer: {
                    if minLength > 1 && trimmed.count < minLength {
                        Text("Не меньше " + Fmt.plural(minLength, "символа", "символов", "символов"))
                    }
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
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
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(busy)
    }

    @ViewBuilder
    private var field: some View {
        if secure {
            SecureField(placeholder, text: $text)
                .focused($focused)
        } else if multiline {
            TextEditor(text: $text)
                .frame(minHeight: 120)
                .focused($focused)
        } else {
            TextField(placeholder, text: $text)
                .keyboardType(keyboard)
                .focused($focused)
        }
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
