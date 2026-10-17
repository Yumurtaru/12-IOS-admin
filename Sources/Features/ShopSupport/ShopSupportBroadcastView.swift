import SwiftUI

/// «Рассылка организациям»: одно сообщение в чаты многих организаций
/// (с пометкой «Рассылка», push владельцам).
///
/// Порядок, как требует сервер (защита от случайного «всем»):
///   1. POST /api/admin/shop-support/broadcast/preview {all, shop_ids} → {count, max, over};
///   2. подтверждение «Отправить N организациям?»;
///   3. POST /api/admin/shop-support/broadcast {body, all, shop_ids, confirm_count: N} →
///      {sent, skipped, failed, queued, notified, broadcast}.
/// 409 confirm_required — адресатов стало другое число: заново спрашиваем
/// предпросмотр и показываем новое число. Только текст, без файла; не чаще 5 в минуту.
struct ShopSupportBroadcastView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var toAll = false
    @State private var selected: [Int: String] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var asking = false
    @State private var askCount = 0
    @State private var changedNote: String?
    @State private var resultText: String?

    /// Предел длины (ShopSupport::MAX_BODY).
    private static let maxBody = 4000

    var body: some View {
        NavigationStack {
            Form {
                textSection
                targetSection
                sendSection
            }
            .navigationTitle("Рассылка организациям")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .disabled(busy)
                }
            }
            .alert(confirmTitle, isPresented: $asking) {
                Button("Отправить") { send() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
            .alert("Рассылка отправлена", isPresented: resultShown) {
                Button("OK") { dismiss() }
            } message: {
                Text(resultText ?? "")
            }
            .interactiveDismissDisabled(busy)
        }
    }

    // MARK: - Разделы формы

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var textSection: some View {
        Section {
            TextEditor(text: $text)
                .frame(minHeight: 140)
        } header: {
            Text("Текст")
        } footer: {
            Text(String(text.count) + " / " + String(ShopSupportBroadcastView.maxBody)
                 + ". Сообщение появится в разделе «Техподдержка» панели каждой организации с пометкой «Рассылка».")
                .foregroundColor(text.count > ShopSupportBroadcastView.maxBody ? Brand.red : Brand.muted)
        }
    }

    private var targetSection: some View {
        Section {
            Picker("Кому", selection: $toAll) {
                Text("Выбранным").tag(false)
                Text("Всем организациям").tag(true)
            }
            .pickerStyle(.segmented)
            if !toAll {
                NavigationLink(destination: ShopSupportBroadcastPickView(selected: $selected)) {
                    HStack {
                        Text("Выбрать организации")
                        Spacer()
                        Text(String(selected.count)).foregroundColor(Brand.muted)
                    }
                }
                ForEach(pickedList) { p in
                    Text(p.name).lineLimit(1)
                }
                .onDelete(perform: removePicked)
            }
        } header: {
            Text("Кому")
        } footer: {
            Text(toAll
                 ? "Всем организациям с доступом в панель продавца. Перед отправкой покажем точное число адресатов."
                 : "Отметьте организации в поиске. Убрать из списка — смахните влево.")
        }
    }

    private var sendSection: some View {
        Section {
            Button {
                check()
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView() } else { Text("Проверить и отправить").bold() }
                    Spacer()
                }
            }
            .disabled(!canCheck)
            if let e = error {
                Text(e)
                    .font(.footnote)
                    .foregroundColor(Brand.red)
            }
        }
    }

    private var canCheck: Bool {
        !busy && !trimmed.isEmpty && text.count <= ShopSupportBroadcastView.maxBody && (toAll || !selected.isEmpty)
    }

    private var pickedList: [ShopSupportPicked] {
        let ids = selected.keys.sorted()
        return ids.map { ShopSupportPicked(id: $0, name: selected[$0] ?? ("#" + String($0))) }
    }

    private func removePicked(_ offsets: IndexSet) {
        let list = pickedList
        for i in offsets where i < list.count {
            selected[list[i].id] = nil
        }
    }

    private var targetIds: [Int] { selected.keys.sorted() }

    // MARK: - Подтверждение и результат

    private var confirmTitle: String {
        "Отправить " + Fmt.plural(askCount, "организации", "организациям", "организациям") + "?"
    }

    private var confirmMessage: String {
        let preview = String(trimmed.prefix(200))
        let tail = trimmed.count > 200 ? "…" : ""
        let note = changedNote.map { $0 + "\n\n" } ?? ""
        return note + "«" + preview + tail + "»"
    }

    private var resultShown: Binding<Bool> {
        Binding(get: { resultText != nil }, set: { if !$0 { resultText = nil } })
    }

    // MARK: - Действия

    /// Шаг 1: предпросмотр числа адресатов → подтверждение.
    private func check() {
        guard canCheck else { return }
        busy = true
        error = nil
        let all = toAll
        let ids = targetIds
        Task { @MainActor in
            do {
                let p = try await ShopSupportBroadcastView.preview(all: all, ids: ids)
                busy = false
                ask(p, previous: nil)
            } catch {
                busy = false
                if !APIError.isCancellation(error) { self.error = APIError.describe(error) }
            }
        }
    }

    /// Показать подтверждение (или объяснить, почему отправить нельзя).
    private func ask(_ p: ShopSupportBroadcastPreview, previous: Int?) {
        if p.over {
            error = "Слишком много адресатов: " + String(p.count) + ". За один раз — не больше " + String(p.max) + "."
            return
        }
        if p.count <= 0 {
            error = toAll ? "Нет организаций с доступом в панель." : "Выбранные организации не найдены."
            return
        }
        if let old = previous {
            changedNote = "Число адресатов изменилось: было " + String(old) + ", стало " + String(p.count) + "."
        } else {
            changedNote = nil
        }
        askCount = p.count
        asking = true
    }

    /// Шаг 2: отправка с числом, которое человек подтвердил.
    private func send() {
        let n = askCount
        let all = toAll
        let ids = targetIds
        let body = trimmed
        guard n > 0, !body.isEmpty else { return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let payload: [String: Any?] = ["body": body, "all": all, "shop_ids": ids, "confirm_count": n]
                let d = try await API.shared.post("/api/admin/shop-support/broadcast", body: payload)
                busy = false
                Haptics.success()
                resultText = ShopSupportBroadcastView.describe(d)
            } catch {
                if APIError.isCancellation(error) {
                    busy = false
                    return
                }
                if let e = error as? APIError, e.status == 409 {
                    await recheck(e, sentCount: n, all: all, ids: ids)
                    return
                }
                busy = false
                Haptics.error()
                self.error = APIError.describe(error)
            }
        }
    }

    /// 409: либо адресатов стало другое число (confirm_required — спрашиваем заново
    /// с новым числом), либо такая же рассылка ещё идёт (показываем текст сервера).
    private func recheck(_ e: APIError, sentCount: Int, all: Bool, ids: [Int]) async {
        do {
            let p = try await ShopSupportBroadcastView.preview(all: all, ids: ids)
            busy = false
            if p.count != sentCount {
                ask(p, previous: sentCount)
            } else {
                error = e.message
            }
        } catch {
            busy = false
            self.error = e.message
        }
    }

    private static func preview(all: Bool, ids: [Int]) async throws -> ShopSupportBroadcastPreview {
        let d = try await API.shared.post("/api/admin/shop-support/broadcast/preview",
                                          body: ["all": all, "shop_ids": ids])
        return ShopSupportBroadcastPreview(count: d["count"].intValue, max: d["max"].intValue, over: d["over"].boolValue)
    }

    /// Итог рассылки по-человечески.
    private static func describe(_ d: JSON) -> String {
        var parts: [String] = ["Доставлено в чаты: " + String(d["sent"].intValue) + "."]
        let skipped = d["skipped"].intValue
        if skipped > 0 { parts.append("Уже получили раньше: " + String(skipped) + ".") }
        let failed = d["failed"].intValue
        if failed > 0 { parts.append("Не удалось: " + String(failed) + ".") }
        let notified = d["notified"].intValue
        if notified > 0 { parts.append("Уведомлено: " + String(notified) + ".") }
        if d["queued"].intValue > 0 { parts.append("Остальные уведомления уйдут в фоне в ближайшие минуты.") }
        return parts.joined(separator: "\n")
    }
}

/// Ответ предпросмотра рассылки.
struct ShopSupportBroadcastPreview {
    let count: Int
    let max: Int
    let over: Bool
}

/// Выбранная для рассылки организация.
struct ShopSupportPicked: Identifiable {
    let id: Int
    let name: String
}

/// Выбор адресатов рассылки: поиск, тап — отметить / снять.
struct ShopSupportBroadcastPickView: View {
    @Binding var selected: [Int: String]
    @StateObject private var search = ShopSupportShopSearch()

    init(selected: Binding<[Int: String]>) {
        self._selected = selected
    }

    var body: some View {
        ShopSupportShopSearchList(search: search, selectedIds: Set(selected.keys), onTap: toggle)
            .navigationTitle("Выбрано: " + String(selected.count))
            .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ shop: JSON) {
        guard let id = shop["id"].int, id > 0 else { return }
        Haptics.tap()
        if selected[id] != nil {
            selected[id] = nil
        } else {
            selected[id] = shop["name"].nonEmptyString ?? ("#" + String(id))
        }
    }
}
