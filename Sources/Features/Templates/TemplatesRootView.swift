import SwiftUI

/// Раздел «Шаблоны» (шаблоны уведомлений): список и правка заголовка, текста,
/// каналов (push, telegram, sms, email) и выключателя шаблона.
///
/// Сервер: GET /api/admin/templates (id, type, title, body, channels_json, is_active),
/// PUT /api/admin/templates/{id} {title, body, channels, is_active} → {updated, template}.
/// Создания и удаления шаблонов на сервере нет (как и на сайте).
/// `openId` — id шаблона: после загрузки списка сразу открывается его редактор.
struct TemplatesRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/templates", searchParam: nil)
    @State private var deepLinkDone = false
    @State private var deepLinkTemplate: JSON?

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Шаблоны", model: model, searchPrompt: nil, emptyText: "Шаблонов нет",
                        row: { tpl in TemplatesRow(template: tpl) },
                        destination: { tpl in editor(tpl) })
            .onChange(of: model.state) { _ in
                openDeepLinkIfReady()
            }
            .navigationDestination(isPresented: deepLinkShown) {
                if let t = deepLinkTemplate {
                    editor(t)
                }
            }
    }

    private var deepLinkShown: Binding<Bool> {
        Binding(get: { deepLinkTemplate != nil }, set: { if !$0 { deepLinkTemplate = nil } })
    }

    private func editor(_ tpl: JSON) -> some View {
        TemplatesEditorView(template: tpl) { saved in
            model.replace(saved)
        }
    }

    private func openDeepLinkIfReady() {
        guard let id = openId, !deepLinkDone, model.state == .loaded else { return }
        deepLinkDone = true
        deepLinkTemplate = model.items.first(where: { $0.id == id })
    }
}

/// Каналы и переменные шаблонов.
enum TemplatesInfo {
    /// Каналы в порядке сайта.
    static let all: [PickerOption] = [
        PickerOption(value: "push", label: "Push"),
        PickerOption(value: "telegram", label: "Telegram"),
        PickerOption(value: "sms", label: "SMS"),
        PickerOption(value: "email", label: "Email"),
    ]

    static func channelLabel(_ code: String) -> String {
        all.first(where: { $0.value == code })?.label ?? code
    }

    /// channels_json приходит строкой JSON (колонка json) или массивом.
    /// Пустое поле сервер понимает как ["push"] (Notify::channelsForRow).
    static func channels(of tpl: JSON) -> [String] {
        let raw = tpl["channels_json"]
        if raw.isArray { return strings(raw.array) }
        guard let s = raw.string else { return ["push"] }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return ["push"] }
        guard let d = t.data(using: .utf8), let parsed = JSON.parse(d), parsed.isArray else { return ["push"] }
        return strings(parsed.array)
    }

    private static func strings(_ arr: [JSON]) -> [String] {
        var out: [String] = []
        for item in arr {
            if let s = item.nonEmptyString { out.append(s) }
        }
        return out
    }

    /// Строка шаблона после сохранения (если сервер не вернул template).
    static func updated(_ tpl: JSON, title: String, body: String, channels: [String], active: Bool) -> JSON {
        var obj = tpl.object
        obj["title"] = .string(title)
        obj["body"] = .string(body)
        obj["channels_json"] = .array(channels.map { JSON.string($0) })
        obj["is_active"] = .number(active ? 1 : 0)
        return .object(obj)
    }

    /// Переменные вида {order} в тексте — сервер подставляет их при отправке.
    static func variables(in texts: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let pattern = "\\{(\\w+)\\}"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        for text in texts {
            let ns = text as NSString
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > 1 {
                let name = ns.substring(with: m.range(at: 1))
                if !seen.contains(name) {
                    seen.insert(name)
                    out.append(name)
                }
            }
        }
        return out
    }
}

/// Строка шаблона: тип, заголовок, начало текста, каналы, статус.
private struct TemplatesRow: View {
    let template: JSON

    private var active: Bool { template["is_active"].bool ?? true }

    private var channelsText: String {
        let list = TemplatesInfo.channels(of: template)
        if list.isEmpty { return "Каналы: нет" }
        var labels: [String] = []
        for c in list { labels.append(TemplatesInfo.channelLabel(c)) }
        return labels.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(template["type"].stringValue)
                    .font(.caption.monospaced())
                    .foregroundColor(Brand.muted)
                Spacer()
                if !active {
                    StatusBadge("Выключен", color: Brand.red)
                }
            }
            Text(template["title"].nonEmptyString ?? "Без заголовка")
                .font(.body.weight(.medium))
                .foregroundColor(active ? Brand.text : Brand.muted)
                .lineLimit(2)
            if let b = template["body"].nonEmptyString {
                Text(b)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(2)
            }
            Text(channelsText)
                .font(.caption2)
                .foregroundColor(Brand.accent)
        }
        .padding(.vertical, 2)
    }
}

