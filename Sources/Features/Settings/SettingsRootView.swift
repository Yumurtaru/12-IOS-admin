import SwiftUI

/// Раздел «Настройки» сайта — те же поля и группы, что admin.js settings().
///
/// GET  /api/admin/settings → {ключ: значение, …, _secret_keys:[…], _secret_set:{ключ: bool}}
///      секреты (ЮKassa, Dadata, Яндекс.Карты, Telegram, iiko) приходят маской «••••••••cdef».
/// POST /api/admin/settings {ключ: значение, …} → {saved, changed:[ключи]}
///      422 → errors {ключ: причина}; сохранение атомарное (ошибка в одном поле — не сохраняется ничего).
///      Секрет: маска или пусто — «не трогать», «__CLEAR__» — стереть.
///      Реквизиты, ключи ЮKassa и сервисов, ссылки на приложения, установщик и «обязательное»
///      обновление кассы, автоодобрение (этап L, dbConfirm) — только с `password` (или `code`
///      при 2FA): без него 403 `errors.need = "password" | "2fa"` (неверный — то же; "setup" —
///      подтвердить нечем). Лист подтверждения спрашивает пароль/код и повторяет с ним.
///
/// Отправляем ТОЛЬКО изменённые ключи (сервер пропускает отсутствующие) — после
/// подтверждения со списком «было → стало».
struct SettingsRootView: View {
    let openId: Int?

    @StateObject private var loader = ObjectLoader(path: "/api/admin/settings")
    /// Значения, как пришли с сервера (секреты — маской).
    @State private var original: [String: String] = [:]
    /// Текущие значения полей (для секретов — НОВОЕ значение, пусто = не менять).
    @State private var values: [String: String] = [:]
    /// Секреты, которые будут стёрты при сохранении.
    @State private var cleared: Set<String> = []
    /// Ошибки сервера по полям (422).
    @State private var fieldErrors: [String: String] = [:]
    @State private var loadedOnce = false
    @State private var showReview = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var data: JSON { loader.data }

    private var secretKeys: Set<String> {
        Set(data["_secret_keys"].array.compactMap { $0.string })
    }

