import SwiftUI

/// «Кто видит вызов» — волна А96 сайта (ОТВЕТЫ-САЙТА.md, раздел «Кто видит вызов»):
///
/// GET /api/admin/pool/calls/{id}/visibility →
/// `{call: {id, kind, status, status_label, city, client_id, wave, created_at, expires_at, search_minutes},
///   visible_count, online_in_city, notes: [], couriers: [{user_id, name, phone, status, status_label,
///   city_id, city, online, last_seen_at, visible, reasons: [{code, text}]}]}`.
///
/// Показываем текст причины (`reasons[].text`) как есть; код (`not_searching`, `disabled`,
/// `courier_status`, `rules`, `city`, `own_parcel`, `target`, `declined`, `offline`, `blocked`,
/// `busy`, `vehicle`, `cash`, `wave`) — только для значка и цвета.
///
/// Ручка ищет по НОМЕРУ ВЫЗОВА курьера (pool_calls.id, CourierPool::adminVisibility), а не по
/// номеру заказа (orders.daily_number — его называют заведение и клиент). Поэтому везде
/// «Вызов №…»; по номеру заказа вызов ищет сервер: GET /api/admin/pool/calls?q=<число>
/// (П-62, А316) — CallVisibilityLookupSheet.
///
/// 404 с кодом `not_found` — «Вызов не найден». 404 «Эндпоинт не найден» (`no_route`, сервер
/// до А96) — ручки нет: входы в экран прячутся (CallVisibilitySupport).
enum CallVisibility {
    /// Путь ручки для вызова.
    static func path(_ callId: Int) -> String {
        "/api/admin/pool/calls/" + String(callId) + "/visibility"
    }

    /// Ответ «нет такой ручки» (старый сервер): 404 с текстом роутера «Эндпоинт не найден»
    /// (index.php, code no_route). Текст сверяем, потому что клиент код ответа не хранит,
    /// а серверы до волны А54 присылали тот же текст без кода.
    static func isNoRoute(_ error: Error) -> Bool {
        guard let e = error as? APIError, e.status == 404 else { return false }
        return e.message.contains("Эндпоинт")
    }

    /// «Посылка» / «Доставка из заведения».
    static func kindLabel(_ kind: String?) -> String {
        switch kind ?? "" {
        case "parcel": return "Посылка"
        case "shop": return "Доставка из заведения"
        default: return "Доставка"
        }
    }

    /// Цвет статуса вызова (CourierPool::CALL_LABELS).
    static func statusColor(_ s: String?) -> Color {
        switch s ?? "" {
        case "searching": return Brand.amber
        case "accepted", "picked": return Brand.blue
        case "delivered": return Brand.green
        case "failed", "cancelled", "expired": return Brand.red
        default: return Brand.muted
        }
    }

    /// Волна поиска: 1 — курьерам рядом с местом забора, 2 — всем в городе.
    static func waveText(_ w: Int) -> String {
        switch w {
        case 1: return "1 — курьерам рядом с местом забора"
        case 2: return "2 — всем курьерам в городе"
        default: return String(w)
        }
    }

    /// Значок причины по коду.
    static func reasonSymbol(_ code: String?) -> String {
        switch code ?? "" {
        case "not_searching": return "pause.circle"
        case "disabled": return "power"
        case "courier_status": return "person.crop.circle.badge.xmark"
        case "rules": return "checkmark.shield"
        case "city": return "building.2"
        case "own_parcel": return "shippingbox"
        case "target": return "scope"
        case "declined": return "hand.raised"
        case "offline": return "wifi.slash"
        case "blocked": return "lock"
        case "busy": return "clock"
        case "vehicle": return "car"
        case "cash": return "rublesign.circle"
        case "wave": return "dot.radiowaves.left.and.right"
        default: return "info.circle"
        }
    }

    /// Цвет причины: красный — курьер не может брать заказы вообще (блок, статус, правила, долг),
    /// янтарный — временно (не на линии, занят, волна, отказался), серый — свойства заказа.
    static func reasonColor(_ code: String?) -> Color {
        switch code ?? "" {
        case "blocked", "courier_status", "rules", "cash", "disabled": return Brand.red
        case "offline", "busy", "wave", "declined", "not_searching": return Brand.amber
        default: return Brand.muted
        }
    }
}

