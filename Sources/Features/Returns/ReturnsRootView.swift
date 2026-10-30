import SwiftUI

/// Раздел «Возвраты» (returns в admin.js): все заявки на возврат и эскалированные
/// (на рассмотрении дольше 72 часов), модерация (одобрить / отклонить с причиной),
/// отметка «деньги выплачены», массовые действия по выбранным.
///
/// GET  /api/admin/returns?status=&escalated=1&q=&page= → {items, stats:{cnt, avg_amount}, total, page, pages}
///      строка: id, order_id, shop_id, type, reason_code, status, refund_amount, refund_method, created_at,
///      shop, client, age_hours, order_daily_number (П-62, А316: номер дня заказа — «№N · #id»).
///      Поиск q — номер заказа (сквозной или номер дня)/возврата, магазин, клиент.
/// POST /api/admin/returns/{id}/moderate {decision: "approve"} | {decision: "reject", note}
/// POST /api/admin/returns/{id}/paid {note?} — только для refund_method = manual в статусе approved/refunded.
/// `openId` — сразу открыть заявку с этим id.
struct ReturnsRootView: View {
    let openId: Int?

    @StateObject private var model: PagedListModel
    @State private var selecting = false
    @State private var selected: Set<Int> = []
    @State private var pending: ConfirmAction?
    @State private var pendingOp: ReturnsPendingOp?
    @State private var rejectIds: ReturnsIdList?
    @State private var paidRow: JSON?
    @State private var bulkResult: String?
    /// Итог массового отказа: показываем после закрытия листа (алерт поверх листа не всплывёт).
    @State private var deferredResult: String?
    @State private var bulkBusy = false
    /// Заявка, решение по которой (свайп) сейчас уходит на сервер: строка с индикатором и без действий.
    @State private var busyRowId: Int?
    @State private var deepLinkShown = false
    @State private var deepLinkHandled = false

    /// - Parameters:
    ///   - openId: id заявки (deep link);
    ///   - escalated: открыть сразу режим «Эскалированные» (переход со сводки «без ответа > 72 ч»).
    init(openId: Int? = nil, escalated: Bool = false) {
        self.openId = openId
        let start: [String: String] = escalated ? ["escalated": "1"] : [:]
        _model = StateObject(wrappedValue: PagedListModel(path: "/api/admin/returns", filters: start))
    }

    private var escalated: Bool { model.filter("escalated") != nil }
    private var hasPending: Bool { model.items.contains { $0["status"].string == "pending" } }

