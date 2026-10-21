import SwiftUI

/// Подписи вкладок «Проблемы» и «Жалобы» раздела «Курьеры».
enum CourierIssuesFormat {
    /// pool_problems.status.
    static func problemStatus(_ s: String?) -> String {
        switch s ?? "" {
        case "open": return "Открыта"
        case "upheld": return "Возмещение оставлено"
        case "voided": return "Снято с курьера"
        default: return Fmt.statusLabel(s)
        }
    }

    static func problemColor(_ s: String?) -> Color {
        switch s ?? "" {
        case "open": return Brand.amber
        case "upheld": return Brand.red
        case "voided": return Brand.green
        default: return Brand.muted
        }
    }

    /// Решение по жалобе (CourierPool::COMPLAINT_RESOLUTIONS) — кнопка.
    static func actionTitle(_ a: String) -> String {
        switch a {
        case "block": return "Заблокировать курьера"
        case "warn": return "Предупредить"
        case "close_call": return "Закрыть вызов"
        case "resolve": return "Разобрано"
        case "dismiss": return "Не подтвердилась"
        default: return a
        }
    }

    /// Что произойдёт — пояснение в листе решения.
    static func actionMessage(_ a: String) -> String {
        switch a {
        case "block": return "Курьер будет заблокирован и увидит причину. Жалоба закроется."
        case "warn": return "Тому, на кого пожаловались, придёт уведомление-предупреждение с этим текстом. Номера вызова в нём нет."
        case "close_call": return "Живой вызов закроется; отправителю и курьеру придёт нейтральная причина «нарушение правил сервиса»."
        case "resolve": return "Жалоба закроется без мер."
        case "dismiss": return "Жалоба закроется как не подтвердившаяся."
        default: return ""
        }
    }
}

/// Цель листа решения (для `.sheet(item:)`).
struct CourierIssueTarget: Identifiable {
    let id = UUID()
    /// id проблемы или жалобы.
    let itemId: Int
    /// Действие для сервера (uphold/void или dismiss/warn/block/close_call/resolve).
    let action: String
    /// Заготовка текста (для блокировки и предупреждения).
    let suggestion: String?
}

// MARK: - Проблемы с доставкой

/// Вкладка «Проблемы»: GET /api/admin/pool/problems?status=open|upheld|voided|all
/// (CourierPool::adminProblems, data = массив, meta {page, total});
/// решение POST /api/admin/pool/problems/{id}/resolve {action: uphold|void, note}.
/// uphold — возмещение остаётся долгом курьера, void — снимаем запись с курьера.
struct CourierProblemsScreen: View {
    @ObservedObject var model: PagedListModel
    @ObservedObject var summary: ObjectLoader
    /// Модель вкладки «Курьеры»: блокировка или решение в карточке курьера меняет его строку.
    /// Вкладка сейчас не на экране — обновлять её сразу безопасно.
    let couriers: PagedListModel
    @State private var target: CourierIssueTarget?

    init(model: PagedListModel, summary: ObjectLoader, couriers: PagedListModel) {
        self.model = model
        self.summary = summary
        self.couriers = couriers
    }

    private var statusBinding: Binding<String> {
        Binding(get: { model.filter("status") ?? "open" },
                set: { model.setFilter("status", $0) })
    }