/// Есть ли на сервере ручка «Кто видит заказ». Проверяется один раз за запуск, когда
/// открывают раздел «Курьеры» (CouriersRootView): GET …/calls/0/visibility. Любой ответ
/// сервера, кроме 404 no_route, — ручка есть. Пока не проверили — входы не показываем,
/// на старом сервере (до А96) они так и не появятся. Нет сети — показываем (экран сам
/// покажет ошибку и «Повторить»).
@MainActor
final class CallVisibilitySupport: ObservableObject {
    static let shared = CallVisibilitySupport()

    enum Availability {
        /// Ещё не проверяли.
        case unknown
        /// Ручка есть.
        case available
        /// Сервер старый — ручки нет.
        case missing
        /// Проверить не вышло (нет сети) — показываем, проверим снова при следующем входе.
        case unverified
    }

    @Published private(set) var state: Availability = .unknown
    private var probing = false

    /// Показывать ли входы в экран.
    var showsEntry: Bool { state == .available || state == .unverified }

    /// Проверить ручку, если ещё не знаем ответа.
    func probeIfNeeded() async {
        guard state == .unknown || state == .unverified, !probing else { return }
        probing = true
        defer { probing = false }
        do {
            _ = try await API.shared.get(CallVisibility.path(0))
            state = .available
        } catch {
            if APIError.isCancellation(error) { return }
            if CallVisibility.isNoRoute(error) {
                state = .missing
            } else if let e = error as? APIError, e.status != 0 {
                // 404 «Заказ не найден», 503 «временно недоступны» и т.п. — ручка на сервере есть.
                state = .available
            } else {
                state = .unverified
            }
        }
    }

    /// Экран получил ответ ручки.
    func markAvailable() { state = .available }

    /// Экран получил 404 no_route — спрятать входы.
    func markMissing() { state = .missing }
}

/// Загрузка экрана «Кто видит заказ».
@MainActor
final class CallVisibilityLoader: ObservableObject {
    /// Что показать вместо данных.
    enum Problem: Equatable {
        /// 404 not_found — заказа с таким номером нет.
        case notFound
        /// 404 no_route — сервер до А96.
        case noRoute
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var data: JSON = .null
    @Published private(set) var problem: Problem?
    /// Ошибка повторной загрузки (на экране прежние данные).
    @Published var refreshError: String?

    let callId: Int
    private var generation = 0

    init(callId: Int) {
        self.callId = callId
    }

    func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    func load() async {
        generation += 1
        let gen = generation
        if data.isNull { state = .loading }
        do {
            let j = try await API.shared.get(CallVisibility.path(callId))
            guard gen == generation else { return }
            CallVisibilitySupport.shared.markAvailable()
            guard j.isObject else {
                if data.isNull { state = .empty("Сервер не прислал данных о вызове") }
                return
            }
            data = j
            problem = nil
            refreshError = nil
            state = .loaded
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            if CallVisibility.isNoRoute(error) {
                CallVisibilitySupport.shared.markMissing()
                data = .null
                problem = .noRoute
                refreshError = nil
                state = .empty(nil)
                return
            }
            if let e = error as? APIError, e.status == 404 {
                data = .null
                problem = .notFound
                refreshError = nil
                state = .empty(nil)
                return
            }
            if data.isNull {
                state = .failed(APIError.describe(error))
            } else {
                refreshError = APIError.describe(error)
            }
        }
    }
}

/// Экран «Кто видит вызов»: шапка вызова, «Видят: N из M на линии в городе», заметки
/// сервера и список курьеров города — видит ✓ / не видит ✗, на линии, когда был, причины.
/// `title` — как вызов назван там, откуда открыли («Заказ №57» из call_title жалобы,
/// «Доставка №…» из проблемы): показываем рядом с номером вызова, чтобы было ясно, что это одно и то же.
struct CallVisibilityView: View {
    let callId: Int
    let title: String?

