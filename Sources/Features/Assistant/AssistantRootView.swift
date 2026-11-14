import SwiftUI

/// Раздел «Помощник (ИИ)» — только чтение и проверка связи (как /admin/assistant.php на сайте).
///
///  * GET  /api/admin/assistant/stats — включён ли, ключ, поставщик, регион, модель, лимиты
///    `limits:[человек, гость, площадка]` (0 — без ограничения), `periods.today|week|month`;
///  * GET  /api/admin/ai/overview — поставщик, регионы, модели, `usage.today|month[]`
///    (feature, calls, fails, tokens_in, tokens_out, cost_rub — null, если цена не задана), `usage.note`;
///  * POST /api/admin/ai/test {purpose:"support"} → {ok, ms, model, in, out, text | error}
///    (текст сервера показывается как есть);
///  * переписки — AssistantChatsView (/assistant/chats, /assistant/chats/{id}).
/// Настройки поставщика и ключей — раздел «Настройки» (группы «ИИ: …»). Ключи API сервер не отдаёт.
///
/// `openId` — id переписки: она открывается сразу.
struct AssistantRootView: View {
    let openId: Int?

    @StateObject private var stats = ObjectLoader(path: "/api/admin/assistant/stats")
    @StateObject private var overview = ObjectLoader(path: "/api/admin/ai/overview")
    @State private var period = "week"
    @State private var testResult: JSON?
    @State private var deepLinkShown: Bool

    init(openId: Int? = nil) {
        self.openId = openId
        _deepLinkShown = State(initialValue: openId != nil)
    }

    private var s: JSON { stats.data }
    private var o: JSON { overview.data }

    var body: some View {
        AsyncContent(state: stats.state, retry: { await reloadAll() }) {
            list
        }
        .navigationTitle("Помощник (ИИ)")
        .task { await stats.loadIfNeeded() }
        .task { await overview.loadIfNeeded() }
        .navigationDestination(isPresented: $deepLinkShown) {
            AssistantChatView(id: openId ?? 0)
        }
    }

    private func reloadAll() async {
        await stats.load()
        await overview.load()
    }

    private var list: some View {
        List {
            if let e = stats.lastRefreshError {
                Section {
                    ErrorBanner(message: e, retry: { Task { await reloadAll() } })
                }
            }
            stateSection
            providerSection
            testSection
            usageSection(title: "Расход за сегодня", rows: o["usage"]["today"].array)
            usageSection(title: "Расход за 30 дней", rows: o["usage"]["month"].array)
            periodSection
            Section {
                NavigationLink {
                    AssistantChatsView()
                } label: {
                    Label("Переписки с помощником", systemImage: "bubble.left.and.bubble.right")
                }
            } footer: {
                Text("Что спрашивают покупатели, организации и гости, как помощник отвечает и что оценили.")
            }
        }
        .refreshable { await reloadAll() }
    }

    // MARK: - Состояние

    private var stateSection: some View {
        Section("Состояние") {
            HStack {
                Text("Помощник")
                    .foregroundColor(Brand.muted)
                Spacer()
                if s["enabled"].boolValue {
                    StatusBadge("Включён", color: Brand.green)
                } else {
                    StatusBadge("Выключен", color: Brand.red)
                }
            }
            .font(.subheadline)
            if !s["has_key"].boolValue {
                InfoBanner("Нет ключа API — задайте его в «Настройки» → «ИИ».", systemImage: "exclamationmark.triangle", color: Brand.amber)
            }
            KVRow("Поставщик", s["provider_label"].string)
            KVRow("Где обрабатываются данные", AssistantFmt.region(s["region"].string))
            KVRow("Модель", s["model"].string)
            KVRow("Лимиты вопросов в сутки", limitsText)
        }
    }

    private var limitsText: String {
        let l = s["limits"].array
        guard l.count >= 3 else { return "—" }
        func part(_ j: JSON) -> String {
            let n = j.intValue
            return n > 0 ? Fmt.number(n) : "без ограничения"
        }
        return "человек: " + part(l[0]) + ", гость: " + part(l[1]) + ", площадка: " + part(l[2])
    }

    // MARK: - Поставщик ИИ