    var body: some View {
        List {
            Picker("Статус", selection: statusBinding) {
                Text("Открытые").tag("open")
                Text("Оставлено").tag("upheld")
                Text("Снято").tag("voided")
                Text("Все").tag("all")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            stateContent
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AdminSection.couriers.title)
        .refreshable {
            await model.refresh()
            await summary.load()
        }
        .task { await model.loadIfNeeded() }
        .sheet(item: $target) { t in
            resolveSheet(t)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.reload() })
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .empty:
            EmptyStateView(title: (model.filter("status") ?? "open") == "open" ? "Открытых проблем нет" : "Проблем нет",
                           systemImage: "checkmark.circle")
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(model.items, id: \.stableID) { p in
                CourierProblemCard(problem: p, onCourierChanged: { courierChanged() }) { action in
                    target = CourierIssueTarget(itemId: p.id ?? 0, action: action, suggestion: nil)
                }
                .task { await model.loadMoreIfNeeded(current: p) }
            }
            ListFooter(model: model)
        }
    }

    private func resolveSheet(_ t: CourierIssueTarget) -> some View {
        let uphold = t.action == "uphold"
        let title = uphold ? "Оставить возмещение" : "Снять с курьера"
        let message = uphold
            ? "Сумма возмещения остаётся долгом курьера перед заведением. Курьеру придёт уведомление."
            : "Запись о возмещении снимется с курьера, его долг уменьшится. Курьеру придёт уведомление."
        return CourierReasonSheet(title: title, message: message, placeholder: "Комментарий — курьер увидит",
                                  submitTitle: title, allowEmpty: true, destructive: uphold,
                                  confirm: ConfirmAction(title: title + "?",
                                                         message: "Решение по проблеме изменить будет нельзя.",
                                                         confirmLabel: title, destructive: uphold)) { note in
            let res: JSON
            do {
                res = try await API.shared.post("/api/admin/pool/problems/" + String(t.itemId) + "/resolve",
                                                body: ["action": t.action, "note": note])
            } catch {
                // 409 «Уже рассмотрено» — решил другой администратор: показываем свежий список.
                if let e = error as? APIError, e.status == 409 { reloadAfterConflict() }
                throw error
            }
            resolved(res, id: t.itemId)
        }
    }

    /// Ответ 409: запись уже решил другой администратор.
    private func reloadAfterConflict() {
        Task {
            await model.refresh()
            await summary.load()
        }
    }

    /// Изменился курьер (блокировка, решение в его карточке) — обновить вкладку «Курьеры»,
    /// если её уже загружали (сейчас она не на экране, карточки из неё не открыты).
    private func courierChanged() {
        guard couriers.state != .idle else { return }
        Task {
            await couriers.refresh()
            await summary.load()
        }
    }

    /// Ответ — проблема целиком (problemView): в «Открытых» убираем, в остальных — заменяем.
    private func resolved(_ res: JSON, id: Int) {
        if (model.filter("status") ?? "open") == "open" || res.id == nil {
            model.remove(id: id)
        } else {
            model.replace(res)
        }
        Task {
            await summary.load()
            await Notifier.shared.refresh(force: true)
        }
    }
}

/// Карточка проблемы: причина, заведение → курьер, сумма, фото, решение.
struct CourierProblemCard: View {
    let problem: JSON
    /// В карточке курьера что-то изменили.
    let onCourierChanged: () -> Void
    let onResolve: (String) -> Void

    @State private var viewed: CourierPhoto?

    init(problem: JSON, onCourierChanged: @escaping () -> Void, onResolve: @escaping (String) -> Void) {
        self.problem = problem
        self.onCourierChanged = onCourierChanged
        self.onResolve = onResolve
    }