    @StateObject private var loader: CallVisibilityLoader

    init(callId: Int, title: String? = nil) {
        self.callId = callId
        self.title = title
        _loader = StateObject(wrappedValue: CallVisibilityLoader(callId: callId))
    }

    private var d: JSON { loader.data }
    private var call: JSON { d["call"] }
    private var couriers: [JSON] { d["couriers"].array }
    private var seeing: [JSON] { couriers.filter { $0["visible"].boolValue } }
    private var notSeeing: [JSON] { couriers.filter { !$0["visible"].boolValue } }

    var body: some View {
        List {
            if let err = loader.refreshError {
                ErrorBanner(message: err, retry: { Task { await loader.load() } })
                    .listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Кто видит вызов")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loader.load() }
        .task { await loader.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await loader.load() })
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .empty(let text):
            emptyView(text)
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private func emptyView(_ text: String?) -> some View {
        switch loader.problem {
        case .notFound:
            EmptyStateView(title: "Вызов не найден", systemImage: "questionmark.circle",
                           message: "Вызова курьера №" + String(callId) + " нет. Это номер вызова, а не номер заказа — проверьте номер или найдите вызов по номеру заказа.")
        case .noRoute:
            EmptyStateView(title: "Сервер пока не показывает, кто видит вызов", systemImage: "eye.slash",
                           message: "Нужно обновить сайт (волна А96).")
        case nil:
            EmptyStateView(title: text ?? "Нет данных", systemImage: "tray")
        }
    }

    @ViewBuilder
    private var loaded: some View {
        callSection
        if !d["notes"].array.isEmpty {
            Section {
                ForEach(Array(d["notes"].array.enumerated()), id: \.offset) { pair in
                    InfoBanner(noteText(pair.element), systemImage: "lightbulb", color: Brand.blue)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                }
            }
        }
        if couriers.isEmpty {
            Section {
                Text("Курьеров в городе вызова нет.")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            }
        } else {
            if !seeing.isEmpty {
                Section("Видят · " + String(seeing.count)) {
                    ForEach(keyed(seeing), id: \.0) { pair in courierRow(pair.1) }
                }
            }
            if !notSeeing.isEmpty {
                Section("Не видят · " + String(notSeeing.count)) {
                    ForEach(keyed(notSeeing), id: \.0) { pair in courierRow(pair.1) }
                }
            }
        }
        Section { JSONInspectorView(d) }
    }

    /// Ключ строки — user_id: при «потянуть» строка курьера меняется (когда был, причины),
    /// а ключ остаётся тем же.
    private func keyed(_ list: [JSON]) -> [(String, JSON)] {
        list.enumerated().map { pair in
            (pair.element["user_id"].int.map { "u" + String($0) } ?? ("i" + String(pair.offset)), pair.element)
        }
    }

    /// Заметка сервера: строка или {text}.
    private func noteText(_ n: JSON) -> String {
        n.nonEmptyString ?? n["text"].nonEmptyString ?? n.compactText
    }

    private var callSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Вызов №" + (call["id"].string ?? String(callId)))
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 6)
                    StatusBadge(call["status_label"].nonEmptyString ?? Fmt.statusLabel(call["status"].string),
                                color: CallVisibility.statusColor(call["status"].string))
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                Text(countLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(d["visible_count"].intValue > 0 ? Brand.green : Brand.red)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            KVRow("Город", call["city"].string)
            if let w = call["wave"].int, w > 0 {
                KVRow("Волна", CallVisibility.waveText(w))
            }
            KVRow("Создан", Fmt.date(call["created_at"]))
            if call["expires_at"].nonEmptyString != nil {
                KVRow("Ищем до", Fmt.date(call["expires_at"]))
            }
            if let m = call["search_minutes"].int, m > 0 {
                KVRow("Время поиска", String(m) + " мин")
            }
        }
    }