    var body: some View {
        list
            .navigationTitle("Возвраты")
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "№ заказа (или номер дня), магазин, клиент")
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { bulkBar }
            .task { await model.loadIfNeeded() }
            .confirmAction($pending) {
                try await runPendingOp()
            }
            .sheet(item: $rejectIds, onDismiss: { showDeferredResult() }) { box in
                ReturnsRejectSheet(count: box.ids.count) { note in
                    try await reject(ids: box.ids, note: note)
                }
            }
            .sheet(item: paidBinding) { box in
                ReturnsPaidSheet(row: box.row) { note in
                    try await ReturnsActions.markPaid(id: box.row.id ?? 0, note: note)
                    refreshAfterAction()
                }
            }
            .alert("Готово", isPresented: bulkResultShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(bulkResult ?? "")
            }
            .navigationDestination(isPresented: $deepLinkShown) {
                ReturnDetailView(id: openId ?? 0, onChanged: { refreshAfterAction() })
            }
            .onAppear { openDeepLinkOnce() }
    }

    // MARK: - Список

    private var list: some View {
        List {
            modePicker
                .listRowSeparator(.hidden)
            if !escalated {
                FilterChipsRow(filters: ReturnsRootView.filters, model: model)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
            }
            ReturnsStatsHeader(model: model)
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            stateSection
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }

    private var modePicker: some View {
        Picker("Режим", selection: modeBinding) {
            Text("Все").tag(false)
            Text("⚠️ Эскалированные").tag(true)
        }
        .pickerStyle(.segmented)
    }

    private var modeBinding: Binding<Bool> {
        Binding(get: { model.filter("escalated") != nil }, set: { setEscalated($0) })
    }

    private func setEscalated(_ on: Bool) {
        selected = []
        if on {
            // Сервер при escalated статус не учитывает — снимаем, чтобы чип не врал.
            if model.filter("status") != nil { model.setFilter("status", nil) }
            model.setFilter("escalated", "1")
        } else {
            model.setFilter("escalated", nil)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch model.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 40)
                .listRowSeparator(.hidden)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.reload() })
                .frame(minHeight: 260)
                .listRowSeparator(.hidden)
        case .empty:
            EmptyStateView(title: escalated ? "Эскалированных заявок нет" : "Заявок нет", systemImage: "tray")
                .frame(minHeight: 260)
                .listRowSeparator(.hidden)
        case .loaded:
            ForEach(model.items, id: \.stableID) { item in
                row(item)
                    .task { await model.loadMoreIfNeeded(current: item) }
            }
            ListFooter(model: model)
        }
    }

    @ViewBuilder
    private func row(_ item: JSON) -> some View {
        if selecting {
            ReturnsSelectableRow(item: item, isSelected: selected.contains(item.id ?? -1)) {
                toggle(item)
            }
        } else {
            let rowBusy = busyRowId != nil && busyRowId == item.id
            NavigationLink(destination: ReturnDetailView(id: item.id ?? 0, initial: item, onChanged: { refreshAfterAction() })) {
                ReturnsRow(item: item)
                    .opacity(rowBusy ? 0.5 : 1)
                    .overlay(alignment: .trailing) {
                        if rowBusy { ProgressView() }
                    }
            }
            .disabled(rowBusy)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !rowBusy { swipeButtons(item) }
            }
        }
    }

    @ViewBuilder
    private func swipeButtons(_ item: JSON) -> some View {
        if item["status"].string == "pending" {
            Button(role: .destructive) {
                if let id = item.id { rejectIds = ReturnsIdList(ids: [id]) }
            } label: {
                Label("Отклонить", systemImage: "xmark")
            }
            Button {
                askApprove(item)
            } label: {
                Label("Одобрить", systemImage: "checkmark")
            }
            .tint(Brand.green)
        } else if ReturnsActions.canMarkPaid(item) {
            Button {
                paidRow = item
            } label: {
                Label("Выплачено", systemImage: "banknote")
            }
            .tint(Brand.blue)
        }
    }

    // MARK: - Панель массовых действий

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if selecting {
                Button("Готово") {
                    selecting = false
                    selected = []
                }
            } else if hasPending {
                Button("Выбрать") { selecting = true }
            }
        }
    }

    private var selectedRows: [JSON] {
        model.items.filter { row in
            guard let id = row.id else { return false }
            return selected.contains(id) && row["status"].string == "pending"
        }
    }

    private var selectedSum: Decimal {
        var sum: Decimal = 0
        for r in selectedRows { sum += r["refund_amount"].decimal ?? 0 }
        return sum
    }

    @ViewBuilder
    private var bulkBar: some View {
        if selecting {
            ReturnsBulkBar(count: selectedRows.count, sum: selectedSum, busy: bulkBusy,
                           approve: { askBulkApprove() },
                           reject: { askBulkReject() })
        }
    }

    private func toggle(_ item: JSON) {
        guard let id = item.id, item["status"].string == "pending" else { return }
        Haptics.tap()
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    // MARK: - Действия

    private func askApprove(_ item: JSON) {
        guard let id = item.id else { return }
        pendingOp = .approve([id])
        pending = ReturnsActions.approveConfirm(rows: [item])
    }

    private func askBulkApprove() {
        let rows = selectedRows
        guard !rows.isEmpty else { return }
        pendingOp = .approve(rows.compactMap { $0.id })
        pending = ReturnsActions.approveConfirm(rows: rows)
    }

    private func askBulkReject() {
        let ids = selectedRows.compactMap { $0.id }
        guard !ids.isEmpty else { return }
        rejectIds = ReturnsIdList(ids: ids)
    }

    private func runPendingOp() async throws {
        guard let op = pendingOp else { return }
        pendingOp = nil
        switch op {
        case .approve(let ids):
            if ids.count == 1, let id = ids.first {
                busyRowId = id
                defer { busyRowId = nil }
                try await ReturnsActions.moderate(id: id, approve: true, note: nil)
                refreshAfterAction()
            } else {
                bulkResult = await runBulk(ids: ids, approve: true, note: nil)
            }
        }
    }

    private func reject(ids: [Int], note: String) async throws {
        if ids.count == 1, let id = ids.first {
            try await ReturnsActions.moderate(id: id, approve: false, note: note)
            refreshAfterAction()
        } else {
            deferredResult = await runBulk(ids: ids, approve: false, note: note)
        }
    }

    private func showDeferredResult() {
        guard let text = deferredResult else { return }
        deferredResult = nil
        bulkResult = text
    }

    /// Как bulkRun на сайте: по одной заявке, честный подсчёт удачных и ошибок
    /// (сервер штатно отвечает 409 «уже обработана» / «позиции уже возвращены»).
    private func runBulk(ids: [Int], approve: Bool, note: String?) async -> String {
        bulkBusy = true
        var ok = 0
        var fails: [String] = []
        for id in ids {
            do {
                try await ReturnsActions.moderate(id: id, approve: approve, note: note)
                ok += 1
            } catch {
                let why = APIError.describe(error)
                fails.append("#" + String(id) + ": " + why)
            }
        }
        bulkBusy = false
        selected = []
        selecting = false
        let word = approve ? "Одобрено: " : "Отклонено: "
        var text = word + String(ok)
        if !fails.isEmpty {
            let head = "\nНе получилось (" + String(fails.count) + "):\n"
            text += head + fails.joined(separator: "\n")
        }
        if fails.isEmpty { Haptics.success() } else { Haptics.warning() }
        refreshAfterAction()
        return text
    }

    private func refreshAfterAction() {
        let m = model
        Task { await m.refresh() }
        Task { await Notifier.shared.refresh(force: true) }
    }

    private var bulkResultShown: Binding<Bool> {
        Binding(get: { bulkResult != nil }, set: { if !$0 { bulkResult = nil } })
    }

    private var paidBinding: Binding<ReturnsRowBox?> {
        Binding(get: { paidRow.map { ReturnsRowBox(row: $0) } },
                set: { paidRow = $0?.row })
    }

    private func openDeepLinkOnce() {
        guard !deepLinkHandled, openId != nil else { return }
        deepLinkHandled = true
        deepLinkShown = true
    }

    /// Статусы — как RET_ST на сайте.
    static let filters: [ListFilter] = [
        ListFilter(key: "status", title: "Статус", options: [
            PickerOption(value: "pending", label: "На рассмотрении"),
            PickerOption(value: "approved", label: "Одобрен, деньги не отданы"),
            PickerOption(value: "rejected", label: "Отклонён"),
            PickerOption(value: "refunded", label: "Возвращён бонусами"),
            PickerOption(value: "closed", label: "Магазин вернул деньги"),
        ]),
    ]
}

