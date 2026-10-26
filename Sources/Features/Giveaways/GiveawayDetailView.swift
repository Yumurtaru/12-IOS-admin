import SwiftUI

/// Карточка розыгрыша: GET /api/admin/giveaways/{id} → {giveaway:{id, title, prize,
/// pickup_text, winners_count, city_id, city, exclude_staff, participants, created_at,
/// created_by_name}, winners:[{user_id, place, name, phone, email, notified, via_push,
/// via_email, given_at, given_by_name}]}.
///
/// У победителя:
///  * «Приз вручён» — POST …/winners/{uid}/given {given: bool};
///  * «Уведомить ещё раз» — POST …/winners/{uid}/notify (с подтверждением) → строка
///    победителя (notified, via_push, via_email).
/// Номера — по переключателю «Скрыть номера» (общий для раздела, GiveawaysPrivacy).
struct GiveawayDetailView: View {
    let id: Int
    /// Что-то поменяли (вручено, уведомили) — обновить список истории.
    let onChanged: (() -> Void)?

    @ObservedObject var privacy: GiveawaysPrivacy
    @StateObject private var loader: ObjectLoader

    init(id: Int, privacy: GiveawaysPrivacy, onChanged: (() -> Void)? = nil) {
        self.id = id
        self.privacy = privacy
        self.onChanged = onChanged
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/giveaways/" + String(id)))
    }

    private var g: JSON { loader.data["giveaway"] }
    private var winners: [JSON] { loader.data["winners"].array }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Розыгрыш не найден", retry: { await loader.load() }) {
            list
        }
        .navigationTitle(g["prize"].nonEmptyString ?? "Розыгрыш")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    privacy.hidePhones.toggle()
                    Haptics.tap()
                } label: {
                    Image(systemName: privacy.hidePhones ? "eye.slash" : "eye")
                }
                .accessibilityLabel(privacy.hidePhones ? "Показать номера" : "Скрыть номера")
            }
        }
        .task { await loader.loadIfNeeded() }
    }

    private var list: some View {
        List {
            if let e = loader.lastRefreshError {
                ErrorBanner(message: e, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            infoSection
            Section {
                GiveawaysPrivacyToggle(privacy: privacy)
            }
            winnersSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await loader.load() }
    }

    private var infoSection: some View {
        Section {
            KVRow("Приз", g["prize"].string)
            KVRow("Название", g["title"].string)
            KVRow("Проведён", Fmt.date(g["created_at"].string))
            KVRow("Участников", Fmt.number(g["participants"].intValue))
            KVRow("Город", g["city"].nonEmptyString ?? "Все города")
            KVRow("Сотрудники организаций", g["exclude_staff"].bool == false ? "участвовали" : "не участвовали")
            KVRow("Победителей", String(winners.count) + " · вручено " + String(givenCount))
            if let by = g["created_by_name"].nonEmptyString {
                KVRow("Провёл", by)
            }
            if let p = g["pickup_text"].nonEmptyString {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Как забрать приз").font(.subheadline).foregroundColor(Brand.muted)
                    Text(p).font(.subheadline)
                }
            }
        } header: {
            Text("Розыгрыш")
        }
    }

    private var givenCount: Int { winners.filter { $0["given_at"].nonEmptyString != nil }.count }

    private var winnersSection: some View {
        Section {
            if winners.isEmpty {
                Text("Победителей нет").foregroundColor(Brand.muted)
            } else {
                // id — user_id: после перечитывания карточки строка (и её подсказка «Уведомление
                // отправлено») остаётся той же, а не создаётся заново.
                ForEach(winners, id: \.giveawayWinnerID) { w in
                    GiveawayWinnerActionsRow(giveawayId: id, winner: w, hidden: privacy.hidePhones, onChanged: { await changed() })
                }
            }
        } header: {
            Text("Победители")
        } footer: {
            Text("«Не уведомлён» и «Только в ленте» — у победителя нет приложения и почты: позвоните ему или нажмите «Уведомить ещё раз», когда он установит приложение.")
        }
    }

    /// После действия: перечитать карточку (тихо, без спиннера) и обновить историю.
    private func changed() async {
        await loader.load()
        onChanged?()
    }
}

