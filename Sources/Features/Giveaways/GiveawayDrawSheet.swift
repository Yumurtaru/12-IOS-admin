import SwiftUI

/// «Провести розыгрыш» (как форма «Новый розыгрыш» в admin-giveaways.js).
///
/// POST /api/admin/giveaways/draw {title, prize, winners_count, pickup_text?, city_id?,
/// exclude_staff?, draw_key} → {giveaway:{…}, winners:[…], repeated}.
///
/// Ключ повтора `draw_key` — ОДИН на это окно, создаётся при открытии (до отправки).
/// Сервер по нему не проводит второй розыгрыш, а отдаёт уже проведённый с repeated=true.
///  * Пока идёт запрос — окно не закрыть (ни свайпом, ни «Отменой»), кнопка недоступна.
///    Ждём ответа до 200 с: сервер синхронно шлёт push победителям (set_time_limit 180).
///  * Исход неизвестен (нет связи, 5xx, непонятный ответ) — форма замирает, кнопка
///    становится «Повторить»: уходит тот же ключ и то же тело. Свайпом окно не закрыть,
///    «Отмена» — только после подтверждения «Розыгрыш мог пройти…».
///  * Окончательный отказ (422 и т.п.) — розыгрыш не проведён, форму можно поправить.
///  * repeated=true — показывается как результат прошлого нажатия.
/// Число участников под выбранный город и галочку — GET …/participants (поле all),
/// как на сайте: перед розыгрышем видно, из скольких выбираем.
struct GiveawayDrawSheet: View {
    /// Розыгрыш проведён (или мог пройти) — обновить историю.
    let onDrawn: () -> Void
    /// «Скрыть номера» раздела.
    @ObservedObject var privacy: GiveawaysPrivacy

    @Environment(\.dismiss) private var dismiss

    @State private var prize = ""
    @State private var title = ""
    @State private var winnersText = "3"
    @State private var pickup = ""
    @State private var cityValue: String
    @State private var excludeStaff: Bool
    @State private var cities: [GiveawayParticipantsStats.City]
    @State private var noCity: Int

    /// Участников под выбранный отбор (nil — ещё считаем или не удалось).
    @State private var total: Int?
    @State private var counting = false
    @State private var countError: String?
    @State private var countGeneration = 0

    /// Ключ повтора этого окна.
    @State private var drawKey = GiveawaysFormat.newDrawKey()
    /// Тело запроса с неизвестным исходом: форма заморожена, «Повторить» шлёт его же.
    @State private var unsentBody: [String: JSON]?
    @State private var busy = false
    @State private var askConfirm = false
    /// «Отмена» при неизвестном исходе — спросить, точно ли закрыть без повтора.
    @State private var askCloseUnknown = false
    @State private var error: String?
    @State private var fieldErrors: [String: String] = [:]
    @State private var result: JSON?

    /// - Parameters:
    ///   - privacy: «Скрыть номера» раздела;
    ///   - cities: города с числом участников (из списка участников, может быть пусто);
    ///   - noCity: участников без города;
    ///   - cityId: город, выбранный в списке участников (nil — все);
    ///   - excludeStaff: галочка «без сотрудников» из списка участников;
    ///   - onDrawn: розыгрыш проведён (или мог пройти).
    init(privacy: GiveawaysPrivacy, cities: [GiveawayParticipantsStats.City], noCity: Int, cityId: Int?,
         excludeStaff: Bool, onDrawn: @escaping () -> Void) {
        self.onDrawn = onDrawn
        self.privacy = privacy
        _cities = State(initialValue: cities)
        _noCity = State(initialValue: noCity)
        _cityValue = State(initialValue: cityId.map { String($0) } ?? "")
        _excludeStaff = State(initialValue: excludeStaff)
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Форма заморожена: идёт запрос или исход прошлого нажатия неизвестен.
    private var locked: Bool { busy || unsentBody != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let r = result {
                    GiveawayDrawResultSections(data: r, privacy: privacy, onChanged: { resultChanged() })
                } else {
                    formSections
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(result == nil ? "Новый розыгрыш" : "Победители")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if result == nil {
                        Button("Отмена") { cancelTapped() }.disabled(busy)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil {
                        Button("Готово") { dismiss() }
                    } else if busy {
                        ProgressView()
                    }
                }
            }
            .confirmationDialog("Провести розыгрыш?", isPresented: $askConfirm, titleVisibility: .visible) {
                Button("Провести") { send(buildBody()) }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(confirmText)
            }
            .task { await loadCount() }
            .onChange(of: cityValue) { _ in Task { await loadCount() } }
            .onChange(of: excludeStaff) { _ in Task { await loadCount() } }
        }
        // Подтверждение «Отмены» при неизвестном исходе — на внешнем виде (у Form свой диалог).
        .confirmationDialog("Розыгрыш мог пройти — закрыть без повтора?", isPresented: $askCloseUnknown,
                            titleVisibility: .visible) {
            Button("Закрыть без повтора", role: .destructive) { dismiss() }
            Button("Остаться", role: .cancel) {}
        } message: {
            Text("Проверьте «Историю»: если розыгрыш прошёл, он там есть. Повтор отсюда второго розыгрыша не проведёт.")
        }
        // Пока идёт запрос или исход неизвестен, свайпом окно не закрыть: иначе исход
        // розыгрыша потеряется (при неизвестном — «Отмена» с подтверждением).
        .interactiveDismissDisabled(busy || unsentBody != nil)
    }