/// Отложенное действие после подтверждения.
enum ReturnsPendingOp {
    case approve([Int])
}

/// Список id для листа «Отклонить» (.sheet(item:)).
struct ReturnsIdList: Identifiable {
    let id = UUID()
    let ids: [Int]

    init(ids: [Int]) {
        self.ids = ids
    }
}

/// Строка для .sheet(item:) «Деньги выплачены».
struct ReturnsRowBox: Identifiable {
    let row: JSON
    var id: String { row.stableID }

    init(row: JSON) {
        self.row = row
    }
}

/// Подписи кодов возврата (RET_ST, REASON на сайте).
enum ReturnsLabels {
    static func status(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "pending": return "На рассмотрении"
        case "approved": return "Одобрен, деньги не отданы"
        case "rejected": return "Отклонён"
        case "refunded": return "Возвращён бонусами"
        case "closed": return "Магазин вернул деньги"
        case "": return "—"
        default: return c
        }
    }

    static func color(_ code: String?) -> Color {
        switch code ?? "" {
        case "pending": return Brand.amber
        case "approved": return Brand.blue
        case "rejected": return Brand.red
        case "refunded", "closed": return Brand.green
        default: return Brand.muted
        }
    }

    static func reason(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "wrong_item": return "Не тот товар"
        case "bad_quality": return "Качество"
        case "not_delivered": return "Не доставлен"
        case "changed_mind": return "Передумал"
        case "other": return "Другое"
        case "": return "—"
        default: return c
        }
    }

    static func type(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "full": return "Полный"
        case "partial": return "Частичный"
        case "": return "—"
        default: return c
        }
    }

    static func method(_ code: String?) -> String {
        let c = code ?? ""
        switch c {
        case "bonus": return "Бонусами"
        case "manual": return "Деньгами (возвращает магазин)"
        case "": return "—"
        default: return c
        }
    }

    /// Готовые причины отказа (RET_REASONS на сайте).
    static let rejectReasons = [
        "Истёк срок возврата",
        "Товар использован / повреждён",
        "Брак не подтверждён",
        "Возврат не по правилам площадки",
        "Другое",
    ]
}

