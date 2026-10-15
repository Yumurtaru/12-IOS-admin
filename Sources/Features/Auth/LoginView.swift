import SwiftUI
import UIKit

/// Вход администратора: e-mail и пароль → (если включена 2FA) код из
/// приложения-аутентификатора → (первый раз) привязка аутентификатора.
struct LoginView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if let n = session.notice {
                        InfoBanner(n, systemImage: "clock.badge.exclamationmark", color: Brand.amber)
                    }
                    stage
                }
                .padding(20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .background(Brand.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 52))
                .foregroundColor(Brand.accent)
                .padding(.top, 30)
            Text("Yumurta Admin")
                .font(.largeTitle.weight(.bold))
            Text("Админ-панель площадки")
                .foregroundColor(Brand.muted)
        }
    }

    @ViewBuilder
    private var stage: some View {
        switch session.state {
        case .needTOTP:
            TOTPStepView(setupSecret: nil, setupURI: nil)
        case .setupTOTP(let secret, let uri):
            TOTPStepView(setupSecret: secret, setupURI: uri)
        default:
            PasswordStepView()
        }
    }
}

/// Шаг 1: e-mail и пароль.
struct PasswordStepView: View {
    @EnvironmentObject private var session: Session
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.contains("@") && !password.isEmpty && !busy
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                TextField("E-mail", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .padding(14)
                Divider()
                SecureField("Пароль", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
                    .padding(14)
            }
            .background(Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let e = error {
                ErrorBanner(message: e)
            }

            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().tint(.white) } else { Text("Войти").bold() }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)
        }
        .onAppear {
            if email.isEmpty { email = session.lastEmail }
            focus = email.isEmpty ? .email : .password
        }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        let e = email
        let p = password
        Task { @MainActor in
            do {
                try await session.login(email: e, password: p)
                Haptics.success()
            } catch {
                Haptics.error()
                self.error = APIError.describe(error)
            }
            busy = false
        }
    }
}

/// Шаг 2: код из приложения-аутентификатора (и привязка при первом входе).
struct TOTPStepView: View {
    @EnvironmentObject private var session: Session
    let setupSecret: String?
    let setupURI: String?

    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false
    @FocusState private var focused: Bool

    init(setupSecret: String?, setupURI: String?) {
        self.setupSecret = setupSecret
        self.setupURI = setupURI
    }

    private var digits: String { code.filter { $0.isNumber } }
    private var canSubmit: Bool { digits.count == 6 && !busy }

    /// Секрет группами по 4 — так его легче перепечатать.
    private var groupedSecret: String {
        let s = setupSecret ?? ""
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && i % 4 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if setupSecret != nil {
                setupBlock
            } else {
                Text("Код из приложения-аутентификатора")
                    .font(.headline)
                Text("Откройте Google Authenticator (или аналог) и введите 6 цифр для Yumurta Admin.")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            }

            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(14)
                .background(Brand.card)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .focused($focused)
                .onChange(of: code) { value in
                    let only = String(value.filter { $0.isNumber }.prefix(6))
                    if only != value { code = only }
                }

            if let e = error {
                ErrorBanner(message: e)
            }

            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView().tint(.white) } else { Text("Подтвердить").bold() }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)

            Button("Назад к паролю") { session.cancelTOTP() }
                .frame(maxWidth: .infinity)
                .font(.subheadline)
        }
        .onAppear { focused = setupSecret == nil }
    }

    private var setupBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Привяжите приложение-аутентификатор")
                .font(.headline)
            Text("Это нужно один раз. Добавьте ключ в Google Authenticator (или аналог), затем введите 6 цифр из него.")
                .font(.subheadline)
                .foregroundColor(Brand.muted)
            Text(groupedSecret)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(Brand.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Button {
                    UIPasteboard.general.string = setupSecret
                    copied = true
                    Haptics.tap()
                } label: {
                    Label(copied ? "Скопировано" : "Скопировать ключ", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Spacer()
                if let uri = setupURI, let url = URL(string: uri) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Label("Открыть в аутентификаторе", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.subheadline)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        let c = digits
        Task { @MainActor in
            do {
                try await session.submitTOTP(c)
                Haptics.success()
            } catch {
                Haptics.error()
                self.error = APIError.describe(error)
                code = ""
            }
            busy = false
        }
    }
}
