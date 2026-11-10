import SwiftUI
import UIKit

// MARK: - Предпросмотр

/// Ответ POST /api/admin/app-notify/preview (поля необязательны — старый/новый сервер).
struct AppsNotifyPreview {
    let kind: String
    let recipients: Int
    let skippedRecent: Int
    let noChannel: Int
    let byPlatform: [AppsCountRow]
    let defaultTitle: String
    let defaultBody: String
    let latestVersion: String?
    let storeURL: String?
    let storeMissing: Bool

    init(_ j: JSON) {
        kind = j["kind"].stringValue
        recipients = j["recipients"].intValue
        skippedRecent = j["skipped_recent"].intValue
        noChannel = j["no_channel"].intValue
        var rows: [AppsCountRow] = []
        for (i, r) in j["by_platform"].array.enumerated() {
            let p = r["platform"].stringValue
            if p.isEmpty { continue }
            rows.append(AppsCountRow(id: i, platform: p, label: AppsFmt.platformTitle(p), count: r["count"].intValue))
        }
        byPlatform = rows
        defaultTitle = j["default_title"].stringValue
        defaultBody = j["default_body"].stringValue
        latestVersion = j["latest_version"].nonEmptyString
        storeURL = j["store_url"].nonEmptyString
        storeMissing = j["store_missing"].boolValue
    }
}

/// Зафиксированная на время отправки рассылка: параметры и текст не меняются между пачками,
/// `guardKey` один на запуск и переживает повторы (сервер по нему не шлёт пачку второй раз).
struct AppsNotifyJob {
    let kind: String
    let app: String
    let platform: String
    let only: String
    let title: String
    let body: String
    let guardKey: String

    func sendBody(after: Int) -> [String: Any?] {
        var b: [String: Any?] = ["kind": kind, "guard_key": guardKey, "after": after]
        if kind == "update" {
            b["app"] = app
            b["platform"] = platform
            b["only"] = only
        }
        // Пустой текст не отправляем вовсе: сервер подставит текст по умолчанию.
        if !title.isEmpty { b["title"] = title }
        if !body.isEmpty { b["body"] = body }
        return b
    }
}

/// Чем закончилась отправка.
enum AppsNotifyOutcome: Equatable {
    case finished
    case stopped
    case failed(message: String, retryable: Bool)
}

// MARK: - Модель

@MainActor
final class AppsNotifyModel: ObservableObject {
    static let titleLimit = 80
    static let bodyLimit = 240
    /// Пачка — 100 клиентов; 5000 пачек = 500 000 клиентов, дальше считаем это зависанием.
    static let maxBatches = 5000

    static let appOptions: [PickerOption] = [
        PickerOption(value: "client", label: "Покупатель"),
        PickerOption(value: "seller", label: "Продавец"),
        PickerOption(value: "courier", label: "Курьер"),
    ]
    static let platformOptions: [PickerOption] = [
        PickerOption(value: "all", label: "Все платформы"),
        PickerOption(value: "android", label: "Android"),
        PickerOption(value: "ios", label: "iOS"),
    ]
    static let onlyOptions: [PickerOption] = [
        PickerOption(value: "outdated", label: "Все устаревшие"),
        PickerOption(value: "below_min", label: "Только ниже минимальной"),
    ]

    // Параметры рассылки. Меняются только когда нет отправки и нет незавершённого запуска.
    @Published var kind: String = "update" {
        didSet { if kind != oldValue { textEdited = false; inputsChanged() } }
    }
    @Published var app: String = "client" {
        didSet { if app != oldValue { textEdited = false; inputsChanged() } }
    }
    @Published var platform: String = "all" {
        didSet { if platform != oldValue { inputsChanged() } }
    }
    @Published var only: String = "outdated" {
        didSet { if only != oldValue { inputsChanged() } }
    }

    @Published private(set) var title = ""
    @Published private(set) var body = ""

    @Published private(set) var preview: AppsNotifyPreview?
    @Published private(set) var previewLoading = false
    @Published private(set) var previewError: String?

