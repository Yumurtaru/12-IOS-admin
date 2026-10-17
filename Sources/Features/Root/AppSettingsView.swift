import SwiftUI
import UIKit

/// «Настройки приложения»: блокировка Face ID, категории уведомлений, выход, версия.
struct AppSettingsView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var notifier: Notifier
    @State private var askSignOut = false
    @State private var signingOut = false

    var body: some View {
        List {
            securitySection
            notificationsSection
            categoriesSection
            accountSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Настройки приложения")
        .task { await notifier.refreshAuthorization() }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                signingOut = true
                Task {
                    await session.signOut()
                    signingOut = false
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сессия на сервере будет закрыта, уведомления на этом телефоне прекратятся.")
        }
    }

    // MARK: - Защита

    private var lockBinding: Binding<Bool> {
        Binding(get: { lock.isEnabled }, set: { on in Task { await lock.setEnabled(on) } })
    }

    private var securitySection: some View {
        Section {
            Toggle(isOn: lockBinding) {
                Label("Блокировка: " + lock.methodName, systemImage: "faceid")
            }
            .disabled(!lock.isAvailable)
        } header: {
            Text("Защита")
        } footer: {
            if lock.isAvailable {
                Text("Приложение спросит " + lock.methodName + " при запуске и после 5 минут в фоне.")
            } else {
                Text("На телефоне не задан код-пароль — блокировать нечем. Задайте его в настройках iOS.")
            }
        }
    }

    // MARK: - Уведомления

    private var permissionText: String {
        switch notifier.authorization {
        case .authorized, .provisional, .ephemeral: return "Разрешены"
        case .denied: return "Запрещены в настройках iOS"
        default: return "Ещё не разрешены"
        }
    }

    private var notificationsSection: some View {
        Section {
            HStack {
                Label("Уведомления", systemImage: "bell")
                Spacer()
                Text(permissionText).foregroundColor(Brand.muted)
            }
            permissionButton
            Button {
                Task { await notifier.refresh(force: true) }
            } label: {
                HStack {
                    Label("Проверить очереди сейчас", systemImage: "arrow.clockwise")
                    Spacer()
                    if notifier.isRefreshing { ProgressView() }
                }
            }
            .disabled(notifier.isRefreshing)
            if let d = notifier.lastUpdated {
                KVRow("Последняя проверка", Fmt.time(Fmt.serverDateTime(d)))
            }
        } header: {
            Text("Уведомления")
        } footer: {
            Text(pushFooter)
        }
    }

    private var pushFooter: String {
        // С включёнными push (П-29.1) «Сейчас уведомления локальные» было бы неправдой.
        let server = AdminPush.serverSupportsAdminPlatform
        let lead = server ? "Сервер присылает мгновенные push о новых заявках, обращениях и сообщениях организаций. Кроме того, "
                          : "Сейчас уведомления локальные: "
        let local = "приложение само проверяет очереди — каждую минуту, пока открыто, и в фоне примерно раз в 15–60 минут (когда решит iOS)."
        let tail = server ? "" : " Мгновенные push от сервера появятся, когда сервер научится слать их приложению админа (платформа ios_admin)."
        return lead + local + tail
    }

    @ViewBuilder
    private var permissionButton: some View {
        switch notifier.authorization {
        case .notDetermined:
            Button {
                Task { await notifier.requestPermission() }
            } label: {
                Label("Разрешить уведомления", systemImage: "bell.badge")
            }
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Открыть настройки iOS", systemImage: "gear")
            }
        default:
            EmptyView()
        }
    }

    private var categoriesSection: some View {
        Section {
            ForEach(NotifyCategory.allCases) { cat in
                Toggle(isOn: categoryBinding(cat)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cat.title)
                        Text(cat.section.title)
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                    }
                }
            }
        } header: {
            Text("О чём сообщать")
        } footer: {
            // Серверный push при закрытом приложении показывает сама iOS — переключатель его не остановит.
            Text("Выключенная категория не показывает уведомления, пока приложение открыто, не присылает напоминаний от самого приложения и не входит в число на значке, но остаётся видна во вкладке «Заявки». Push от сервера, когда приложение закрыто, приходят всегда — их можно отключить в настройках iOS.")
        }
    }

    private func categoryBinding(_ c: NotifyCategory) -> Binding<Bool> {
        Binding(get: { notifier.isEnabled(c) }, set: { notifier.setEnabled(c, $0) })
    }

    // MARK: - Аккаунт и версия

    private var accountSection: some View {
        Section("Аккаунт") {
            KVRow("Имя", session.user["name"].string)
            KVRow("E-mail", session.user["email"].string, copyable: true)
            Button(role: .destructive) {
                askSignOut = true
            } label: {
                HStack {
                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                    Spacer()
                    if signingOut { ProgressView() }
                }
            }
            .disabled(signingOut)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return v + " (сборка " + b + ")"
    }

    private var aboutSection: some View {
        Section("О приложении") {
            KVRow("Версия", versionText)
            KVRow("Сайт", API.baseURL.host)
        }
    }
}