    private func cancelTapped() {
        guard !busy else { return }
        if unsentBody != nil {
            Haptics.warning()
            askCloseUnknown = true
        } else {
            dismiss()
        }
    }

    /// В карточке, открытой из результата, вручили / уведомили: перечитать розыгрыш,
    /// чтобы плашки результата были свежими, и обновить историю.
    private func resultChanged() {
        onDrawn()
        guard let id = result?["giveaway"]["id"].int else { return }
        let repeated = result?["repeated"] ?? .null
        Task { @MainActor in
            guard let d = try? await API.shared.get("/api/admin/giveaways/" + String(id)),
                  d["giveaway"]["id"].int == id else { return }
            var o = d.object
            o["repeated"] = repeated
            result = .object(o)
        }
    }

    // MARK: - Форма

    @ViewBuilder
    private var formSections: some View {
        Section {
            FormTextField("Приз *", text: $prize, prompt: "Например: пицца «Маргарита» или сертификат на 1000 ₽")
            fieldError("prize")
            FormTextField("Название розыгрыша", text: $title, prompt: "Розыгрыш " + todayText)
            Text("Необязательно — его увидят победители.")
                .font(.caption)
                .foregroundColor(Brand.muted)
            FormIntField("Сколько победителей *", text: $winnersText, prompt: "3")
            fieldError("winners_count")
            FormMultilineField("Как забрать приз", text: $pickup, minHeight: 80)
            Text("Будет в уведомлении победителю. Пусто — «напишите нам в Профиль → Поддержка».")
                .font(.caption)
                .foregroundColor(Brand.muted)
            fieldError("pickup_text")
        } header: {
            Text("Приз")
        }
        .disabled(locked)

        Section {
            Picker("Город", selection: $cityValue) {
                Text(allCitiesLabel).tag("")
                ForEach(cityPickerOptions) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            fieldError("city_id")
            FormToggle("Не включать сотрудников организаций", isOn: $excludeStaff)
            countRow
        } header: {
            Text("Участники")
        } footer: {
            Text("Город — тот, что покупатель выбрал в приложении. Владельцы организаций и администраторы не участвуют.")
        }
        .disabled(locked)

        if let e = error {
            Section {
                ErrorBanner(message: e)
            }
        }

        Section {
            Button {
                tapped()
            } label: {
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                        Text("Выбираем…")
                    } else if unsentBody != nil {
                        Label("Повторить", systemImage: "arrow.clockwise")
                            .font(.body.weight(.semibold))
                    } else {
                        Label("Провести розыгрыш", systemImage: "shuffle")
                            .font(.body.weight(.semibold))
                    }
                    Spacer()
                }
            }
            .disabled(busy)
        } footer: {
            Text("Победители выбираются случайно и сразу получают уведомление. Переиграть розыгрыш нельзя.")
        }
    }

    private var todayText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = Fmt.moscow
        f.dateFormat = "dd.MM.yyyy"
        return f.string(from: Date())
    }

    private var allCitiesLabel: String {
        noCity > 0 ? "Все города (в т. ч. без города: " + Fmt.number(noCity) + ")" : "Все города"
    }

    private var cityPickerOptions: [PickerOption] {
        var out = cities.map { PickerOption(value: String($0.id), label: $0.name + " — " + Fmt.number($0.count)) }
        if !cityValue.isEmpty && !out.contains(where: { $0.value == cityValue }) {
            out.append(PickerOption(value: cityValue, label: "Город #" + cityValue))
        }
        return out
    }

    private var cityName: String? {
        guard let id = Int(cityValue) else { return nil }
        return cities.first(where: { $0.id == id })?.name ?? ("#" + cityValue)
    }

    @ViewBuilder
    private var countRow: some View {
        HStack {
            Text("Участников").foregroundColor(Brand.muted)
            Spacer()
            if counting {
                ProgressView()
            } else if let t = total {
                Text(GiveawaysFormat.people(t)).fontWeight(.semibold).monospacedDigit()
            } else {
                Text("—").foregroundColor(Brand.muted)
            }
        }
        .font(.subheadline)
        if let e = countError {
            Text(e).font(.caption).foregroundColor(Brand.red)
        }
        if !cityValue.isEmpty && noCity > 0 {
            Text("У " + Fmt.plural(noCity, "покупателя", "покупателей", "покупателей")
                 + " город не указан — в розыгрыш по городу они не попадут.")
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
    }

    @ViewBuilder
    private func fieldError(_ key: String) -> some View {
        if let msg = fieldErrors[key] {
            Text(msg).font(.caption).foregroundColor(Brand.red)
        }
    }

    private var winnersCount: Int? { Int(trim(winnersText)) }

    private var confirmText: String {
        let n = winnersCount ?? 0
        var s = "Выбрать " + GiveawaysFormat.winners(n)
        if let t = total { s += " из " + GiveawaysFormat.participants(t) }
        s += "?\n\nПриз: " + trim(prize)
        s += "\nУчастники: " + GiveawaysFormat.whereText(city: cityName, excludeStaff: excludeStaff)
        s += "\n\nПобедители получат уведомление. Переиграть этот розыгрыш будет нельзя."
        return s
    }

    // MARK: - Число участников

    /// GET participants (первая страница без поиска) → all, cities, no_city.
    private func loadCount() async {
        countGeneration += 1
        let gen = countGeneration
        counting = true
        countError = nil
        let q: [String: String?] = [
            "page": "1",
            "city_id": cityValue.isEmpty ? nil : cityValue,
            "exclude_staff": excludeStaff ? "1" : "0",
        ]
        do {
            let d = try await API.shared.get("/api/admin/giveaways/participants", query: q)
            guard gen == countGeneration else { return }
            var stats = GiveawayParticipantsStats()
            stats.absorb(d)
            if d["cities"].isArray { cities = stats.cities }
            noCity = stats.noCity
            total = stats.all ?? d["total"].int
        } catch {
            guard gen == countGeneration, !APIError.isCancellation(error) else { return }
            total = nil
            countError = APIError.describe(error)
        }
        if gen == countGeneration { counting = false }
    }

    // MARK: - Отправка

    private func tapped() {
        guard !busy, result == nil else { return }
        // Исход прошлого нажатия неизвестен — тот же ключ и то же тело, без вопросов:
        // второго розыгрыша сервер не проведёт.
        if let body = unsentBody {
            send(body)
            return
        }
        error = nil
        var local: [String: String] = [:]
        if trim(prize).isEmpty { local["prize"] = "Укажите приз" }
        let n = winnersCount ?? 0
        if n < 1 || n > GiveawaysFormat.maxWinners {
            local["winners_count"] = "Победителей — от 1 до " + String(GiveawaysFormat.maxWinners)
        } else if let t = total, n > t {
            local["winners_count"] = "Победителей больше, чем участников (" + String(t) + ")"
        }
        fieldErrors = local
        if !local.isEmpty {
            error = "Проверьте отмеченные поля."
            Haptics.error()
            return
        }
        Haptics.tap()
        askConfirm = true
    }

    /// Тело запроса. Значения — JSON, чтобы при «Повторить» ушло ровно то же.
    private func buildBody() -> [String: JSON] {
        var b: [String: JSON] = [
            "title": .string(trim(title)),
            "prize": .string(trim(prize)),
            "winners_count": .number(Double(winnersCount ?? 0)),
            "pickup_text": .string(trim(pickup)),
            "exclude_staff": .bool(excludeStaff),
            "draw_key": .string(drawKey),
        ]
        if let cid = Int(cityValue), cid > 0 { b["city_id"] = .number(Double(cid)) } else { b["city_id"] = .null }
        return b
    }

    private func send(_ body: [String: JSON]) {
        guard !busy else { return }
        busy = true
        error = nil
        var payload: [String: Any?] = [:]
        for (k, v) in body { payload[k] = v.toAny() }
        Task { @MainActor in
            do {
                // До 200 с: сервер синхронно шлёт push до 50 победителям (set_time_limit 180).
                let data = try await API.shared.post("/api/admin/giveaways/draw", body: payload,
                                                     timeout: GiveawayDrawSheet.drawTimeout)
                busy = false
                unsentBody = nil
                fieldErrors = [:]
                guard data["giveaway"].isObject else {
                    // 200 без розыгрыша в ответе — исход неизвестен, повтор вернёт проведённый.
                    unsentBody = body
                    error = "Сервер вернул непонятный ответ. Нажмите «Повторить» — второго розыгрыша не будет."
                    onDrawn()
                    return
                }
                Haptics.success()
                result = data
                onDrawn()
            } catch {
                busy = false
                let e = (error as? APIError) ?? API.mapTransport(error)
                if GiveawayDrawSheet.isOutcomeUnknown(e) {
                    unsentBody = body
                    if !APIError.isCancellation(error) { Haptics.error() }
                    self.error = (e == .cancelled ? "Запрос прервался." : e.message)
                        + "\nРозыгрыш мог пройти. Нажмите «Повторить» — второго розыгрыша не будет: сервер покажет уже проведённый."
                    onDrawn()
                } else {
                    // Ответ сервера получен — розыгрыш не проведён, форму можно поправить.
                    unsentBody = nil
                    Haptics.error()
                    fieldErrors = e.fieldErrors
                    self.error = e.message
                }
            }
        }
    }

    /// Ожидание ответа на «Провести розыгрыш», с.
    static let drawTimeout: TimeInterval = 200

    /// Исход неизвестен: нет связи, отмена, непонятный ответ, 5xx. 4xx — окончательный
    /// отказ (сервер отвечает им до записи розыгрыша). 503 «Розыгрыши временно
    /// недоступны» (gwRun: таблицы не готовы) тоже окончательный — его сервер даёт
    /// до розыгрыша; 503 хостинга (без этого текста) — неизвестный исход.
    static func isOutcomeUnknown(_ e: APIError) -> Bool {
        switch e {
        case .offline, .cancelled, .badResponse: return true
        default:
            if e.status == 503 && e.message.contains("Розыгрыши временно недоступны") { return false }
            return e.status == 0 || e.status >= 500
        }
    }
}