    // Отправка.
    @Published private(set) var sending = false
    @Published private(set) var batches = 0
    @Published private(set) var sent = 0
    @Published private(set) var skipped = 0
    @Published private(set) var failed = 0
    @Published private(set) var total = 0
    @Published private(set) var stopRequested = false
    @Published private(set) var outcome: AppsNotifyOutcome?
    /// Незавершённый запуск (остановлен или оборвался): продолжается тем же guard_key с того же курсора.
    @Published private(set) var pendingJob: AppsNotifyJob?
    @Published private(set) var pendingAfter = 0

    private var textEdited = false
    private var previewGen = 0
    private var previewTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    /// Параметры закреплены (идёт отправка или есть незавершённый запуск).
    var locked: Bool { sending || pendingJob != nil }

    var isUpdate: Bool { kind == "update" }

    // MARK: Текст

    func setTitle(_ v: String) {
        textEdited = true
        title = String(v.prefix(AppsNotifyModel.titleLimit))
    }

    func setBody(_ v: String) {
        textEdited = true
        body = String(v.prefix(AppsNotifyModel.bodyLimit))
    }

    /// Вернуть тексты по умолчанию из предпросмотра.
    func resetText() {
        guard let p = preview else { return }
        textEdited = false
        title = String(p.defaultTitle.prefix(AppsNotifyModel.titleLimit))
        body = String(p.defaultBody.prefix(AppsNotifyModel.bodyLimit))
    }

    // MARK: Предпросмотр

    func loadPreviewIfNeeded() {
        if preview == nil && !previewLoading && previewError == nil { startPreview() }
    }

    private func inputsChanged() {
        if locked { return }
        startPreview()
    }

    private func previewBody() -> [String: Any?] {
        var b: [String: Any?] = ["kind": kind]
        if kind == "update" {
            b["app"] = app
            b["platform"] = platform
            b["only"] = only
        }
        return b
    }

    /// Пересчитать и дождаться ответа (для pull-to-refresh).
    func refreshPreview() async {
        let t = startPreview()
        await t.value
    }

    /// Запустить пересчёт, не дожидаясь.
    @discardableResult
    func startPreview() -> Task<Void, Never> {
        previewTask?.cancel()
        previewGen += 1
        let gen = previewGen
        preview = nil
        previewError = nil
        previewLoading = true
        let b = previewBody()
        let task = Task { await self.fetchPreview(gen, b) }
        previewTask = task
        return task
    }

    private func fetchPreview(_ gen: Int, _ body: [String: Any?]) async {
        do {
            let d = try await API.shared.post("/api/admin/app-notify/preview", body: body)
            guard gen == previewGen else { return }
            let p = AppsNotifyPreview(d)
            preview = p
            previewLoading = false
            if !textEdited || (title.isEmpty && self.body.isEmpty) {
                title = String(p.defaultTitle.prefix(AppsNotifyModel.titleLimit))
                self.body = String(p.defaultBody.prefix(AppsNotifyModel.bodyLimit))
            }
        } catch {
            guard gen == previewGen, !APIError.isCancellation(error) else { return }
            previewError = AppsFmt.errorText(error)
            previewLoading = false
        }
    }

    // MARK: Отправка

    /// Можно ли нажимать «Отправить».
    var canSend: Bool {
        guard let p = preview, !sending, pendingJob == nil, !previewLoading else { return false }
        if p.recipients <= 0 { return false }
        if isUpdate && p.storeMissing { return false }
        return true
    }

