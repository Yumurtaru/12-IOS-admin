import SwiftUI
import UIKit

/// Общее для раздела «Розыгрыши»: ключ «Скрыть номера», вкладки, строка человека,
/// плашка доставки уведомления, место победителя.
enum GiveawaysFormat {
    /// Победителей — от 1 до 50 (Giveaway::MAX_WINNERS).
    static let maxWinners = 50

    /// «3 человека».
    static func people(_ n: Int) -> String { Fmt.plural(n, "человек", "человека", "человек") }

    /// «из 120 участников».
    static func participants(_ n: Int) -> String { Fmt.plural(n, "участника", "участников", "участников") }

    /// «2 победителя».
    static func winners(_ n: Int) -> String { Fmt.plural(n, "победитель", "победителя", "победителей") }

    /// Описание отбора участников: «все города, без сотрудников организаций».
    static func whereText(city: String?, excludeStaff: Bool) -> String {
        let c = city.map { "город " + $0 } ?? "все города"
        return c + (excludeStaff ? ", без сотрудников организаций" : ", сотрудники организаций тоже участвуют")
    }

    /// Ключ повтора розыгрыша (draw_key): [A-Za-z0-9_-], до 64 символов.
    static func newDrawKey() -> String {
        "gw-ios-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Вкладки раздела.
enum GiveawaysTab: String, CaseIterable, Identifiable {
    case participants
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .participants: return "Участники"
        case .history: return "История"
        }
    }
}

/// «Скрыть номера» — на время, пока открыт раздел.
///
/// НЕ запоминается (экран раздела могут показывать на трансляции): экземпляр
/// создаёт корень раздела (`@StateObject` в GiveawaysRootView) при каждом входе
/// в раздел — и при запуске приложения — со значением «скрыто». Выключение
/// действует, пока раздел открыт; вышли и вошли снова — номера опять скрыты.
/// Экраны раздела (лист розыгрыша, карточка) получают тот же экземпляр параметром.
@MainActor
final class GiveawaysPrivacy: ObservableObject {
    /// true — видно имя и последние 5 цифр телефона, почта и id скрыты.
    @Published var hidePhones = true

    init() {}
}

/// Переключатель «Скрыть номера» (общий для всех экранов раздела).
struct GiveawaysPrivacyToggle: View {
    @ObservedObject var privacy: GiveawaysPrivacy

    init(privacy: GiveawaysPrivacy) {
        self.privacy = privacy
    }

    var body: some View {
        Toggle(isOn: $privacy.hidePhones) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Скрыть номера", systemImage: privacy.hidePhones ? "eye.slash" : "eye")
                    .font(.subheadline.weight(.semibold))
                Text(privacy.hidePhones ? "Видно имя и последние 5 цифр телефона" : "Видны полные номера и почта — до выхода из раздела")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
        .tint(Brand.accent)
    }
}

/// Имя и телефон человека с учётом «Скрыть номера».
///
/// Скрыто: имя (пустое — «Без имени») и `Fmt.maskPhone` — «+7 (•••) ••2-11-91»;
/// почта и id не показываются. Открыто: телефон как отдал сервер, почта, «#id».
/// Нет телефона — только имя.
struct GiveawayPersonText: View {
    let name: String?
    let phone: String?
    let email: String?
    let userId: Int?
    let hidden: Bool

    init(name: String?, phone: String?, email: String?, userId: Int?, hidden: Bool) {
        self.name = name
        self.phone = phone
        self.email = email
        self.userId = userId
        self.hidden = hidden
    }

    /// Из строки ответа сервера (участник: id; победитель: user_id).
    init(person: JSON, idKey: String, hidden: Bool) {
        self.init(name: person["name"].string, phone: person["phone"].string, email: person["email"].string,
                  userId: person[idKey].int, hidden: hidden)
    }

    private var phoneText: String? { Fmt.contactPhone(phone, hidden: hidden) }

    private var extraText: String? {
        guard !hidden else { return nil }
        var parts: [String] = []
        if let id = userId { parts.append("#" + String(id)) }
        if let e = email?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty { parts.append(e) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.personName(name, hidden: hidden))
                .font(.body.weight(.semibold))
                .foregroundColor(Brand.text)
                .lineLimit(2)
            if let p = phoneText {
                Text(p)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundColor(Brand.text)
            }
            if let x = extraText {
                Text(x)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            // Позвонить и скопировать — только когда номера открыты.
            if !hidden, let raw = phone?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                if let url = Fmt.phoneURL(raw) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: { Label("Позвонить", systemImage: "phone") }
                }
                Button {
                    UIPasteboard.general.string = raw
                    Haptics.tap()
                } label: { Label("Скопировать номер", systemImage: "doc.on.doc") }
            }
        }
    }
}

/// Номер места победителя в кружке.
struct GiveawayPlaceBadge: View {
    let place: Int

    init(place: Int) { self.place = place }

    var body: some View {
        Text(String(place))
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .foregroundColor(.white)
            .frame(width: 30, height: 30)
            .background(Brand.accent)
            .clipShape(Circle())
    }
}

/// Чем дошло уведомление «Вы выиграли» (как delivery() в admin-giveaways.js).
struct GiveawayDeliveryBadge: View {
    let winner: JSON

    init(winner: JSON) { self.winner = winner }

    /// Дошло ли push или письмом.
    static func reached(_ w: JSON) -> Bool { w["via_push"].boolValue || w["via_email"].boolValue }

    var body: some View {
        if !winner["notified"].boolValue {
            StatusBadge("Не уведомлён — позвоните", color: Brand.red)
        } else if GiveawayDeliveryBadge.reached(winner) {
            StatusBadge("Уведомлён: " + channels, color: Brand.green)
        } else {
            StatusBadge("Только в ленте — позвоните", color: Brand.amber)
        }
    }

    private var channels: String {
        var ch: [String] = []
        if winner["via_push"].boolValue { ch.append("push") }
        if winner["via_email"].boolValue { ch.append("письмо") }
        return ch.joined(separator: " + ")
    }
}

/// Строка победителя без действий (результат розыгрыша, история).
struct GiveawayWinnerSummaryRow: View {
    let winner: JSON
    let prize: String?
    let hidden: Bool

    init(winner: JSON, prize: String? = nil, hidden: Bool) {
        self.winner = winner
        self.prize = prize
        self.hidden = hidden
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GiveawayPlaceBadge(place: winner["place"].intValue)
            VStack(alignment: .leading, spacing: 4) {
                GiveawayPersonText(person: winner, idKey: "user_id", hidden: hidden)
                if let p = prize?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                    Text("Выиграл(а) «" + p + "»")
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
                HStack(spacing: 6) {
                    GiveawayDeliveryBadge(winner: winner)
                    if winner["given_at"].nonEmptyString != nil {
                        StatusBadge("Вручено", color: Brand.green)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