    /// «Доставка из заведения · Заказ №57».
    private var subtitle: String {
        var parts: [String] = [CallVisibility.kindLabel(call["kind"].string)]
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    /// «Видят: 1 из 2 на линии в городе».
    private var countLine: String {
        "Видят: " + Fmt.number(d["visible_count"].intValue) + " из "
            + Fmt.number(d["online_in_city"].intValue) + " на линии в городе"
    }

    @ViewBuilder
    private func courierRow(_ c: JSON) -> some View {
        if let uid = c["user_id"].int, uid > 0 {
            NavigationLink(destination: CourierDetailView(id: uid)) {
                CallVisibilityCourierRow(courier: c)
            }
            .accessibilityHint("Открыть карточку курьера")
        } else {
            CallVisibilityCourierRow(courier: c)
        }
    }
}

/// Курьер в «Кто видит заказ»: ✓ / ✗, имя, статус, на линии, когда был, причины.
struct CallVisibilityCourierRow: View {
    let courier: JSON

    init(courier: JSON) {
        self.courier = courier
    }

    private var visible: Bool { courier["visible"].boolValue }
    private var online: Bool { courier["online"].boolValue }
    private var reasons: [JSON] { courier["reasons"].array }
    private var name: String { courier["name"].nonEmptyString ?? "Без имени" }

