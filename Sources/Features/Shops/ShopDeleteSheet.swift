import SwiftUI
import UIKit

/// Удаление организации со всем содержимым: POST /api/admin/shops/{id}/delete
/// {confirm_name, password | code}. Показывает предпросмотр (delete-preview:
/// что исчезнет), требует набрать название и подтвердить паролем администратора
/// или кодом 2FA (что именно — говорит сервер полем has_2fa), как на сайте.
///
/// Удаление крупной организации (ShopPurge::purge — все таблицы и файлы) идёт до 10 минут
/// и доводится сервером до конца, даже если приложение отключилось (П-62, А316) — ждём
/// ответа 11 минут. Ответ так и не пришёл (нет связи, обрыв, 5xx) — удаление могло пройти,
/// а код 2FA уже израсходован: перечитываем карточку (GET /api/admin/shops/{id}: 404 —
/// удалена, иначе — на месте) и говорим, что вышло; после закрытия листа карточка
/// перечитывается (ShopDetailView).
struct ShopDeleteSheet: View {
    let shopId: Int
    let shopName: String
    let preview: JSON
    /// Вызывается после удаления с текстом итога.
    let onDeleted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typedName = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?
    /// Ответ на удаление не пришёл — исход выясняем перечитыванием карточки.
    @State private var unknown = false
    @State private var checking = false
    @State private var checkNote: String?
    /// Когда ушёл запрос на удаление: первые 11 минут «организация на месте» значит
    /// «удаление ещё может идти» — второе удаление не предлагаем.
    @State private var sentAt: Date?

    /// Ожидание ответа на удаление, с: сервер доводит удаление до 10 мин — ждём 11.
    static let deleteTimeout: TimeInterval = 660

    init(shopId: Int, shopName: String, preview: JSON, onDeleted: @escaping (String) -> Void) {
        self.shopId = shopId
        self.shopName = shopName
        self.preview = preview
        self.onDeleted = onDeleted
    }

    private var counts: JSON { preview["counts"] }
    private var has2FA: Bool { preview["has_2fa"].boolValue }
    private var name: String { preview["shop"]["name"].nonEmptyString ?? shopName }
    private var hasHistory: Bool { counts["orders"].intValue > 0 }

    /// Как на сайте: без учёта регистра, лишние пробелы схлопываются.
    private static func norm(_ s: String) -> String {
        let parts = s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        return parts.joined(separator: " ")
    }

    private var canDelete: Bool {
        !busy && !checking && !unknown && !secret.isEmpty && ShopDeleteSheet.norm(typedName) == ShopDeleteSheet.norm(name)
    }