    var body: some View {
        AsyncContent(state: loader.state, emptyText: "Настроек нет", retry: { await reload() }) {
            form
        }
        .navigationTitle("Настройки")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { showReview = true }
                    .disabled(changes.isEmpty)
            }
        }
        .sheet(isPresented: $showReview) {
            SettingsReviewSheet(changes: changes, onSave: { extra in try await save(extra) })
        }
        .task {
            await loader.loadIfNeeded()
            fillIfNeeded()
        }
    }

    // MARK: - Форма

    private var form: some View {
        Form {
            if let e = loader.lastRefreshError {
                Section {
                    ErrorBanner(message: e, retry: { Task { await reload() } })
                }
            }
            if !fieldErrors.isEmpty {
                Section {
                    ErrorBanner(message: "Проверьте значения: " + Fmt.plural(fieldErrors.count, "поле", "поля", "полей")
                                + " с ошибкой. Пока хоть одно поле неверно, не сохраняется ничего.")
                }
            }
            if !changes.isEmpty {
                Section {
                    SettingsPendingBar(count: changes.count, onReview: { showReview = true }, onReset: resetEdits)
                }
            }
            ForEach(SettingsCatalog.groups) { group in
                Section {
                    ForEach(group.fields) { field in
                        fieldView(field)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let n = group.note { Text(n) }
                }
            }
            extrasSection
        }
        .refreshable { await reload() }
    }

    @ViewBuilder
    private func fieldView(_ field: SettingsField) -> some View {
        if secretKeys.contains(field.key) {
            SettingsSecretRow(field: field,
                              masked: original[field.key] ?? "",
                              isSet: data["_secret_set"][field.key].bool ?? !(original[field.key] ?? "").isEmpty,
                              newValue: binding(field.key),
                              cleared: clearedBinding(field.key),
                              error: fieldErrors[field.key])
        } else {
            SettingsValueRow(field: field, value: binding(field.key),
                             changed: isChanged(field.key), error: fieldErrors[field.key])
        }
    }

    /// Ключи, которые сервер отдаёт, а сайт не показывает — только просмотр.
    @ViewBuilder
    private var extrasSection: some View {
        let keys = extraKeys
        if !keys.isEmpty {
            Section {
                ForEach(keys, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsCatalog.extraLabels[key] ?? key)
                            .font(.subheadline)
                        Text(displayExtra(key))
                            .font(.footnote.monospaced())
                            .foregroundColor(Brand.muted)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Прочие (только просмотр)")
            } footer: {
                Text("Этих полей нет на странице настроек сайта, поэтому здесь их можно только посмотреть.")
            }
        }
    }

    private var extraKeys: [String] {
        let known = SettingsCatalog.knownKeys
        var out: [String] = []
        for k in original.keys.sorted() where !k.hasPrefix("_") && !known.contains(k) {
            out.append(k)
        }
        return out
    }

    private func displayExtra(_ key: String) -> String {
        let v = original[key] ?? ""
        return v.isEmpty ? "— пусто —" : v
    }

    // MARK: - Состояние полей

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { newValue in
            values[key] = newValue
            if fieldErrors[key] != nil { fieldErrors[key] = nil }
        })
    }

    private func clearedBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { cleared.contains(key) }, set: { on in
            if on { cleared.insert(key) } else { cleared.remove(key) }
        })
    }

    private func isChanged(_ key: String) -> Bool {
        (values[key] ?? "") != (original[key] ?? "")
    }

    /// Изменения: ключ → что отправить, плюс подписи «было → стало».
    private var changes: [SettingsChange] {
        var out: [SettingsChange] = []
        let secrets = secretKeys
        for group in SettingsCatalog.groups {
            for f in group.fields {
                if let c = change(for: f, secret: secrets.contains(f.key)) { out.append(c) }
            }
        }
        return out
    }

    private func change(for f: SettingsField, secret: Bool) -> SettingsChange? {
        let old = original[f.key] ?? ""
        let new = values[f.key] ?? ""
        if secret {
            if cleared.contains(f.key) {
                return SettingsChange(key: f.key, label: f.label, send: "__CLEAR__", oldText: old.isEmpty ? "не задан" : old, newText: "стереть ключ")
            }
            let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            return SettingsChange(key: f.key, label: f.label, send: t, oldText: old.isEmpty ? "не задан" : old, newText: "новый ключ …" + String(t.suffix(4)))
        }
        if new == old { return nil }
        return SettingsChange(key: f.key, label: f.label, send: new,
                              oldText: SettingsRootView.shown(old, field: f), newText: SettingsRootView.shown(new, field: f))
    }

    /// Значение для списка изменений: у выбора — подпись варианта.
    private static func shown(_ value: String, field: SettingsField) -> String {
        if case .choice(let options) = field.kind, let o = options.first(where: { $0.value == value }) {
            return o.label
        }
        return value.isEmpty ? "пусто" : value
    }

    private func fillIfNeeded() {
        guard !loadedOnce, loader.state == .loaded else { return }
        loadedOnce = true
        fill()
    }

    /// Разложить ответ сервера по полям (правки пользователя сбрасываются).
    private func fill() {
        var o: [String: String] = [:]
        for (k, v) in data.object where !k.hasPrefix("_") {
            o[k] = v.string ?? ""
        }
        original = o
        var edit: [String: String] = [:]
        let secrets = secretKeys
        for (k, v) in o {
            edit[k] = secrets.contains(k) ? "" : v
        }
        values = edit
        cleared = []
    }

    private func resetEdits() {
        fill()
        fieldErrors = [:]
    }

    private func reload() async {
        await loader.load()
        if loader.state == .loaded {
            fill()
            fieldErrors = [:]
        }
    }

    // MARK: - Сохранение

    /// POST только изменённых ключей → текст итога для листа. `extra` — подтверждение
    /// (`password` или `code`), если сервер его попросил.
    /// 422 — подсветить поля и пробросить ошибку в лист.
    private func save(_ extra: [String: Any?]) async throws -> String {
        let list = changes
        guard !list.isEmpty else { return "Изменений нет." }
        var body: [String: Any?] = [:]
        for c in list { body[c.key] = c.send }
        for (k, v) in extra { body[k] = v }
        do {
            let res = try await API.shared.post("/api/admin/settings", body: body)
            let changedKeys = res["changed"].array.compactMap { $0.string }
            await reload()
            return SettingsRootView.savedMessage(changedKeys)
        } catch let e as APIError {
            let errs = e.fieldErrors
            if !errs.isEmpty {
                fieldErrors = errs
                throw APIError.validation(SettingsRootView.validationText(errs), fields: [:])
            }
            throw e
        }
    }

    private static func savedMessage(_ keys: [String]) -> String {
        if keys.isEmpty { return "Значения совпали с сохранёнными — менять было нечего." }
        let names = keys.map { SettingsCatalog.label(for: $0) }
        return "Изменено: " + names.joined(separator: "; ")
    }

    private static func validationText(_ errs: [String: String]) -> String {
        var lines: [String] = ["Проверьте значения настроек:"]
        for k in errs.keys.sorted() {
            let reason = errs[k] ?? ""
            lines.append("• " + SettingsCatalog.label(for: k) + " — " + reason)
        }
        return lines.joined(separator: "\n")
    }
}

