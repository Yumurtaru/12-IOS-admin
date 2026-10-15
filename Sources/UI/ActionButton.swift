import SwiftUI

/// Описание подтверждения перед действием.
///
/// ```
/// ConfirmAction(title: "Опубликовать «Пекарня»?", message: "Организацию увидят клиенты.", confirmLabel: "Опубликовать")
/// ConfirmAction(title: "Удалить магазин?", message: "Это необратимо.", confirmLabel: "Удалить",
///               destructive: true, typedPhrase: shopName)   // нужно ввести название
/// ```
/// `typedPhrase` — для очень опасного: кнопка активна, только когда человек
/// ввёл фразу (без учёта регистра и пробелов по краям).
struct ConfirmAction: Identifiable {
    let id = UUID()
    /// Вопрос.
    let title: String
    /// Пояснение (что произойдёт, сумма).
    let message: String?
    /// Текст кнопки подтверждения.
    let confirmLabel: String
    /// Красная кнопка (удаление, блокировка, отказ).
    let destructive: Bool
    /// Фраза, которую нужно ввести для подтверждения (nil — обычный диалог).
    let typedPhrase: String?

    init(title: String, message: String? = nil, confirmLabel: String = "Подтвердить",
         destructive: Bool = false, typedPhrase: String? = nil) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.destructive = destructive
        self.typedPhrase = typedPhrase
    }
}

/// Кнопка асинхронного действия: спиннер, защита от двойного нажатия, отклик,
/// текст ошибки сервера, необязательное подтверждение.
///
/// ```
/// ActionButton("Одобрить", systemImage: "checkmark", style: .prominent) {
///     try await API.shared.post("/api/admin/registrations/\(id)/approve", body: [...])
///     await loader.load()
/// }
/// ActionButton("Заблокировать", role: .destructive,
///              confirm: ConfirmAction(title: "Заблокировать пользователя?", confirmLabel: "Заблокировать", destructive: true)) {
///     try await API.shared.post("/api/admin/users/\(id)/block", body: ["block": 1])
/// }
/// ```
/// Ошибка показывается алертом с текстом сервера; успех — `successMessage` (если задан).
struct ActionButton: View {
    /// Вид кнопки.
    enum Style {
        /// Залитая акцентом (главное действие).
        case prominent
        /// С рамкой/подложкой.
        case bordered
        /// Простая текстовая (в строках List, в меню).
        case plain
    }

    let title: String
    let systemImage: String?
    let role: ButtonRole?
    let style: Style
    let confirm: ConfirmAction?
    let successMessage: String?
    let fullWidth: Bool
    let action: () async throws -> Void

    @State private var busy = false
    @State private var error: String?
    @State private var success: String?
    @State private var askConfirm = false
    @State private var askTyped = false

    /// - Parameters:
    ///   - title: подпись;
    ///   - systemImage: значок SF Symbols;
    ///   - role: .destructive — красная;
    ///   - style: вид;
    ///   - confirm: спросить перед выполнением;
    ///   - successMessage: показать после успеха (nil — только отклик);
    ///   - fullWidth: растянуть на ширину;
    ///   - action: само действие (бросает — покажется текст ошибки).
    init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil, style: Style = .bordered,
         confirm: ConfirmAction? = nil, successMessage: String? = nil, fullWidth: Bool = false,
         action: @escaping () async throws -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.style = style
        self.confirm = confirm
        self.successMessage = successMessage
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        styled
            .disabled(busy)
            .confirmationDialog(confirm?.title ?? "", isPresented: $askConfirm, titleVisibility: .visible) {
                if let c = confirm {
                    Button(c.confirmLabel, role: c.destructive ? .destructive : nil) { run() }
                    Button("Отмена", role: .cancel) {}
                }
            } message: {
                if let m = confirm?.message { Text(m) }
            }
            .sheet(isPresented: $askTyped) {
                if let c = confirm {
                    TypedConfirmSheet(confirm: c) { run() }
                }
            }
            .alert("Не получилось", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .alert(success ?? "", isPresented: successShown) {
                Button("OK", role: .cancel) {}
            }
    }