    private var pid: Int { problem.id ?? 0 }
    private var isOpen: Bool { problem["status"].stringValue == "open" }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(problem["reason_label"].nonEmptyString ?? "Проблема")
                        .font(.body.weight(.semibold))
                    Spacer(minLength: 6)
                    StatusBadge(CourierIssuesFormat.problemStatus(problem["status"].string),
                                color: CourierIssuesFormat.problemColor(problem["status"].string))
                }
                Text(problem["shop"].stringValue + " → курьер " + problem["courier"].stringValue)
                    .font(.subheadline)
                Text("Доставка №" + problem["call_id"].stringValue + " · " + Fmt.date(problem["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if let t = problem["comment"].nonEmptyString {
                    Text(t)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                Text("Возмещение: " + Fmt.money(problem["amount"]))
                    .font(.subheadline.weight(.semibold))
                if let n = problem["resolution_note"].nonEmptyString {
                    Text("Решение: " + n)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            .padding(.vertical, 2)
            if problem["has_photo"].boolValue {
                CourierDocThumb(path: "/api/admin/pool/problems/" + String(pid) + "/photo", version: "",
                                title: "Фото от заведения", available: true, height: 160) { p in viewed = p }
                    .fullScreenCover(item: $viewed) { p in
                        CourierPhotoViewer(photo: p)
                    }
            }
            if let cid = problem["courier_id"].int, cid > 0 {
                NavigationLink(destination: CourierDetailView(id: cid, onChanged: onCourierChanged)) {
                    Label("Карточка курьера", systemImage: "person.text.rectangle")
                }
            }
            if isOpen {
                HStack(spacing: 10) {
                    Button {
                        onResolve("uphold")
                    } label: {
                        Text("Оставить возмещение").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        onResolve("void")
                    } label: {
                        Text("Снять с курьера").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Жалобы

/// Вкладка «Жалобы»: GET /api/admin/pool/complaints?status=open|closed|all
/// (CourierPool::adminComplaints: открытые и «пассажиры» — первыми);
/// решение POST /api/admin/pool/complaints/{id}/resolve {action: dismiss|warn|block|close_call|resolve, note}.
/// block — только для жалобы на курьера; close_call — только пока вызов идёт.
struct CourierComplaintsScreen: View {
    @ObservedObject var model: PagedListModel
    @ObservedObject var summary: ObjectLoader
    /// Модель вкладки «Курьеры»: блокировка или решение в карточке курьера меняет его строку.
    /// Вкладка сейчас не на экране — обновлять её сразу безопасно.
    let couriers: PagedListModel
    @State private var target: CourierIssueTarget?

    init(model: PagedListModel, summary: ObjectLoader, couriers: PagedListModel) {
        self.model = model
        self.summary = summary
        self.couriers = couriers
    }

    private var statusBinding: Binding<String> {
        Binding(get: { model.filter("status") ?? "open" },
                set: { model.setFilter("status", $0) })
    }

    var body: some View {
        List {
            Picker("Статус", selection: statusBinding) {
                Text("Открытые").tag("open")
                Text("Рассмотренные").tag("closed")
                Text("Все").tag("all")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            InfoBanner("Сервис только для грузов и посылок — пассажиров курьеры не перевозят (закон о такси). Жалобу «пассажиры» на курьера разберите первой: подтвердилась — заблокируйте.",
                       systemImage: "exclamationmark.shield", color: Brand.amber)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            stateContent
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AdminSection.couriers.title)
        .refreshable {
            await model.refresh()
            await summary.load()
        }
        .task { await model.loadIfNeeded() }
        .sheet(item: $target) { t in
            resolveSheet(t)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .idle, .loading:
            HStack { Spacer(); ProgressView("Загрузка…"); Spacer() }
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: { await model.reload() })
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .empty:
            EmptyStateView(title: (model.filter("status") ?? "open") == "open" ? "Открытых жалоб нет" : "Жалоб нет",
                           systemImage: "checkmark.circle")
                .frame(minHeight: 260)
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(model.items, id: \.stableID) { x in
                CourierComplaintCard(complaint: x, onCourierChanged: { courierChanged() }) { action in
                    target = CourierIssueTarget(itemId: x.id ?? 0, action: action,
                                                suggestion: CourierComplaintsScreen.suggestion(x, action))
                }
                .task { await model.loadMoreIfNeeded(current: x) }
            }
            ListFooter(model: model)
        }
    }

    /// Заготовка текста для блокировки и предупреждения (как admin-pool.js).
    static func suggestion(_ x: JSON, _ action: String) -> String? {
        guard action == "block" || action == "warn" else { return nil }
        if x["reason"].stringValue == "passenger" {
            return "Нарушение правил: сервис только для грузов и посылок, пассажиров не перевозим"
        }
        return "Нарушение правил: " + x["reason_label"].stringValue.lowercased()
    }

    private func resolveSheet(_ t: CourierIssueTarget) -> some View {
        let title = CourierIssuesFormat.actionTitle(t.action)
        let danger = t.action == "block" || t.action == "close_call"
        let reasons: [String] = t.suggestion.map { [$0] } ?? []
        return CourierReasonSheet(title: title, message: CourierIssuesFormat.actionMessage(t.action),
                                  reasons: reasons,
                                  placeholder: t.action == "warn" ? "Текст предупреждения" : "Комментарий",
                                  initial: t.suggestion ?? "",
                                  submitTitle: title, allowEmpty: true, destructive: danger,
                                  confirm: ConfirmAction(title: title + "?",
                                                         message: "Жалоба закроется, решение изменить будет нельзя.",
                                                         confirmLabel: title, destructive: danger)) { note in
            let res: JSON
            do {
                res = try await API.shared.post("/api/admin/pool/complaints/" + String(t.itemId) + "/resolve",
                                                body: ["action": t.action, "note": note])
            } catch {
                // 409 «Жалоба уже рассмотрена» / «Вызов уже закрыт» — показываем свежий список.
                if let e = error as? APIError, e.status == 409 { reloadAfterConflict() }
                throw error
            }
            resolved(res, id: t.itemId)
            // Блокировка из жалобы меняет статус курьера — строка во вкладке «Курьеры» устарела.
            if t.action == "block" { courierChanged() }
        }
    }

    /// Ответ 409: жалобу уже решил другой администратор (или вызов уже закрыт).
    private func reloadAfterConflict() {
        Task {
            await model.refresh()
            await summary.load()
        }
    }

    /// Изменился курьер (блокировка, решение в его карточке) — обновить вкладку «Курьеры»,
    /// если её уже загружали (сейчас она не на экране, карточки из неё не открыты).
    private func courierChanged() {
        guard couriers.state != .idle else { return }
        Task {
            await couriers.refresh()
            await summary.load()
        }
    }

    /// Ответ — жалоба целиком (complaintView): в «Открытых» убираем, иначе заменяем.
    private func resolved(_ res: JSON, id: Int) {
        if (model.filter("status") ?? "open") == "open" || res.id == nil {
            model.remove(id: id)
        } else {
            model.replace(res)
        }
        Task {
            await summary.load()
            await Notifier.shared.refresh(force: true)
        }
    }
}

/// Карточка жалобы: причина, кто на кого, вызов, текст, решение и кнопки.
struct CourierComplaintCard: View {
    let complaint: JSON
    /// В карточке курьера что-то изменили.
    let onCourierChanged: () -> Void
    let onResolve: (String) -> Void

    init(complaint: JSON, onCourierChanged: @escaping () -> Void, onResolve: @escaping (String) -> Void) {
        self.complaint = complaint
        self.onCourierChanged = onCourierChanged
        self.onResolve = onResolve
    }

    private var isOpen: Bool { complaint["status"].stringValue == "open" }
    private var passenger: Bool { complaint["reason"].stringValue == "passenger" }
    private var againstCourier: Bool { complaint["against"].stringValue == "courier" }
    private var courier: JSON { complaint["courier"] }

    /// Доступные решения (как кнопки admin-pool.js).
    private var actions: [String] {
        var out: [String] = []
        if againstCourier && courier.isObject && courier["status"].stringValue != "blocked" { out.append("block") }
        out.append("warn")
        if complaint["call_live"].boolValue { out.append("close_call") }
        out.append("resolve")
        out.append("dismiss")
        return out
    }

    private var callLine: String {
        var parts: [String] = [complaint["call_title"].nonEmptyString ?? ("Вызов №" + complaint["call_id"].stringValue)]
        if complaint["call_live"].boolValue { parts.append("вызов ещё идёт") }
        parts.append(Fmt.date(complaint["created_at"]))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text((passenger ? "⚠️ " : "") + (complaint["reason_label"].nonEmptyString ?? "Жалоба"))
                        .font(.body.weight(.semibold))
                        .foregroundColor(passenger && isOpen ? Brand.red : Brand.text)
                    Spacer(minLength: 6)
                    StatusBadge(isOpen ? "Открыта" : (complaint["resolution_label"].nonEmptyString ?? "Рассмотрена"),
                                color: isOpen ? Brand.amber : Brand.green)
                }
                Text(complaint["author_label"].stringValue + " → на " + (againstCourier ? "курьера" : "отправителя")
                     + ": " + complaint["against_label"].stringValue)
                    .font(.subheadline)
                Text(callLine)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if let t = complaint["comment"].nonEmptyString {
                    Text(t)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                if let n = complaint["resolution_note"].nonEmptyString {
                    Text("Решение: " + n)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            .padding(.vertical, 2)
            links
            if isOpen {
                Menu {
                    ForEach(actions, id: \.self) { a in
                        Button(role: a == "block" ? .destructive : nil) {
                            onResolve(a)
                        } label: {
                            Text(CourierIssuesFormat.actionTitle(a))
                        }
                    }
                } label: {
                    Label("Решение по жалобе", systemImage: "checkmark.seal")
                }
            }
        }
    }

    @ViewBuilder
    private var links: some View {
        if let cid = courier["user_id"].int, cid > 0 {
            NavigationLink(destination: CourierDetailView(id: cid, onChanged: onCourierChanged)) {
                Label("Курьер: " + courier["name"].stringValue + " · " + courier["status_label"].stringValue,
                      systemImage: "person.text.rectangle")
            }
        }
        if let phone = complaint["client"]["phone"].nonEmptyString, let url = Fmt.phoneURL(phone) {
            Link(destination: url) {
                Label("Отправитель: " + Fmt.phone(phone), systemImage: "phone")
            }
        }
        if let sid = complaint["shop_id"].int, sid > 0 {
            NavigationLink(destination: ShopDetailView(id: sid)) {
                Label("Заведение: " + complaint["shop"].stringValue, systemImage: "building.2")
            }
        }
    }
}