    private var rows: [ShopDeleteCount] {
        let keys: [(String, String)] = [
            ("Товары", "products"), ("Услуги", "services"), ("Заказы", "orders"),
            ("Фото товаров", "photos"), ("Отзывы", "reviews"), ("Сотрудники", "employees"),
            ("Мастера", "masters"), ("Движения по кошельку", "wallet_ops"),
        ]
        var out: [ShopDeleteCount] = []
        for (title, key) in keys {
            let n = counts[key].intValue
            if n > 0 { out.append(ShopDeleteCount(title: title, count: n)) }
        }
        let files = preview["files"].intValue
        if files > 0 { out.append(ShopDeleteCount(title: "Файлов на диске", count: files)) }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                whatSection
                if hasHistory { historySection }
                confirmSection
                    .disabled(busy || unknown || checking)
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                if unknown {
                    unknownSection
                } else {
                    Section {
                        Button(role: .destructive) {
                            submit()
                        } label: {
                            HStack {
                                Spacer()
                                if busy { ProgressView() } else { Text("Удалить навсегда").bold() }
                                Spacer()
                            }
                        }
                        .disabled(!canDelete)
                    } footer: {
                        if busy {
                            Text("Удаляем… У крупной организации это может занять до 10 минут — не закрывайте приложение и не блокируйте телефон.")
                        }
                    }
                }
            }
            .navigationTitle("Удалить «" + name + "»?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(unknown ? "Закрыть" : "Отмена") { dismiss() }.disabled(busy || checking)
                }
            }
        }
        .interactiveDismissDisabled(busy || checking || unknown)
    }

    /// Ответ не пришёл: «Удаление могло пройти» и «Проверить» (перечитать карточку).
    private var unknownSection: some View {
        Section {
            InfoBanner(checkNote ?? "Ответ сервера не пришёл. Удаление могло пройти — проверяем, на месте ли организация.",
                       systemImage: "exclamationmark.triangle.fill", color: Brand.amber)
            Button {
                Task { await checkDeleted() }
            } label: {
                HStack {
                    Spacer()
                    if checking {
                        ProgressView()
                        Text("Проверяем…")
                    } else {
                        Label(checkNote == nil ? "Проверить, удалена ли" : "Проверить ещё раз", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                }
            }
            .disabled(checking)
        } header: {
            Text("Удаление могло пройти")
        }
    }

    /// Перечитать карточку: 404 — удалена (закрыть как успех), 200 — на месте.
    private func checkDeleted() async {
        guard unknown, !checking else { return }
        checking = true
        defer { checking = false }
        let fallbackName = name
        do {
            let d = try await API.shared.get("/api/admin/shops/" + String(shopId))
            if d.isObject && (d.id == nil || d.id == shopId) {
                let elapsed = Date().timeIntervalSince(sentAt ?? .distantPast)
                if elapsed < ShopDeleteSheet.deleteTimeout {
                    // Сервер доводит удаление до 10 минут и после обрыва связи — пока это
                    // время не вышло, «на месте» не значит «не удалена».
                    let left = Int(((ShopDeleteSheet.deleteTimeout - elapsed) / 60).rounded(.up))
                    checkNote = "Проверено в " + MoneyOp.nowText() + ": организация пока на месте, но удаление может ещё идти на сервере (до 10 минут после отправки). Проверьте ещё раз через минуту; второе удаление — не раньше чем через " + String(left) + " мин, если она так и останется."
                    return
                }
                // Организация на месте: удаление не прошло. Код 2FA мог быть
                // израсходован — для новой попытки нужен свежий.
                unknown = false
                secret = ""
                checkNote = nil
                error = "Проверено в " + MoneyOp.nowText() + ": организация на месте — удаление не прошло. Если нужно — удалите ещё раз (нужен новый " + (has2FA ? "код" : "ввод пароля") + ")."
                return
            }
            checkNote = "Сервер ответил непонятно. Проверьте ещё раз через минуту."
        } catch {
            if let e = error as? APIError, e.status == 404 {
                unknown = false
                Haptics.success()
                onDeleted("«" + fallbackName + "»: организации больше нет — удаление прошло (ответ сервера не дошёл).")
                dismiss()
                Task { await Notifier.shared.refresh(force: true) }
                return
            }
            if APIError.isCancellation(error) { return }
            checkNote = "Проверить не удалось: " + APIError.describe(error) + "\nУдаление могло пройти — проверьте ещё раз."
        }
    }

    private var whatSection: some View {
        Section {
            if rows.isEmpty {
                Text("Организация пустая: товаров, заказов и файлов нет.")
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(rows) { row in
                    KVRow(row.title, Fmt.number(row.count))
                }
            }
        } header: {
            Text("Будет удалено безвозвратно")
        }
    }

    private var historySection: some View {
        Section {
            InfoBanner(historyText, systemImage: "exclamationmark.triangle.fill", color: Brand.red)
        }
    }

    private var historyText: String {
        var t = "У организации есть история заказов. Вместе с заказами исчезнут и списания комиссий по ним"
        if (counts["commission_total"].decimal ?? 0) > 0 {
            t += " (площадка получила с них " + Fmt.money(counts["commission_total"]) + ")"
        }
        t += ", поэтому выручка и GMV за прошлые периоды в отчётах изменятся. Если нужно просто убрать организацию с витрины — поставьте ей статус «Заблокирована» (Изменить карточку → Статус): она пропадёт у клиентов, а данные останутся."
        return t
    }

    private var confirmSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("Наберите название организации: «" + name + "»")
                TextField(name, text: $typedName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if has2FA {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle("Код двухфакторной аутентификации")
                    TextField("000000", text: $secret)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    FieldTitle("Ваш пароль администратора")
                    SecureField("пароль", text: $secret)
                        .textContentType(.password)
                }
            }
        } header: {
            Text("Подтверждение")
        }
    }

    private func submit() {
        guard canDelete else { return }
        busy = true
        error = nil
        Haptics.warning()
        var payload: [String: Any?] = ["confirm_name": typedName]
        if has2FA { payload["code"] = secret } else { payload["password"] = secret }
        let sendBody = payload
        let path = "/api/admin/shops/" + String(shopId) + "/delete"
        let done = onDeleted
        let fallbackName = name
        // До 10 минут ожидания: экран не гаснет, иначе iOS усыпит приложение и запрос оборвётся.
        UIApplication.shared.isIdleTimerDisabled = true
        sentAt = Date()
        Task { @MainActor in
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let res = try await API.shared.post(path, body: sendBody, timeout: ShopDeleteSheet.deleteTimeout)
                Haptics.success()
                busy = false
                let deletedName = res["name"].nonEmptyString ?? fallbackName
                // Короткими частями — длинная цепочка `+` с перегруженным Fmt.number тяжела для проверки типов.
                let tables: String = Fmt.number(res["tables"])
                let files: String = Fmt.number(res["files"])
                let head: String = "«" + deletedName + "»: "
                let text: String = head + tables + " таблиц, " + files + " файлов."
                done(text)
                dismiss()
                Task { await Notifier.shared.refresh(force: true) }
            } catch {
                busy = false
                let e = API.mapTransport(error)
                if MoneyOp.isUnknown(e) {
                    // Исход неизвестен: удаление могло пройти — выясняем по карточке.
                    Haptics.error()
                    unknown = true
                    checkNote = nil
                    await checkDeleted()
                    return
                }
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                    // Неверный пароль/код — очищаем поле, как на сайте.
                    let need = (error as? APIError)?.details["need"].string ?? ""
                    if need == "password" || need == "2fa" { secret = "" }
                }
            }
        }
    }
}

/// Строка предпросмотра удаления: что и сколько исчезнет.
struct ShopDeleteCount: Identifiable {
    let title: String
    let count: Int
    var id: String { title }
}