    /// Новый запуск: один guard_key на весь запуск.
    func start() {
        guard canSend, !sending else { return }
        let key = "adm-app-" + UUID().uuidString.lowercased()
        // Текст уходит только если администратор его изменил: при платформе «все» сервер сам
        // подставляет текст под платформу клиента (iPhone не получит версию Android).
        let ws = CharacterSet.whitespacesAndNewlines
        let curTitle = title.trimmingCharacters(in: ws)
        let curBody = body.trimmingCharacters(in: ws)
        let defTitle = (preview?.defaultTitle ?? "").trimmingCharacters(in: ws)
        let defBody = (preview?.defaultBody ?? "").trimmingCharacters(in: ws)
        let job = AppsNotifyJob(kind: kind, app: app, platform: platform, only: only,
                                title: curTitle == defTitle ? "" : curTitle,
                                body: curBody == defBody ? "" : curBody,
                                guardKey: key)
        sent = 0
        skipped = 0
        failed = 0
        total = preview?.recipients ?? 0
        batches = 0
        launch(job, from: 0)
    }

    /// Продолжить остановленный или оборвавшийся запуск тем же guard_key с того же курсора.
    func resume() {
        guard let job = pendingJob, !sending else { return }
        launch(job, from: pendingAfter)
    }

    /// Остановить: следующие пачки не пойдут. Пачка, которая уже отправляется, дойдёт до конца.
    func requestStop() {
        guard sending else { return }
        stopRequested = true
    }

    /// Закрыть итог и сбросить незавершённый запуск (следующий получит новый guard_key).
    func dismissOutcome() {
        guard !sending else { return }
        outcome = nil
        pendingJob = nil
        pendingAfter = 0
        startPreview()
    }

    private func launch(_ job: AppsNotifyJob, from cursor: Int) {
        sending = true
        stopRequested = false
        outcome = nil
        pendingJob = nil
        sendTask = Task { await self.run(job, from: cursor) }
    }

    private func run(_ job: AppsNotifyJob, from cursor: Int) async {
        UIApplication.shared.isIdleTimerDisabled = true
        var after = cursor
        var result: AppsNotifyOutcome = .finished
        var round = 0
        loop: while true {
            round += 1
            if round > AppsNotifyModel.maxBatches {
                result = .failed(message: "Слишком много пачек подряд — отправка прервана.", retryable: false)
                break loop
            }
            if stopRequested {
                result = .stopped
                break loop
            }
            do {
                let r = try await API.shared.post("/api/admin/app-notify/send", body: job.sendBody(after: after),
                                                  timeout: 120)
                sent += r["sent"].intValue
                skipped += r["skipped"].intValue
                failed += r["failed"].intValue
                if let t = r["total"].int, t > 0 { total = t }
                batches += 1
                if r["done"].boolValue {
                    result = .finished
                    break loop
                }
                guard let next = r["next_after"].int, next > after else {
                    // Курсор не сдвинулся: повтор зациклился бы и дублировал нагрузку на сервер.
                    result = .failed(message: "Сервер не вернул следующий курсор — отправка остановлена, чтобы не зациклиться.",
                                     retryable: false)
                    break loop
                }
                after = next
            } catch {
                let e = API.mapTransport(error)
                let text = e == .cancelled ? "Отправка прервана." : AppsFmt.errorText(e)
                // Ответа нет или сервер занят — пачка могла уйти, повтор с тем же guard_key безопасен.
                let st = e.status
                // 409 «guard_key уже занят другой рассылкой» повторять нельзя (зациклится);
                // 409 «Эта пачка уже отправляется» — можно, подождав.
                let busyHit = st == 409 && text.contains("уже отправляется")
                let retryable = busyHit || st == 408 || st == 429 || !(st >= 400 && st < 500)
                result = .failed(message: text, retryable: retryable)
                break loop
            }
        }
        UIApplication.shared.isIdleTimerDisabled = false
        outcome = result
        switch result {
        case .finished:
            Haptics.success()
            pendingJob = nil
            pendingAfter = 0
        case .stopped:
            Haptics.warning()
            pendingJob = job
            pendingAfter = after
        case .failed(_, let retryable):
            Haptics.error()
            pendingJob = retryable ? job : nil
            pendingAfter = after
        }
        sending = false
        stopRequested = false
        if pendingJob == nil { startPreview() }
    }
}

// MARK: - Экран

/// Вкладка «Уведомить».
struct AppsNotifyView: View {
    @ObservedObject var model: AppsNotifyModel