/// Редактор шаблона уведомления.
struct TemplatesEditorView: View {
    let template: JSON
    let onSaved: (JSON) -> Void

    @State private var title: String
    @State private var bodyText: String
    @State private var channels: Set<String>
    @State private var active: Bool
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    /// Максимум заголовка: колонка notifications.title (сервер обрезает до 190).
    private let titleLimit = 190

    init(template: JSON, onSaved: @escaping (JSON) -> Void) {
        self.template = template
        self.onSaved = onSaved
        _title = State(initialValue: template["title"].stringValue)
        _bodyText = State(initialValue: template["body"].stringValue)
        _channels = State(initialValue: Set(TemplatesInfo.channels(of: template)))
        _active = State(initialValue: template["is_active"].bool ?? true)
    }

    private var variables: [String] {
        let original = [template["title"].stringValue, template["body"].stringValue]
        return TemplatesInfo.variables(in: original + [title, bodyText])
    }

    var body: some View {
        Form {
            Section("Тип") {
                Text(template["type"].stringValue)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            titleSection
            Section("Текст") {
                TextEditor(text: $bodyText)
                    .frame(minHeight: 140)
            }
            variablesSection
            channelsSection
            Section {
                FormToggle("Шаблон включён", isOn: $active,
                           subtitle: "Выключенный шаблон не шлёт ни пуш, ни строку в ленте уведомлений")
            }
            if let e = error {
                Section { ErrorBanner(message: e) }
            }
            Section { JSONInspectorView(template) }
        }
        .navigationTitle("Шаблон")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else {
                    Button("Сохранить") { save() }
                }
            }
        }
        .alert(notice ?? "", isPresented: noticeShown) {
            Button("OK", role: .cancel) {}
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private var titleSection: some View {
        let count = title.count
        let over = count > titleLimit
        let tail: String = over ? " — длиннее сервер обрежет" : ""
        let counter: String = String(count) + " / " + String(titleLimit) + tail
        return Section {
            TextField("Заголовок", text: $title, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Заголовок")
        } footer: {
            Text(counter)
                .foregroundColor(over ? Brand.red : Brand.muted)
        }
    }

    @ViewBuilder
    private var variablesSection: some View {
        let vars = variables
        if !vars.isEmpty {
            Section {
                Text(vars.map { "{" + $0 + "}" }.joined(separator: "  "))
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Переменные")
            } footer: {
                Text("Подставляются при отправке. Используйте те же, что уже есть в шаблоне: неизвестная переменная останется в тексте как есть.")
            }
        }
    }

    private var channelsSection: some View {
        Section {
            ForEach(TemplatesInfo.all) { opt in
                Toggle(opt.label, isOn: channelBinding(opt.value))
            }
        } header: {
            Text("Каналы")
        } footer: {
            if channels.isEmpty {
                Text("Ни один канал не выбран — уведомление не уйдёт ни по одному каналу.")
                    .foregroundColor(Brand.red)
            }
        }
    }

    private func channelBinding(_ code: String) -> Binding<Bool> {
        Binding(get: { channels.contains(code) }, set: { on in
            if on { channels.insert(code) } else { channels.remove(code) }
        })
    }

    private func save() {
        guard !busy, let id = template.id else { return }
        var list: [String] = []
        for opt in TemplatesInfo.all where channels.contains(opt.value) {
            list.append(opt.value)
        }
        let chosen = list
        let sentTitle = title
        let sentBody = bodyText
        let sentActive = active
        let payload: [String: Any?] = [
            "title": sentTitle,
            "body": bodyText,
            "channels": chosen,
            "is_active": active ? 1 : 0,
        ]
        let original = template
        let done = onSaved
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let res = try await API.shared.put("/api/admin/templates/" + String(id), body: payload)
                let saved = res["template"]
                Haptics.success()
                busy = false
                if saved.isObject {
                    done(saved)
                    let serverTitle = saved["title"].stringValue
                    if serverTitle != sentTitle {
                        title = serverTitle
                        notice = "Сохранено, заголовок обрезан до 190 символов"
                    } else {
                        notice = "Сохранено"
                    }
                } else {
                    done(TemplatesInfo.updated(original, title: sentTitle, body: sentBody,
                                               channels: chosen, active: sentActive))
                    notice = "Сохранено"
                }
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
        }
    }
}
