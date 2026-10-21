import SwiftUI

/// Вкладка «Заявки»: всё, что ждёт администратора, по счётчикам Notifier.
/// Строка открывает раздел. Потянуть вниз — обновить сейчас.
struct InboxView: View {
    @EnvironmentObject private var notifier: Notifier

    private var waiting: [NotifyCategory] {
        NotifyCategory.allCases.filter { notifier.count($0) > 0 }
    }

    /// Пустые очереди. Категории «Курьеров» без счётчика (сервер без раздела или
    /// раздел выключен) не показываем — их строка вела бы в 404 (Notifier.isListed).
    private var clear: [NotifyCategory] {
        NotifyCategory.allCases.filter { notifier.count($0) == 0 && notifier.isListed($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if waiting.isEmpty && notifier.lastUpdated != nil {
                    Section {
                        EmptyStateView(title: "Всё разобрано", systemImage: "checkmark.seal",
                                       message: "Новых заявок, возвратов, жалоб и обращений нет.")
                            .frame(minHeight: 180)
                    }
                }
                if !waiting.isEmpty {
                    Section("Ждут действия") {
                        ForEach(waiting) { cat in
                            NavigationLink(destination: cat.section.makeRoot(openId: nil, subtab: cat.subtab)) {
                                InboxRow(category: cat)
                            }
                        }
                    }
                }
                if !clear.isEmpty && notifier.lastUpdated != nil {
                    Section("Пусто") {
                        ForEach(clear) { cat in
                            NavigationLink(destination: cat.section.makeRoot(openId: nil, subtab: cat.subtab)) {
                                InboxRow(category: cat)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await notifier.refresh(force: true) }
            .navigationTitle("Заявки")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if notifier.isRefreshing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await notifier.refresh(force: true) }
                        } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }
            .task { await notifier.refresh() }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let e = notifier.lastError {
            Section {
                ErrorBanner(message: e, retry: { Task { await notifier.refresh(force: true) } })
            }
        } else if notifier.lastUpdated == nil {
            Section {
                HStack { Spacer(); ProgressView("Проверяю очереди…"); Spacer() }
                    .padding(.vertical, 20)
            }
        }
        if notifier.authorization == .denied {
            Section {
                InfoBanner("Уведомления запрещены в настройках iOS — о новых заявках вы узнаете только здесь.",
                           systemImage: "bell.slash", color: Brand.amber)
            }
        }
    }
}

/// Строка категории: значок раздела, название, пояснение, число.
struct InboxRow: View {
    @EnvironmentObject private var notifier: Notifier
    let category: NotifyCategory

    init(category: NotifyCategory) { self.category = category }

    private var count: Int { notifier.count(category) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.section.symbol)
                .frame(width: 28)
                .foregroundColor(count > 0 ? Brand.accent : Brand.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .foregroundColor(count > 0 ? Brand.text : Brand.muted)
                subtitle
            }
            Spacer(minLength: 8)
            if !notifier.isEnabled(category) {
                Image(systemName: "bell.slash")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if count > 0 {
                Text(category.isAlarm ? "!" : String(count))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .foregroundColor(.white)
                    .background(category.isAlarm ? Brand.red : Brand.accent)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var subtitle: some View {
        let note = notifier.notes[category]
        let place = category.section.title
        Text(note ?? place)
            .font(.caption)
            .foregroundColor(note != nil ? Brand.amber : Brand.muted)
    }
}