/// Одно изменение для подтверждения.
struct SettingsChange: Identifiable {
    let key: String
    let label: String
    /// Что уйдёт на сервер.
    let send: String
    let oldText: String
    let newText: String

    var id: String { key }

    init(key: String, label: String, send: String, oldText: String, newText: String) {
        self.key = key
        self.label = label
        self.send = send
        self.oldText = oldText
        self.newText = newText
    }
}

/// Плашка «Изменено N полей» с просмотром и отменой.
struct SettingsPendingBar: View {
    let count: Int
    let onReview: () -> Void
    let onReset: () -> Void

    init(count: Int, onReview: @escaping () -> Void, onReset: @escaping () -> Void) {
        self.count = count
        self.onReview = onReview
        self.onReset = onReset
    }

    var body: some View {
        HStack {
            Image(systemName: "pencil.circle.fill")
                .foregroundColor(Brand.amber)
            Text("Не сохранено: " + Fmt.plural(count, "изменение", "изменения", "изменений"))
                .font(.subheadline)
            Spacer()
            Button("Отменить", action: onReset)
                .buttonStyle(.borderless)
                .foregroundColor(Brand.red)
            Button("Сохранить", action: onReview)
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.semibold))
        }
    }
}

/// Обычное поле: текст/число/выбор, подсказка сайта, ошибка сервера.
struct SettingsValueRow: View {
    let field: SettingsField
    @Binding var value: String
    let changed: Bool
    let error: String?