    @ViewBuilder
    private var providerSection: some View {
        switch overview.state {
        case .loaded:
            Section("Поставщик ИИ") {
                providerRows
            }
        case .failed(let msg):
            Section("Поставщик ИИ") {
                ErrorBanner(message: msg, retry: { Task { await overview.load() } })
            }
        default:
            Section("Поставщик ИИ") {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    @ViewBuilder
    private var providerRows: some View {
        HStack {
            Text(o["provider_label"].stringValue)
                .font(.headline)
            Spacer()
            if o["configured"].boolValue {
                StatusBadge("ключ задан", color: Brand.green)
            } else {
                StatusBadge("ключ не задан", color: Brand.red)
            }
        }
        KVRow("Помощник", AssistantFmt.region(o["region"]["support"].string))
        KVRow("Описания и модерация", AssistantFmt.region(o["region"]["desc"].string))
        KVRow("Фото", o["vision"].boolValue ? "передаются" : "нет, описание по данным товара")
        KVRow("Модель помощника", o["models"]["support"].string)
        KVRow("Модель описаний и модерации", o["models"]["desc"].string)
        if let cert = o["cert"]["text"].nonEmptyString {
            Text(cert)
                .font(.footnote)
                .foregroundColor(o["cert"]["warn"].boolValue ? Brand.red : Brand.muted)
        }
    }

    // MARK: - Проверка связи

    private var testSection: some View {
        Section {
            ActionButton("Проверить связь", systemImage: "bolt.horizontal", style: .bordered, fullWidth: true) {
                testResult = nil
                let res = try await API.shared.post("/api/admin/ai/test", body: ["purpose": "support"], timeout: 60)
                testResult = res
            }
            if let t = testResult {
                testResultView(t)
            }
        } footer: {
            Text("Короткий тестовый вопрос поставщику ИИ; результат — текст ответа сервера.")
        }
    }

    @ViewBuilder
    private func testResultView(_ t: JSON) -> some View {
        let secs = AssistantFmt.seconds(t["ms"].double)
        let tokensIn = Fmt.number(t["in"].intValue)
        let tokensOut = Fmt.number(t["out"].intValue)
        let tokens = "токены " + tokensIn + " / " + tokensOut
        let modelText = "модель " + t["model"].stringValue
        if t["ok"].boolValue {
            VStack(alignment: .leading, spacing: 6) {
                Text("Связь есть")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.green)
                Text(AssistantFmt.joined(["за " + secs, modelText, tokens]))
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                Text(t["text"].stringValue)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ошибка: " + t["error"].stringValue)
                    .font(.subheadline)
                    .foregroundColor(Brand.red)
                    .textSelection(.enabled)
                Text(AssistantFmt.joined([secs, t["model"].stringValue]))
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
        }
    }

    // MARK: - Расход

    @ViewBuilder
    private func usageSection(title: String, rows: [JSON]) -> some View {
        if overview.state == .loaded {
            Section {
                if rows.isEmpty {
                    Text("Пока нет запросов.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        usageRow(row)
                    }
                }
            } header: {
                Text(title)
            } footer: {
                if title.hasSuffix("30 дней") { Text(usageNote) }
            }
        }
    }

    private var usageNote: String {
        let u = o["usage"]
        var parts: [String] = []
        if let n = u["note"].nonEmptyString { parts.append(n) }
        if let r = u["usd_rub"].nonEmptyString { parts.append("Курс для долларовых цен: " + r + " ₽.") }
        parts.append("Накладные по фото в этот учёт не входят.")
        return parts.joined(separator: " ")
    }

    private func usageRow(_ x: JSON) -> some View {
        let cost = x["cost_rub"]
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(AssistantFmt.feature(x["feature"].string))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(cost.isNull ? "цена не задана" : "≈ " + Fmt.money(cost))
                    .font(.subheadline)
                    .foregroundColor(cost.isNull ? Brand.muted : Brand.text)
            }
            Text("Запросов: " + Fmt.number(x["calls"].intValue) + " · ошибок: " + Fmt.number(x["fails"].intValue))
                .font(.footnote)
                .foregroundColor(Brand.muted)
            Text("Токены вход / выход: " + Fmt.number(x["tokens_in"].intValue) + " / " + Fmt.number(x["tokens_out"].intValue))
                .font(.footnote)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Статистика

    private var periodSection: some View {
        let cur = s["periods"][period]
        let likes = cur["likes"].intValue
        let dislikes = cur["dislikes"].intValue
        return Section {
            Picker("Период", selection: $period) {
                Text("Сегодня").tag("today")
                Text("7 дней").tag("week")
                Text("30 дней").tag("month")
            }
            .pickerStyle(.segmented)
            KVRow("Разговоров", Fmt.number(cur["chats"].intValue))
            KVRow("Вопросов", Fmt.number(cur["questions"].intValue))
            KVRow("Помогло / не помогло", Fmt.number(likes) + " / " + Fmt.number(dislikes))
            KVRow("Довольны", AssistantFmt.satisfaction(likes: likes, dislikes: dislikes))
            KVRow("Передано человеку", Fmt.number(cur["handoffs"].intValue))
            KVRow("Вне темы (отказы)", Fmt.number(cur["off_topic"].intValue))
            KVRow("Среднее время ответа", cur["avg_ms"].intValue > 0 ? AssistantFmt.seconds(cur["avg_ms"].double) : nil)
            KVRow("Токены: вход / ответ", Fmt.number(cur["tokens_in"].intValue) + " / " + Fmt.number(cur["tokens_out"].intValue))
        } header: {
            Text("Статистика помощника")
        }
    }
}

/// Общие подписи и форматы раздела «Помощник (ИИ)».
enum AssistantFmt {
    /// Кто писал помощнику.
    static func audience(_ code: String?) -> String {
        switch code ?? "" {
        case "client": return "Покупатель"
        case "seller": return "Организация"
        case "guest": return "Гость"
        default: return code ?? "—"
        }
    }

    /// Функция в таблице расхода.
    static func feature(_ code: String?) -> String {
        switch code ?? "" {
        case "assistant": return "Помощник"
        case "desc": return "Описания товаров"
        case "moderation": return "Модерация отзывов"
        case "test": return "Проверки подключения"
        default: return code ?? "—"
        }
    }

    /// Где обрабатываются данные: "ru" — в России, иначе за рубежом.
    static func region(_ code: String?) -> String? {
        guard let c = code, !c.isEmpty else { return nil }
        return c == "ru" ? "данные в России" : "данные за рубежом (персональные данные скрываются)"
    }

    /// Миллисекунды → «1,5 с». nil → «—».
    static func seconds(_ ms: Double?) -> String {
        guard let ms = ms else { return "—" }
        let text = String(format: "%.1f", ms / 1000).replacingOccurrences(of: ".", with: ",")
        return text + " с"
    }

    /// Процент «Довольны»: likes / (likes + dislikes).
    static func satisfaction(likes: Int, dislikes: Int) -> String {
        let all = likes + dislikes
        guard all > 0 else { return "—" }
        return String((likes * 100 + all / 2) / all) + "%"
    }

    /// Части через « · ».
    static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