/// Плашка статуса возврата.
struct ReturnsStatusBadge: View {
    let status: String?

    init(status: String?) {
        self.status = status
    }

    var body: some View {
        StatusBadge(ReturnsLabels.status(status), color: ReturnsLabels.color(status))
    }
}

/// Запросы раздела «Возвраты» и тексты подтверждений.
enum ReturnsActions {
    static func moderate(id: Int, approve: Bool, note: String?) async throws {
        let path = "/api/admin/returns/" + String(id) + "/moderate"
        if approve {
            try await API.shared.post(path, body: ["decision": "approve"])
        } else {
            try await API.shared.post(path, body: ["decision": "reject", "note": note ?? ""])
        }
    }

    static func markPaid(id: Int, note: String) async throws {
        let path = "/api/admin/returns/" + String(id) + "/paid"
        try await API.shared.post(path, body: ["note": note])
    }

    /// «Выплачено» показывается, как на сайте: деньгами вручную и одобрен/возвращён.
    static func canMarkPaid(_ row: JSON) -> Bool {
        let st = row["status"].string ?? ""
        return row["refund_method"].string == "manual" && (st == "approved" || st == "refunded")
    }

    /// Подтверждение одобрения с суммой (одна заявка или несколько).
    static func approveConfirm(rows: [JSON]) -> ConfirmAction {
        var sum: Decimal = 0
        for r in rows { sum += r["refund_amount"].decimal ?? 0 }
        let note = "Сервер может уменьшить сумму: учтёт уже возвращённое по заказу и потраченный покупателем кешбэк."
        if rows.count == 1, let r = rows.first {
            let num = "Одобрить возврат #" + r["id"].stringValue
            let title = num + " на " + Fmt.money(sum) + "?"
            let how: String
            if r["refund_method"].string == "bonus" {
                how = "Бонусы зачислятся покупателю сразу."
            } else {
                how = "Деньги покупателю возвращает магазин — после выплаты отметьте «Деньги выплачены»."
            }
            return ConfirmAction(title: title, message: how + "\n" + note, confirmLabel: "Одобрить")
        }
        let count = Fmt.plural(rows.count, "возврат", "возврата", "возвратов")
        let title = "Одобрить " + count + " на " + Fmt.money(sum)
        return ConfirmAction(title: title + "?",
                             message: note, confirmLabel: "Одобрить все")
    }
}

/// Сводка над списком: всего возвратов и средняя сумма (stats с сервера).
struct ReturnsStatsHeader: View {
    @ObservedObject var model: PagedListModel

    init(model: PagedListModel) {
        self.model = model
    }

    private var text: String? {
        let stats = model.lastData["stats"]
        guard stats.isObject else { return nil }
        let cnt = Fmt.number(stats["cnt"])
        let avg = Fmt.money(stats["avg_amount"])
        return "Всего возвратов: " + cnt + " · средняя сумма: " + avg
    }

    var body: some View {
        if let t = text {
            Text(t)
                .font(.footnote)
                .foregroundColor(Brand.muted)
                .listRowSeparator(.hidden)
        }
    }
}

/// Строка заявки на возврат.
struct ReturnsRow: View {
    let item: JSON

    init(item: JSON) {
        self.item = item
    }

    private var isStale: Bool {
        item["status"].string == "pending" && item["age_hours"].intValue >= 72
    }

    private var people: String {
        let shop = item["shop"].nonEmptyString ?? "—"
        guard let c = item["client"].nonEmptyString else { return shop }
        return shop + " · " + c
    }

    private var meta: String {
        let reason = ReturnsLabels.reason(item["reason_code"].string)
        let type = ReturnsLabels.type(item["type"].string)
        let date = Fmt.date(item["created_at"])
        return [reason, type, date].joined(separator: " · ")
    }