/// Победитель с действиями: «Приз вручён» и «Уведомить ещё раз».
struct GiveawayWinnerActionsRow: View {
    let giveawayId: Int
    let winner: JSON
    let hidden: Bool
    let onChanged: () async -> Void

    @State private var pendingGiven: Bool?
    @State private var givenBusy = false
    @State private var notifyBusy = false
    @State private var askNotify = false
    @State private var error: String?
    @State private var notice: String?

    init(giveawayId: Int, winner: JSON, hidden: Bool, onChanged: @escaping () async -> Void) {
        self.giveawayId = giveawayId
        self.winner = winner
        self.hidden = hidden
        self.onChanged = onChanged
    }

    private var userId: Int { winner["user_id"].intValue }
    private var isGiven: Bool { winner["given_at"].nonEmptyString != nil }
    private var basePath: String {
        "/api/admin/giveaways/" + String(giveawayId) + "/winners/" + String(userId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GiveawayWinnerSummaryRow(winner: winner, hidden: hidden)
            if isGiven, let at = winner["given_at"].nonEmptyString {
                Text("Вручено " + Fmt.date(at) + (winner["given_by_name"].nonEmptyString.map { " · " + $0 } ?? ""))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Toggle(isOn: givenBinding) {
                HStack(spacing: 6) {
                    Text("Приз вручён").font(.subheadline)
                    if givenBusy { ProgressView() }
                }
            }
            .tint(Brand.green)
            .disabled(givenBusy)
            Button {
                Haptics.tap()
                askNotify = true
            } label: {
                HStack(spacing: 6) {
                    if notifyBusy { ProgressView() } else { Image(systemName: "bell.badge") }
                    Text("Уведомить ещё раз")
                }
                .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .disabled(notifyBusy)
            if let n = notice {
                Text(n).font(.caption).foregroundColor(Brand.green)
            }
            if let e = error {
                ErrorBanner(message: e, dismiss: { error = nil })
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Уведомить ещё раз?", isPresented: $askNotify, titleVisibility: .visible) {
            Button("Уведомить") { notify() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Победителю снова придёт уведомление «Вы выиграли» (в приложении и письмом, если есть почта).")
        }
    }

    private var givenBinding: Binding<Bool> {
        Binding(get: { pendingGiven ?? isGiven }, set: { setGiven($0) })
    }

    private func setGiven(_ value: Bool) {
        guard !givenBusy, value != (pendingGiven ?? isGiven) else { return }
        pendingGiven = value
        givenBusy = true
        error = nil
        notice = nil
        Task { @MainActor in
            do {
                try await API.shared.post(basePath + "/given", body: ["given": value])
                Haptics.success()
                await onChanged()
            } catch {
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
            pendingGiven = nil
            givenBusy = false
        }
    }

    private func notify() {
        guard !notifyBusy else { return }
        notifyBusy = true
        error = nil
        notice = nil
        Task { @MainActor in
            do {
                let r = try await API.shared.post(basePath + "/notify")
                if GiveawayDeliveryBadge.reached(r) {
                    Haptics.success()
                    notice = "Уведомление отправлено"
                } else {
                    Haptics.warning()
                    error = r["notified"].boolValue
                        ? "Снова не дошло: приложения и почты нет — уведомление только в ленте. Позвоните победителю."
                        : "Уведомление не создано (аккаунт заблокирован или шаблон выключен). Позвоните победителю."
                }
                await onChanged()
            } catch {
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
            notifyBusy = false
        }
    }
}

private extension JSON {
    /// Ключ строки победителя в карточке — user_id (один человек — одна строка розыгрыша).
    var giveawayWinnerID: Int { self["user_id"].intValue }
}