    init(field: SettingsField, value: Binding<String>, changed: Bool, error: String?) {
        self.field = field
        self._value = value
        self.changed = changed
        self.error = error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            input
            if let h = field.hint {
                Text(h)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let e = error {
                Text(e)
                    .font(.caption)
                    .foregroundColor(Brand.red)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(changed ? Brand.amber.opacity(0.10) : nil)
    }

    @ViewBuilder
    private var input: some View {
        switch field.kind {
        case .choice(let options):
            Picker(field.label, selection: $value) {
                ForEach(SettingsValueRow.withCurrent(options, value: value)) { o in
                    Text(o.label).tag(o.value)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle(field.label)
                TextField("", text: $value)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(capitalization)
                    .autocorrectionDisabled(!isFreeText)
            }
        }
    }

    private var isFreeText: Bool {
        if case .text = field.kind { return true }
        return false
    }

    private var keyboard: UIKeyboardType {
        switch field.kind {
        case .decimal: return .decimalPad
        case .integer: return .numberPad
        case .signed: return .numbersAndPunctuation
        case .url: return .URL
        default: return .default
        }
    }

    private var capitalization: TextInputAutocapitalization {
        isFreeText ? .sentences : .never
    }

    /// Если в базе лежит значение, которого нет среди вариантов, — показать и его,
    /// иначе Picker остался бы без выбора, а значение молча потерялось бы.
    static func withCurrent(_ options: [PickerOption], value: String) -> [PickerOption] {
        if options.contains(where: { $0.value == value }) { return options }
        let label = value.isEmpty ? "— не задано —" : value + " (текущее)"
        return [PickerOption(value: value, label: label)] + options
    }
}

/// Поле секрета: маска текущего значения, ввод нового, «Стереть».
struct SettingsSecretRow: View {
    let field: SettingsField
    let masked: String
    let isSet: Bool
    @Binding var newValue: String
    @Binding var cleared: Bool
    let error: String?

    @State private var askClear = false

    init(field: SettingsField, masked: String, isSet: Bool, newValue: Binding<String>,
         cleared: Binding<Bool>, error: String?) {
        self.field = field
        self.masked = masked
        self.isSet = isSet
        self._newValue = newValue
        self._cleared = cleared
        self.error = error
    }

    private var currentText: String {
        if !isSet { return "Сейчас: не задан" }
        return "Сейчас: " + (masked.isEmpty ? "задан" : masked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldTitle(field.label)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(currentText)
                .font(.footnote.monospaced())
                .foregroundColor(Brand.text)
            if cleared {
                HStack {
                    Text("Будет стёрт при сохранении")
                        .font(.footnote)
                        .foregroundColor(Brand.red)
                    Spacer()
                    Button("Не стирать") { cleared = false }
                        .buttonStyle(.borderless)
                }
            } else {
                TextField("Новое значение (пусто — не менять)", text: $newValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                if isSet {
                    Button("Стереть ключ", role: .destructive) { askClear = true }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                }
            }
            if let h = field.hint {
                Text(h)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let e = error {
                Text(e)
                    .font(.caption)
                    .foregroundColor(Brand.red)
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog("Стереть «" + field.label + "»?", isPresented: $askClear, titleVisibility: .visible) {
            Button("Стереть при сохранении", role: .destructive) {
                newValue = ""
                cleared = true
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Без ключа соответствующая функция сайта перестанет работать.")
        }
    }
}

/// Подтверждение сохранения: список «было → стало». Если сервер попросил подтвердить
/// опасную правку (403 `errors.need` = "password" | "2fa"), лист показывает поле пароля
/// или кода и повторяет сохранение с ним.
struct SettingsReviewSheet: View {
    let changes: [SettingsChange]
    /// Сохранение; аргумент — подтверждение (`password` / `code`) или пусто.
    let onSave: ([String: Any?]) async throws -> String
    @Environment(\.dismiss) private var dismiss
    /// Итог сохранения (после успеха лист показывает его вместо списка).
    @State private var doneText: String?
    /// Что просит сервер: "password" или "2fa" (nil — ничего).
    @State private var need: String?
    @State private var secret = ""
    /// Текст сервера к запросу подтверждения (неверный пароль, код уже использован …).
    @State private var needText: String?

    init(changes: [SettingsChange], onSave: @escaping ([String: Any?]) async throws -> String) {
        self.changes = changes
        self.onSave = onSave
    }

    /// Сервер просит пароль или код — запомнить и не показывать ошибку алертом.
    private func askedConfirm(_ error: Error) -> Bool {
        guard let e = error as? APIError, e.status == 403,
              let n = e.details["need"].string, n == "password" || n == "2fa" else { return false }
        need = n
        secret = ""
        needText = e.message
        Haptics.warning()
        return true
    }

    private func attempt(_ extra: [String: Any?]) async throws {
        do {
            let text = try await onSave(extra)
            doneText = text
        } catch {
            if askedConfirm(error) { return }
            throw error
        }
    }

    private var title: String {
        "Сохранить " + Fmt.plural(changes.count, "изменение", "изменения", "изменений")
    }

    var body: some View {
        NavigationStack {
            Group {
                if let done = doneText {
                    SettingsSavedView(text: done, onClose: { dismiss() })
                } else {
                    reviewList
                }
            }
            .navigationTitle(doneText == nil ? "Проверьте изменения" : "Сохранено")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if doneText == nil {
                        Button("Отмена") { dismiss() }
                    }
                }
            }
        }
    }

    private var reviewList: some View {
        List {
            Section {
                ForEach(changes) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c.label)
                            .font(.subheadline.weight(.semibold))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(c.oldText)
                                .strikethrough()
                                .foregroundColor(Brand.muted)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundColor(Brand.muted)
                            Text(c.newText)
                                .foregroundColor(Brand.text)
                        }
                        .font(.footnote)
                        Text(c.key)
                            .font(.caption2.monospaced())
                            .foregroundColor(Brand.muted)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("Настройки действуют сразу для всей площадки. В журнал попадут названия изменённых настроек (без значений).")
            }
            if let n = need {
                confirmSection(n)
            } else {
                Section {
                    ActionButton(title, systemImage: "checkmark", style: .prominent, fullWidth: true) {
                        try await attempt([:])
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func confirmSection(_ n: String) -> some View {
        let useCode = n == "2fa"
        Section {
            if let t = needText {
                Text(t)
                    .font(.footnote)
                    .foregroundColor(Brand.amber)
            }
            if useCode {
                TextField("000000", text: $secret)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title3.monospacedDigit())
            } else {
                SecureField("Пароль", text: $secret)
                    .textContentType(.password)
            }
        } header: {
            Text(useCode ? "Код двухфакторной аутентификации" : "Ваш пароль администратора")
        } footer: {
            Text(useCode ? "Реквизиты, ключи и ссылки площадки сервер меняет только с кодом из приложения-аутентификатора. Один код — одно сохранение."
                         : "Реквизиты, ключи и ссылки площадки сервер меняет только после ввода пароля администратора.")
        }
        Section {
            ActionButton("Подтвердить и сохранить", systemImage: "lock.open", style: .prominent, fullWidth: true) {
                let v = secret.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty else { return }
                try await attempt(useCode ? ["code": v] : ["password": v])
            }
            .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .listRowBackground(Color.clear)
        }
    }
}

/// Итог сохранения внутри листа.
struct SettingsSavedView: View {
    let text: String
    let onClose: () -> Void

    init(text: String, onClose: @escaping () -> Void) {
        self.text = text
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(Brand.green)
            Text(text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Готово", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
