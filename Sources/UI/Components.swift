import SwiftUI
import UIKit

/// Строка «название — значение» для экранов деталей (внутри List/Section).
///
/// ```
/// KVRow("Телефон", Fmt.phone(user["phone"].string), copyable: true)
/// KVRow("Баланс", json: shop["balance"], money: true)
/// ```
struct KVRow: View {
    let title: String
    let value: String
    var copyable: Bool = false

    /// Значение строкой (nil/пусто → «—»). copyable — долгое нажатие копирует.
    init(_ title: String, _ value: String?, copyable: Bool = false) {
        self.title = title
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.value = v.isEmpty ? "—" : v
        self.copyable = copyable
    }

    /// Значение из JSON как есть (`raw`) или деньгами (`money: true`).
    init(_ title: String, json: JSON, money: Bool = false, copyable: Bool = false) {
        self.title = title
        let s = money ? Fmt.money(json) : (json.isNull ? "—" : json.raw)
        self.value = s.isEmpty ? "—" : s
        self.copyable = copyable
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundColor(Brand.muted)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundColor(Brand.text)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .contextMenu {
            if copyable {
                Button {
                    UIPasteboard.general.string = value
                    Haptics.tap()
                } label: { Label("Скопировать", systemImage: "doc.on.doc") }
            }
        }
    }
}

/// Карточка с заголовком — для экранов на ScrollView (не List).
///
/// ```
/// SectionCard("Владелец") { KVRow("Имя", owner); KVRow("Телефон", phone) }
/// ```
struct SectionCard<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title {
                Text(t)
                    .font(.headline)
                    .foregroundColor(Brand.text)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Цветная плашка статуса.
///
/// ```
/// StatusBadge("Активен", color: Brand.green)
/// StatusBadge(status: row["status"].string)          // подпись и цвет по коду статуса
/// StatusBadge(status: "pending", label: "Ждёт оплаты")
/// ```
struct StatusBadge: View {
    let text: String
    let color: Color

    /// Произвольный текст и цвет.
    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    /// По коду статуса: подпись из Fmt.statusLabel (или своя), цвет из StatusBadge.tone.
    init(status: String?, label: String? = nil) {
        self.text = label ?? Fmt.statusLabel(status)
        self.color = StatusBadge.tone(for: status)
    }

    /// Цвет частых статусов: ожидание — янтарный, успех — зелёный, отказ — красный.
    static func tone(for status: String?) -> Color {
        switch status ?? "" {
        case "pending", "review", "reviewing", "more_info_needed", "new", "open", "draft":
            return Brand.amber
        case "active", "approved", "paid", "done", "confirmed", "resolved", "published", "answered", "charged":
            return Brand.green
        case "rejected", "blocked", "cancelled", "failed", "expired", "suspended":
            return Brand.red
        case "accepted", "preparing", "ready", "in_delivery":
            return Brand.blue
        default:
            return Brand.muted
        }
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(color)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

/// Сумма в рублях: `MoneyText(row["total"])`, `MoneyText(value: 1250)`.
struct MoneyText: View {
    let text: String
    var negativeRed: Bool = true
    private let isNegative: Bool

    /// Из JSON (число или строка "12.50").
    init(_ json: JSON, negativeRed: Bool = true) {
        let d = json.decimal
        self.text = Fmt.money(d)
        self.negativeRed = negativeRed
        self.isNegative = (d ?? 0) < 0
    }

    /// Из Decimal.
    init(value: Decimal?, negativeRed: Bool = true) {
        self.text = Fmt.money(value)
        self.negativeRed = negativeRed
        self.isNegative = (value ?? 0) < 0
    }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundColor(negativeRed && isNegative ? Brand.red : Brand.text)
    }
}

/// Пустое состояние: значок, заголовок, пояснение.
struct EmptyStateView: View {
    let title: String
    var systemImage: String = "tray"
    var message: String? = nil

    init(title: String, systemImage: String = "tray", message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38))
                .foregroundColor(Brand.muted)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let m = message {
                Text(m)
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Красная плашка ошибки над содержимым, с «Повторить» и/или крестиком.
///
/// ```
/// if let e = loader.lastRefreshError { ErrorBanner(message: e, retry: { Task { await loader.load() } }) }
/// ```
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil
    var dismiss: (() -> Void)? = nil

    init(message: String, retry: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Brand.red)
            Text(message)
                .font(.footnote)
                .foregroundColor(Brand.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let r = retry {
                Button("Повторить", action: r)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            if let d = dismiss {
                Button(action: d) { Image(systemName: "xmark") }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Brand.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Плашка-подсказка (информация, не ошибка).
struct InfoBanner: View {
    let text: String
    var systemImage: String = "info.circle"
    var color: Color = Brand.blue

    init(_ text: String, systemImage: String = "info.circle", color: Color = Brand.blue) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundColor(color)
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Заглушка раздела, пока его строитель не заменил RootView.
struct SectionStubView: View {
    let section: AdminSection
    var openId: Int? = nil

    init(section: AdminSection, openId: Int? = nil) {
        self.section = section
        self.openId = openId
    }

    var body: some View {
        EmptyStateView(title: section.title, systemImage: section.symbol,
                       message: "Раздел в разработке" + (openId.map { " (объект #" + String($0) + ")" } ?? ""))
            .navigationTitle(section.title)
    }
}