    var body: some View {
        Form {
            kindSection
            if model.isUpdate {
                targetSection
            }
            recipientsSection
            messageSection
            sendSection
            progressSection
        }
        .task { model.loadPreviewIfNeeded() }
        .refreshable { await model.refreshPreview() }
    }

    // MARK: Секции

    private var kindSection: some View {
        Section {
            Picker("Тип уведомления", selection: $model.kind) {
                Text("Обновить приложение").tag("update")
                Text("Установить приложение").tag("install")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(model.locked)
        } header: {
            Text("Что отправить")
        } footer: {
            if model.isUpdate {
                Text("Служебное сообщение без акций: получат клиенты, у которых на выбранной платформе устаревшая версия. Тот же клиент не получает его чаще раза в 7 дней.")
            } else {
                Text("Реклама приложения для клиентов без него: получат активные клиенты, не отключившие уведомления о новых магазинах. Раз в 7 дней на клиента.")
            }
        }
    }

    private var targetSection: some View {
        Section("Кому") {
            Picker("Приложение", selection: $model.app) {
                ForEach(AppsNotifyModel.appOptions) { o in Text(o.label).tag(o.value) }
            }
            Picker("Платформа", selection: $model.platform) {
                ForEach(AppsNotifyModel.platformOptions) { o in Text(o.label).tag(o.value) }
            }
            Picker("Версии", selection: $model.only) {
                ForEach(AppsNotifyModel.onlyOptions) { o in Text(o.label).tag(o.value) }
            }
        }
        .disabled(model.locked)
    }

    @ViewBuilder
    private var recipientsSection: some View {
        Section("Получатели") {
            if model.previewLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Считаем получателей…")
                }
            } else if let e = model.previewError {
                ErrorBanner(message: e, retry: { model.startPreview() })
            } else if let p = model.preview {
                previewRows(p)
            }
        }
    }

    @ViewBuilder
    private func previewRows(_ p: AppsNotifyPreview) -> some View {
        HStack {
            Text(Fmt.plural(p.recipients, "получатель", "получателя", "получателей"))
                .font(.headline)
                .monospacedDigit()
            Spacer()
        }
        if p.skippedRecent > 0 {
            KVRow("Уже получали за 7 дней", AppsFmt.num(p.skippedRecent))
        }
        ForEach(p.byPlatform) { row in
            KVRow(row.label, AppsFmt.num(row.count))
        }
        if let v = p.latestVersion, model.isUpdate {
            KVRow("Последняя версия", v)
        }
        if model.isUpdate && p.storeMissing {
            ErrorBanner(message: "Нет версии приложения или ссылки на магазин — уведомление об обновлении отправить нельзя. Заполните их в настройках сайта и обновите расчёт.",
                        retry: { model.startPreview() })
        }
        if p.noChannel > 0 {
            InfoBanner(noChannelText(p), systemImage: "exclamationmark.triangle.fill", color: Brand.amber)
        }
        if p.recipients == 0 && !p.storeMissing {
            Text("Подходящих получателей сейчас нет.")
                .font(.footnote)
                .foregroundColor(Brand.muted)
        }
    }

    private func noChannelText(_ p: AppsNotifyPreview) -> String {
        let n = Fmt.plural(p.noChannel, "клиент", "клиента", "клиентов")
        if model.isUpdate {
            return n + " без канала доставки: push до них не дойдёт."
        }
        return n + " без web-push: увидят уведомление только при входе на сайт."
    }

    private var messageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("Заголовок")
                TextField("Заголовок", text: Binding(get: { model.title }, set: { model.setTitle($0) }))
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("Текст")
                TextEditor(text: Binding(get: { model.body }, set: { model.setBody($0) }))
                    .frame(minHeight: 100)
            }
            if model.preview != nil {
                Button("Вернуть текст по умолчанию") { model.resetText() }
            }
            sample
        } header: {
            Text("Сообщение")
        } footer: {
            Text(limitsText)
        }
        .disabled(model.locked)
    }

    /// Счётчики длины. Отдельным свойством с интерполяцией: длинная цепочка «+»
    /// внутри Text(...) не укладывается в лимит проверки типов Swift (Xcode 26).
    private var limitsText: String {
        let t = "\(model.title.count) / \(AppsNotifyModel.titleLimit)"
        let b = "\(model.body.count) / \(AppsNotifyModel.bodyLimit)"
        return "Заголовок: \(t), текст: \(b). Пустой текст заменится текстом по умолчанию."
    }

    @ViewBuilder
    private var sample: some View {
        if !model.title.isEmpty || !model.body.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title.isEmpty ? "Yumurta" : model.title)
                    .font(.subheadline.weight(.semibold))
                Text(model.body)
                    .font(.subheadline)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.chip)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityHint("Так увидит клиент")
        }
    }

    private var sendSection: some View {
        Section {
            ActionButton("Отправить", systemImage: "paperplane.fill", style: .prominent,
                         confirm: confirmAction, fullWidth: true) {
                model.start()
            }
            .disabled(!model.canSend)
        } footer: {
            if model.pendingJob != nil {
                Text("Есть незавершённая отправка — продолжите её или закройте итог ниже.")
            } else if let p = model.preview, p.recipients == 0 {
                Text("Нет получателей.")
            }
        }
    }

    private var confirmAction: ConfirmAction {
        let kindText = model.isUpdate ? "Обновить приложение" : "Установить приложение"
        var message = kindText
        if model.isUpdate {
            message += ": " + AppsFmt.appTitle(model.app) + ", " + AppsFmt.platformTitle(model.platform)
        }
        if let p = model.preview {
            message += ". Получателей: " + Fmt.number(p.recipients)
        }
        message += ". Отправленные уведомления отозвать нельзя."
        return ConfirmAction(title: "Отправить уведомление?", message: message, confirmLabel: "Отправить")
    }

    @ViewBuilder
    private var progressSection: some View {
        if model.sending {
            Section("Отправка") {
                if model.total > 0 {
                    ProgressView(value: min(1.0, Double(model.sent + model.skipped + model.failed) / Double(model.total)))
                } else {
                    ProgressView()
                }
                counters
                Text(model.stopRequested
                     ? "Остановится после текущей пачки…"
                     : "Пачек: " + String(model.batches) + ". Не закрывайте приложение до конца отправки.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                Button(role: .destructive) {
                    model.requestStop()
                } label: {
                    Label("Остановить отправку", systemImage: "stop.circle")
                }
                .disabled(model.stopRequested)
            }
        } else if let o = model.outcome {
            Section("Итог") {
                outcomeRows(o)
            }
        }
    }

    private var counters: some View {
        VStack(alignment: .leading, spacing: 6) {
            KVRow("Отправлено", AppsFmt.num(model.sent))
            KVRow("Пропущено", AppsFmt.num(model.skipped))
            KVRow("Ошибки", AppsFmt.num(model.failed))
        }
    }

    @ViewBuilder
    private func outcomeRows(_ o: AppsNotifyOutcome) -> some View {
        switch o {
        case .finished:
            InfoBanner("Отправка завершена.", systemImage: "checkmark.circle", color: Brand.green)
        case .stopped:
            InfoBanner("Отправка остановлена. Можно продолжить с места остановки: повторных сообщений не будет.",
                       systemImage: "pause.circle", color: Brand.amber)
        case .failed(let message, let retryable):
            ErrorBanner(message: message)
            if retryable {
                Text("Можно повторить: пачка, которая могла уйти, второй раз не отправится.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
        }
        counters
        if model.pendingJob != nil {
            Button {
                model.resume()
            } label: {
                Label(o == .stopped ? "Продолжить" : "Повторить", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
        }
        Button(model.pendingJob == nil ? "Скрыть" : "Закрыть без продолжения") {
            model.dismissOutcome()
        }
        .foregroundColor(Brand.muted)
    }
}