    private var title: String {
        let ret = "#" + item["id"].stringValue
        // Номер дня заказа — тот, что называет клиент: «заказ №N · #id» (поле с А316).
        if let day = item["order_daily_number"].int, day > 0 {
            return ret + " · заказ №" + String(day) + " · #" + item["order_id"].stringValue
        }
        let order = "заказ #" + item["order_id"].stringValue
        return ret + " · " + order
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                MoneyText(item["refund_amount"])
                    .font(.body.weight(.semibold))
            }
            HStack {
                Text(people)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                ReturnsStatusBadge(status: item["status"].string)
            }
            HStack(spacing: 6) {
                if isStale {
                    StatusBadge("⚠️ 72+ ч", color: Brand.red)
                }
                Text(meta)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Строка в режиме выбора: кружок-отметка (только у заявок на рассмотрении).
struct ReturnsSelectableRow: View {
    let item: JSON
    let isSelected: Bool
    let onTap: () -> Void

    init(item: JSON, isSelected: Bool, onTap: @escaping () -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.onTap = onTap
    }

    private var selectable: Bool { item["status"].string == "pending" }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? Brand.accent : Brand.muted)
                    .opacity(selectable ? 1 : 0.25)
                ReturnsRow(item: item)
            }
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }
}

/// Нижняя панель массовых действий.
struct ReturnsBulkBar: View {
    let count: Int
    let sum: Decimal
    let busy: Bool
    let approve: () -> Void
    let reject: () -> Void

    init(count: Int, sum: Decimal, busy: Bool, approve: @escaping () -> Void, reject: @escaping () -> Void) {
        self.count = count
        self.sum = sum
        self.busy = busy
        self.approve = approve
        self.reject = reject
    }

    private var caption: String {
        if count == 0 { return "Отметьте заявки на рассмотрении" }
        return "Выбрано: " + String(count) + " · " + Fmt.money(sum)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(caption)
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                Spacer()
                if busy { ProgressView() }
            }
            HStack(spacing: 10) {
                Button(role: .destructive, action: reject) {
                    Text("Отклонить").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: approve) {
                    Text("Одобрить").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
            }
            .disabled(count == 0 || busy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Лист «Отклонить возврат»: готовые причины (как pickReason на сайте) и свой комментарий.
/// На сервер уходит свой комментарий, а если он пуст — выбранная причина.
struct ReturnsRejectSheet: View {
    let count: Int
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preset = ReturnsLabels.rejectReasons[0]
    @State private var custom = ""
    @State private var busy = false
    @State private var error: String?

    init(count: Int, onSubmit: @escaping (String) async throws -> Void) {
        self.count = count
        self.onSubmit = onSubmit
    }

    private var title: String {
        count > 1 ? "Отклонить " + Fmt.plural(count, "возврат", "возврата", "возвратов") : "Отклонить возврат"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Причина") {
                    ForEach(ReturnsLabels.rejectReasons, id: \.self) { r in
                        Button {
                            preset = r
                        } label: {
                            HStack {
                                Text(r).foregroundColor(Brand.text)
                                Spacer()
                                if preset == r {
                                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                                }
                            }
                        }
                    }
                }
                Section {
                    TextField("уточнение…", text: $custom, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Свой комментарий (необязательно)")
                } footer: {
                    Text("Покупатель увидит причину в уведомлении. Свой комментарий заменяет выбранную причину.")
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                Section {
                    Button(role: .destructive) {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Отклонить").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private func submit() {
        guard !busy else { return }
        let c = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = c.isEmpty ? preset : c
        busy = true
        error = nil
        let send = onSubmit
        Task { @MainActor in
            do {
                try await send(note)
                busy = false
                dismiss()
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

/// Лист «Деньги выплачены»: подтверждение с суммой и необязательная заметка.
struct ReturnsPaidSheet: View {
    let row: JSON
    let onSubmit: (String) async throws -> Void

    init(row: JSON, onSubmit: @escaping (String) async throws -> Void) {
        self.row = row
        self.onSubmit = onSubmit
    }

    private var amount: String { Fmt.money(row["refund_amount"]) }

    private var message: String {
        let head = "Подтвердите, что покупателю выплачено " + amount
        let tail = " по возврату #" + row["id"].stringValue + ". Заявка закроется."
        return head + tail
    }

    var body: some View {
        TextInputSheet(title: "Деньги выплачены",
                       message: message,
                       placeholder: "Заметка (необязательно)",
                       submitTitle: "Подтвердить выплату " + amount,
                       minLength: 0) { note in
            try await onSubmit(note)
        }
    }
}
