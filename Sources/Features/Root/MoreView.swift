import SwiftUI

/// Вкладка «Ещё»: все 26 разделов в порядке меню сайта + «Настройки приложения».
struct MoreView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notifier: Notifier

    var body: some View {
        NavigationStack(path: $router.morePath) {
            List {
                Section("Разделы") {
                    ForEach(AdminSection.allCases) { s in
                        NavigationLink(value: MoreRoute.section(s, openId: nil)) {
                            MoreRow(section: s, waiting: waiting(in: s))
                        }
                    }
                }
                Section {
                    NavigationLink(value: MoreRoute.appSettings) {
                        Label("Настройки приложения", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Ещё")
            .navigationDestination(for: MoreRoute.self) { route in
                destination(route)
            }
        }
    }

    /// Сколько ждёт в разделе (по включённым категориям Notifier).
    private func waiting(in s: AdminSection) -> Int {
        var n = 0
        for c in NotifyCategory.allCases where c.section == s && notifier.isEnabled(c) {
            n += notifier.count(c)
        }
        return n
    }

    @ViewBuilder
    private func destination(_ route: MoreRoute) -> some View {
        switch route {
        case .section(let s, let id, let sub):
            s.makeRoot(openId: id, subtab: sub)
        case .appSettings:
            AppSettingsView()
        }
    }
}

/// Строка раздела в «Ещё».
struct MoreRow: View {
    let section: AdminSection
    let waiting: Int

    init(section: AdminSection, waiting: Int) {
        self.section = section
        self.waiting = waiting
    }

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.symbol)
            Spacer()
            if waiting > 0 {
                Text(String(waiting))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .foregroundColor(.white)
                    .background(Brand.accent)
                    .clipShape(Capsule())
            }
        }
    }
}