    @ViewBuilder
    private var styled: some View {
        switch style {
        case .prominent:
            button.buttonStyle(.borderedProminent)
        case .bordered:
            button.buttonStyle(.bordered)
        case .plain:
            button.buttonStyle(.borderless)
        }
    }

    private var button: some View {
        Button(role: role) {
            tapped()
        } label: {
            HStack(spacing: 6) {
                if busy {
                    ProgressView()
                } else if let img = systemImage {
                    Image(systemName: img)
                }
                Text(title)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    }

    private var successShown: Binding<Bool> {
        Binding(get: { success != nil }, set: { if !$0 { success = nil } })
    }

    private func tapped() {
        guard !busy else { return }
        guard let c = confirm else { run(); return }
        Haptics.tap()
        if c.typedPhrase != nil { askTyped = true } else { askConfirm = true }
    }

    private func run() {
        guard !busy else { return }
        busy = true
        let work = action
        let okText = successMessage
        Task { @MainActor in
            do {
                try await work()
                Haptics.success()
                success = okText
            } catch {
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
            busy = false
        }
    }
}

/// Лист «введите фразу, чтобы подтвердить» для очень опасных действий.
struct TypedConfirmSheet: View {
    let confirm: ConfirmAction
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    init(confirm: ConfirmAction, onConfirm: @escaping () -> Void) {
        self.confirm = confirm
        self.onConfirm = onConfirm
    }

    private var matches: Bool {
        let want = (confirm.typedPhrase ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let got = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !want.isEmpty && want == got
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let m = confirm.message { Text(m) }
                    Text("Чтобы подтвердить, введите: «" + (confirm.typedPhrase ?? "") + "»")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                    TextField("Введите для подтверждения", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button(role: confirm.destructive ? .destructive : nil) {
                        Haptics.warning()
                        dismiss()
                        onConfirm()
                    } label: {
                        Text(confirm.confirmLabel).frame(maxWidth: .infinity)
                    }
                    .disabled(!matches)
                }
            }
            .navigationTitle(confirm.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}

extension View {
    /// Подтверждение + выполнение действия, запущенного не кнопкой ActionButton
    /// (свайп, пункт меню). Показ: присвоить `pending = ConfirmAction(...)`.
    ///
    /// ```
    /// @State private var pending: ConfirmAction?
    /// .swipeActions { Button("Удалить", role: .destructive) { pending = ConfirmAction(title: "Удалить город?", confirmLabel: "Удалить", destructive: true) } }
    /// .confirmAction($pending) { try await API.shared.delete("/api/admin/cities/\(id)") }
    /// ```
    func confirmAction(_ pending: Binding<ConfirmAction?>, perform: @escaping () async throws -> Void) -> some View {
        modifier(ConfirmActionModifier(pending: pending, perform: perform))
    }
}

/// Реализация `.confirmAction(...)`.
struct ConfirmActionModifier: ViewModifier {
    @Binding var pending: ConfirmAction?
    let perform: () async throws -> Void
    @State private var current: ConfirmAction?
    @State private var showDialog = false
    @State private var showTyped = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: pending?.id) { _ in
                guard let p = pending else { return }
                current = p
                pending = nil
                if p.typedPhrase != nil { showTyped = true } else { showDialog = true }
            }
            .confirmationDialog(current?.title ?? "", isPresented: $showDialog, titleVisibility: .visible) {
                if let c = current {
                    Button(c.confirmLabel, role: c.destructive ? .destructive : nil) { run() }
                    Button("Отмена", role: .cancel) {}
                }
            } message: {
                if let m = current?.message { Text(m) }
            }
            .sheet(isPresented: $showTyped) {
                if let c = current {
                    TypedConfirmSheet(confirm: c) { run() }
                }
            }
            .alert("Не получилось", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    }

    private func run() {
        let work = perform
        Task { @MainActor in
            do {
                try await work()
                Haptics.success()
            } catch {
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
        }
    }
}