/// Результат розыгрыша (внутри Form/List): победители, сколько участвовало, сколько уведомлено.
struct GiveawayDrawResultSections: View {
    let data: JSON
    @ObservedObject var privacy: GiveawaysPrivacy
    let onChanged: () -> Void

    init(data: JSON, privacy: GiveawaysPrivacy, onChanged: @escaping () -> Void) {
        self.data = data
        self.privacy = privacy
        self.onChanged = onChanged
    }

    private var g: JSON { data["giveaway"] }
    private var winners: [JSON] { data["winners"].array }

    var body: some View {
        if data["repeated"].boolValue {
            Section {
                InfoBanner("Этот розыгрыш уже был проведён (ответ сервера мог не дойти) — показаны его победители.",
                           systemImage: "arrow.uturn.backward.circle")
            }
        }
        Section {
            GiveawaysPrivacyToggle(privacy: privacy)
        }
        Section {
            ForEach(Array(winners.enumerated()), id: \.offset) { pair in
                GiveawayWinnerSummaryRow(winner: pair.element, prize: g["prize"].string, hidden: privacy.hidePhones)
            }
        } header: {
            Text(g["title"].nonEmptyString ?? "Победители")
        } footer: {
            Text(summaryText)
        }
        if let id = g["id"].int {
            Section {
                NavigationLink(destination: GiveawayDetailView(id: id, privacy: privacy, onChanged: onChanged)) {
                    Label("Открыть розыгрыш: вручение и повторное уведомление", systemImage: "rosette")
                }
            }
        }
    }

    private var summaryText: String {
        let p = g["participants"].intValue
        let reached = winners.filter { GiveawayDeliveryBadge.reached($0) }.count
        var s = (p % 10 == 1 && p % 100 != 11 ? "Участвовал " : "Участвовали ") + GiveawaysFormat.people(p) + "."
        s += " Уведомление «Вы выиграли» дошло (push или письмо): " + String(reached) + " из " + String(winners.count) + "."
        if reached < winners.count {
            s += " Остальным позвоните — или нажмите «Уведомить ещё раз» в карточке розыгрыша."
        }
        return s
    }
}