    private var info: String {
        var parts: [String] = []
        if let p = courier["phone"].nonEmptyString { parts.append(Fmt.phone(p)) }
        if let c = courier["city"].nonEmptyString { parts.append(c) }
        parts.append(online ? "на линии" : "не на линии")
        if courier["last_seen_at"].nonEmptyString != nil {
            parts.append("был " + Fmt.date(courier["last_seen_at"]))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: visible ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(visible ? Brand.green : Brand.red)
                    .accessibilityLabel(visible ? "Видит вызов" : "Не видит вызов")
                Text(name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if online {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundColor(Brand.green)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 6)
                StatusBadge(status: courier["status"].string,
                            label: courier["status_label"].nonEmptyString ?? CouriersFormat.statusLabel(courier["status"].string))
            }
            Text(info)
                .font(.caption)
                .foregroundColor(Brand.muted)
            ForEach(Array(reasons.enumerated()), id: \.offset) { pair in
                reasonLine(pair.element)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func reasonLine(_ r: JSON) -> some View {
        let code = r["code"].string
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: CallVisibility.reasonSymbol(code))
                .font(.caption)
                .foregroundColor(CallVisibility.reasonColor(code))
                .accessibilityHidden(true)
            Text(r["text"].nonEmptyString ?? r["code"].stringValue)
                .font(.caption)
                .foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Строка-ссылка «Кто видит: …» для карточек проблем и жалоб. `title` — то же название
/// вызова, что в карточке выше («Заказ №57» из call_title, «Доставка №…»), чтобы одна и
/// та же доставка не называлась в одной карточке двумя разными номерами. На старом
/// сервере (и пока ручку не проверили) — ничего.
struct CallVisibilityLink: View {
    let callId: Int
    let title: String?
    @ObservedObject private var support = CallVisibilitySupport.shared

    init(callId: Int, title: String? = nil) {
        self.callId = callId
        self.title = title
    }

    private var name: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return "Вызов №" + String(callId)
    }

    var body: some View {
        if support.showsEntry && callId > 0 {
            NavigationLink(destination: CallVisibilityView(callId: callId, title: title)) {
                Label("Кто видит: " + name, systemImage: "eye")
            }
            .accessibilityHint("Какие курьеры видят этот вызов в ленте и почему")
        }
    }
}

/// Строка списка, которая открывает «Кто видит вызов» (последние доставки в карточке курьера).
/// Ручки нет — строка остаётся простой, как раньше.
struct CallVisibilityRowLink<Content: View>: View {
    let callId: Int
    let content: Content
    @ObservedObject private var support = CallVisibilitySupport.shared

    init(callId: Int, @ViewBuilder content: () -> Content) {
        self.callId = callId
        self.content = content()
    }

    var body: some View {
        if support.showsEntry && callId > 0 {
            NavigationLink(destination: CallVisibilityView(callId: callId)) {
                content
            }
            .accessibilityHint("Открыть «Кто видит вызов»")
        } else {
            content
        }
    }
}

/// Вызов, открытый из поиска.
struct CallVisibilityTarget: Hashable {
    let id: Int
    let title: String?
}

/// Лист «Кто видит вызов» (кнопка с глазом в шапке раздела «Курьеры»): по номеру вызова
/// курьера или по номеру заказа.
///
/// Сервер ищет «кто видит» только по номеру вызова (pool_calls.id). Номер заказа
/// (orders.daily_number) у каждого заведения свой и повторяется по дням, поэтому вызов по
/// нему ищет сам сервер: GET /api/admin/pool/calls?q=<число> (П-62, А316) — номер вызова,
/// сквозной номер заказа или номер дня заказа за 3 последних дня; `meta.total` учитывает
/// поиск. Показываем все совпадения по заказу (сквозной номер или номер дня) с заведением и
/// датой. Старый сервер `q` не знает — тогда, как раньше, листаем список: живые вызовы
/// (status=active, до 4 страниц по 50) и последние 100 любых.
struct CallVisibilityLookupSheet: View {
    enum Mode: String {
        case call, order
    }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .call
    @State private var text = ""
    @State private var opened = CallVisibilityTarget(id: 0, title: nil)
    @State private var showResult = false
    @State private var searching = false
    @State private var matches: [JSON]?
    @State private var searchedNumber = 0
    @State private var searchError: String?
    @FocusState private var focused: Bool

    private var number: Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "№", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let n = Int(digits), n > 0 else { return nil }
        return n
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Что известно", selection: $mode) {
                        Text("Номер вызова").tag(Mode.call)
                        Text("Номер заказа").tag(Mode.order)
                    }
                    .pickerStyle(.segmented)
                    TextField("Например, 12", text: $text)
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit(open)
                        .accessibilityLabel(mode == .call ? "Номер вызова" : "Номер заказа")
                } header: {
                    Text(mode == .call ? "Вызов курьера №" : "Заказ №")
                } footer: {
                    Text(mode == .call
                         ? "Номер вызова курьера — как в «Проблемах», «Жалобах» и последних доставках курьера. Это не номер заказа."
                         : "Номер заказа, который называют заведение и клиент (номер дня за последние 3 дня) или сквозной номер заказа. Номер дня у каждого заведения свой — совпадений может быть несколько.")
                }
                Section {
                    Button(action: open) {
                        HStack {
                            Spacer()
                            if searching {
                                ProgressView()
                                Text("Ищем вызов…")
                            } else {
                                Text(mode == .call ? "Показать, кто видит" : "Найти вызов").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(number == nil || searching)
                }
                if let e = searchError {
                    Section { ErrorBanner(message: e) }
                }
                if mode == .order, let list = matches {
                    matchesSection(list)
                }
            }
            .navigationTitle("Кто видит вызов")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showResult) {
                CallVisibilityView(callId: opened.id, title: opened.title)
                    .id(opened.id)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .onChange(of: mode) { _ in
                matches = nil
                searchError = nil
            }
        }
    }

    @ViewBuilder
    private func matchesSection(_ list: [JSON]) -> some View {
        Section {
            if list.isEmpty {
                Text("Вызова курьера для заказа №" + String(searchedNumber) + " не нашлось (номер дня ищется за последние 3 дня). Если заказ старый — введите сквозной номер заказа или откройте «Кто видит» из карточки проблемы, жалобы или курьера.")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            } else {
                ForEach(list, id: \.stableID) { c in
                    Button {
                        go(CallVisibilityTarget(id: c.id ?? 0, title: c["title"].nonEmptyString))
                    } label: {
                        CallVisibilityMatchRow(call: c)
                    }
                    .disabled((c.id ?? 0) <= 0)
                }
            }
        } header: {
            Text("Найдено: " + String(list.count))
        }
    }

    private func open() {
        guard let n = number, !searching else { return }
        focused = false
        searchError = nil
        if mode == .call {
            go(CallVisibilityTarget(id: n, title: nil))
            return
        }
        searching = true
        matches = nil
        Task { @MainActor in
            do {
                let list = try await CallVisibilityLookupSheet.findByOrder(n)
                searchedNumber = n
                matches = list
                // Номер заказа повторяется (по заведениям и дням) — всегда показываем список
                // с заведением и датой; сами открываем только единственный живой вызов за сегодня.
                if list.count == 1, let only = list.first, let id = only.id, id > 0,
                   CallVisibilityLookupSheet.isLiveToday(only) {
                    go(CallVisibilityTarget(id: id, title: only["title"].nonEmptyString))
                }
            } catch {
                if !APIError.isCancellation(error) {
                    searchError = "Найти по номеру заказа не вышло: " + APIError.describe(error)
                        + "\nВведите номер вызова курьера."
                }
            }
            searching = false
        }
    }

    private func go(_ target: CallVisibilityTarget) {
        guard target.id > 0 else { return }
        opened = target
        showResult = true
    }

    /// Живой вызов (ищем / принят / забран), созданный сегодня по Москве.
    static func isLiveToday(_ c: JSON) -> Bool {
        guard ["searching", "accepted", "picked"].contains(c["status"].stringValue),
              let d = Fmt.parseDate(c["created_at"].string) else { return false }
        return Fmt.ymd(d) == Fmt.ymd(Date())
    }

    /// Вызовы заказа n: сервер ищет по `q` (сквозной номер заказа или номер дня за 3 дня);
    /// оставляем совпадения по заказу (не по номеру вызова). Старый сервер `q` не знает и
    /// отдаёт обычный список — тогда листаем, как раньше (findByOrderPaging).
    static func findByOrder(_ n: Int) async throws -> [JSON] {
        var found: [JSON] = []
        var seen = Set<Int>()
        var page = 1
        while page <= 3 {
            let res = try await API.shared.getResult("/api/admin/pool/calls",
                                                     query: ["q": String(n), "page": String(page)])
            let items = res.data.isArray ? res.data.array : res.data["items"].array
            // Строка, не подходящая ни по вызову, ни по заказу, — сервер поиск не применил.
            let ignored = items.contains { it in
                it.id != n && it["order_id"].int != n && it["order_number"].int != n
            }
            if ignored { return try await findByOrderPaging(n) }
            for it in items where it["order_number"].int == n || it["order_id"].int == n {
                guard let id = it.id, seen.insert(id).inserted else { continue }
                found.append(it)
            }
            let total = res.meta["total"].int ?? 0
            if items.count < 50 || page * 50 >= total { break }
            page += 1
        }
        return found
    }

    /// Старый сервер: вызовы с order_number == n — живые (до 4 страниц) и последние 100 любых.
    static func findByOrderPaging(_ n: Int) async throws -> [JSON] {
        var found: [JSON] = []
        var seen = Set<Int>()
        let passes: [([String: String?], Int)] = [(["status": "active"], 4), ([:], 2)]
        for (filters, maxPages) in passes {
            var page = 1
            while page <= maxPages {
                var q = filters
                q["page"] = String(page)
                let res = try await API.shared.getResult("/api/admin/pool/calls", query: q)
                let items = res.data.isArray ? res.data.array : res.data["items"].array
                for it in items where it["order_number"].int == n {
                    guard let id = it.id, seen.insert(id).inserted else { continue }
                    found.append(it)
                }
                let total = res.meta["total"].int ?? 0
                if items.count < 50 || page * 50 >= total { break }
                page += 1
            }
        }
        return found
    }
}

/// Найденный по номеру заказа вызов: «Заказ №57 · Пекарня», статус, вызов №, когда.
struct CallVisibilityMatchRow: View {
    let call: JSON

    private var line: String {
        var parts: [String] = ["вызов №" + String(call.id ?? 0)]
        if let shop = call["shop_name"].nonEmptyString { parts.append(shop) }
        parts.append(Fmt.date(call["created_at"]))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(call["title"].nonEmptyString ?? ("Вызов №" + String(call.id ?? 0)))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Text(line)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Spacer(minLength: 6)
            StatusBadge(call["status_label"].nonEmptyString ?? Fmt.statusLabel(call["status"].string),
                        color: CallVisibility.statusColor(call["status"].string))
        }
    }
}
