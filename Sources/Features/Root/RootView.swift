import SwiftUI

/// Корень: экран блокировки → вход → главные вкладки.
struct RootView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var notifier: Notifier
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if session.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
            overlay
        }
        .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
        .animation(.easeInOut(duration: 0.2), value: session.isLoggedIn)
        // id — блок отрабатывает заново после входа и после выхода.
        .task(id: session.isLoggedIn) {
            if session.isLoggedIn {
                notifier.start()
                await AdminPush.registerIfPossible()
            } else {
                notifier.stop()
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        if session.isLoggedIn && lock.isLocked {
            LockView()
                .transition(.opacity)
        } else if session.isLoggedIn && lock.isEnabled && scenePhase != .active {
            // В переключателе приложений не показываем данные площадки.
            PrivacyCover()
        }
    }
}

/// Заслонка для переключателя приложений.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 44))
                    .foregroundColor(Brand.accent)
                Text("Yumurta Admin")
                    .font(.headline)
            }
        }
    }
}

/// Экран блокировки: Face ID / код-пароль телефона.
struct LockView: View {
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var session: Session
    @State private var askSignOut = false

    var body: some View {
        ZStack {
            Brand.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundColor(Brand.accent)
                Text("Админ-панель заблокирована")
                    .font(.title3.weight(.semibold))
                Text(session.userName)
                    .foregroundColor(Brand.muted)
                if let e = lock.lastError {
                    Text(e)
                        .font(.footnote)
                        .foregroundColor(Brand.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label("Открыть — " + lock.methodName, systemImage: "faceid")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
                Button("Выйти из аккаунта") { askSignOut = true }
                    .font(.footnote)
                    .padding(.bottom, 24)
            }
        }
        .task { await lock.unlock() }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                Task {
                    await session.signOut()
                    lock.didLogin()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Потом нужно будет снова ввести e-mail и пароль.")
        }
    }
}
