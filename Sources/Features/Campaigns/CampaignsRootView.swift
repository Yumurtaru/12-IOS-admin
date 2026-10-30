import SwiftUI
import UIKit

/// Раздел «Рассылки»: push-уведомление пользователям выбранного сегмента.
///
/// Сервер: GET /api/admin/campaigns/segments → {all, buyers, inactive_30, new_7} (числа);
/// POST /api/admin/campaigns/send {segment, title, body, after, campaign_id} →
/// {sent, audience, after, more, text_hash, campaign_id, sent_total}.
/// Канал один — push в клиентские приложения (android, ios, web); выбора каналов у ручки нет.
///
/// С `campaign_id` (П-62, А316: один на рассылку, латиница/цифры/-/_ до 64) курсор и счётчик
/// хранит сервер, по каждому получателю: порция — 100 человек, повтор той же рассылки после
/// обрыва продолжает с последнего получившего (присланный `after` меньше серверного —
/// берётся серверный), дублей нет. Параллельная порция той же рассылки — 409 «уже
/// отправляется»; тот же id с другим текстом или сегментом — 409 «занят». `sent_total` —
/// «Отправлено всего». Поэтому при неизвестном исходе порции сразу доступна «Повторить».
///
/// Старый сервер (в ответе нет `campaign_id`) шлёт порциями по 500 с окном повтора 2 мин —
/// для него остаётся запасная проверка по журналу действий (GET /api/admin/audit?action=campaign:
/// по каждой порции {segment, sent, after, more}) и «Отправить порцию снова» после подтверждения.
/// Порция может идти дольше обычных 30 с — ждём до 200 с.
/// `openId` здесь не используется (у рассылок нет объектов).
struct CampaignsRootView: View {
    let openId: Int?

    @StateObject private var model = CampaignsModel()
    @State private var segment = "all"
    @State private var title = ""
    @State private var text = ""

    private let titleLimit = 120
    private let textLimit = 1000

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                Text("Push-уведомления пользователям выбранного сегмента. Текст — короткий и с пользой (акция, новинка, напоминание).")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
            segmentSection
            channelSection
            messageSection
            previewSection
            sendSection
            CampaignsProgressSection(model: model)
        }
        .navigationTitle("Рассылки")
        .task { await model.loadCountsIfNeeded() }
        .refreshable { await model.loadCounts() }
        .onChange(of: title) { v in
            if v.count > titleLimit { title = String(v.prefix(titleLimit)) }
        }
        .onChange(of: text) { v in
            if v.count > textLimit { text = String(v.prefix(textLimit)) }
        }
    }

    // MARK: - Секции

    private var segmentSection: some View {
        Section {
            ForEach(CampaignsModel.segments) { opt in
                segmentRow(opt)
            }
            if let e = model.countsError {
                ErrorBanner(message: e, retry: { Task { await model.loadCounts() } })
            }
        } header: {
            Text("Сегмент")
        } footer: {
            Text("Число — активные клиенты, не отключившие уведомления. Push дойдёт до тех, у кого есть приложение или включены уведомления на сайте.")
        }
    }

    private func segmentRow(_ opt: PickerOption) -> some View {
        Button {
            Haptics.tap()
            segment = opt.value
        } label: {
            HStack {
                Image(systemName: segment == opt.value ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(segment == opt.value ? Brand.accent : Brand.muted)
                Text(opt.label)
                    .foregroundColor(Brand.text)
                Spacer()
                countLabel(opt.value)
            }
        }
        .disabled(model.sending)
    }

    @ViewBuilder
    private func countLabel(_ seg: String) -> some View {
        if let n = model.count(for: seg) {
            Text("~" + Fmt.number(n))
                .monospacedDigit()
                .foregroundColor(Brand.muted)
        } else if model.countsLoading {
            ProgressView()
        }
    }

    private var channelSection: some View {
        Section("Канал") {
            Label("Push в клиентские приложения и на сайт", systemImage: "bell.badge")
            Text("Приложение продавца и станции рассылку не получают.")
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
    }

    private var messageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("Заголовок")
                TextField("Например: Скидка 20% сегодня", text: $title)
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldTitle("Текст")
                TextEditor(text: $text)
                    .frame(minHeight: 120)
            }
        } header: {
            Text("Сообщение")
        } footer: {
            Text(counterText)
        }
        .disabled(model.sending)
    }

    private var counterText: String {
        let t = "Заголовок: " + String(title.count) + " / " + String(titleLimit)
        let b = "текст: " + String(text.count) + " / " + String(textLimit)
        return t + " · " + b + ". Без заголовка придёт «Yumurta»."
    }

    @ViewBuilder
    private var previewSection: some View {
        if !trimmedText.isEmpty {
            Section("Как увидит пользователь") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trimmedTitle.isEmpty ? "Yumurta" : trimmedTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(trimmedText)
                        .font(.subheadline)
                        .foregroundColor(Brand.text)
                        .lineLimit(4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.chip)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var sendSection: some View {
        Section {
            ActionButton("Отправить", systemImage: "paperplane.fill", style: .prominent,
                         confirm: sendConfirm, fullWidth: true) {
                await model.start(segment: segment, title: trimmedTitle, body: trimmedText)
            }
            .disabled(trimmedText.isEmpty || model.sending || model.uncertainJob != nil)
        } footer: {
            if model.uncertainJob?.tracked == true {
                Text("Сначала завершите прошлую рассылку в «Итоге» ниже («Повторить» продолжит её без дублей).")
            } else if model.uncertainJob != nil {
                Text("Сначала проверьте прошлую порцию в «Итоге» ниже — иначе люди могут получить push дважды.")
            } else if trimmedText.isEmpty {
                Text("Введите текст рассылки.")
            }
        }
    }

    private var sendConfirm: ConfirmAction {
        let label = CampaignsModel.segmentLabel(segment)
        var message = "Сегмент «" + label + "»"
        if let n = model.count(for: segment) {
            message += " — ~" + Fmt.plural(n, "получатель", "получателя", "получателей")
        }
        message += ". Отправленные уведомления отозвать нельзя."
        return ConfirmAction(title: "Отправить рассылку?", message: message, confirmLabel: "Отправить")
    }
}

/// Итог отправки.
enum CampaignsOutcome: Equatable {
    /// Все порции ушли.
    case finished(sent: Int)
    /// Остановлено вручную (или достигнут предел порций).
    case stopped(sent: Int, after: Int)
    /// Ошибка сервера на очередной порции (ответ получен — порция не ушла).
    case failed(message: String, sent: Int, after: Int)
    /// Ответ на порцию не пришёл (нет связи, обрыв, 5xx) — она могла уйти.
    case uncertain(message: String, sent: Int, after: Int)
}

/// Незавершённая рассылка — чтобы продолжить с курсора.
struct CampaignsJob: Equatable {
    let segment: String
    let title: String
    let body: String
    let after: Int
    let sent: Int
    /// Номер рассылки для сервера (`campaign_id`) — один на всю рассылку, с её продолжениями.
    let campaignId: String
    /// Сервер держит курсор по `campaign_id`: true — подтвердил (вернул его в ответе или в
    /// журнале), false — ответил без него (старый сервер), nil — ответа ещё не было.
    let tracked: Bool?

    /// Та же рассылка с новым курсором и счётчиком.
    func moved(after: Int, sent: Int, tracked: Bool?) -> CampaignsJob {
        CampaignsJob(segment: segment, title: title, body: body, after: after, sent: sent,
                     campaignId: campaignId, tracked: tracked)
    }

    /// Новый номер рассылки: латиница, цифры и «-» (сервер оставляет [A-Za-z0-9_-], до 64).
    static func newCampaignId() -> String {
        "adm-camp-" + UUID().uuidString.lowercased()
    }
}

/// Счётчики сегментов и отправка порциями.
@MainActor
final class CampaignsModel: ObservableObject {
    /// Сегменты (как на сайте).
    static let segments: [PickerOption] = [
        PickerOption(value: "all", label: "Все пользователи"),
        PickerOption(value: "buyers", label: "Покупатели (делали заказ)"),
        PickerOption(value: "inactive_30", label: "Неактивные 30+ дней"),
        PickerOption(value: "new_7", label: "Новые (7 дней)"),
    ]

    static func segmentLabel(_ code: String) -> String {
        segments.first(where: { $0.value == code })?.label ?? code
    }

    /// Сколько порций максимум: 2000 × 100 = 200 000 человек (с campaign_id порция — 100).
    static let maxBatches = 2000

    @Published private(set) var counts: JSON = .null
    @Published private(set) var countsLoading = false
    @Published private(set) var countsError: String?
    @Published private(set) var sending = false
    @Published private(set) var sentSoFar = 0
    @Published private(set) var batches = 0
    @Published private(set) var outcome: CampaignsOutcome?
    @Published private(set) var resumeJob: CampaignsJob?
    /// Порция с неизвестным исходом (с курсора `after`): повторять только после проверки.
    @Published private(set) var uncertainJob: CampaignsJob?
    /// Идёт проверка по журналу.
    @Published private(set) var checking = false
    /// В журнале порции нет — можно отправить её снова (после подтверждения).
    @Published private(set) var checkedMissing = false
    /// Итог проверки для показа.
    @Published private(set) var checkNote: String?

    private var stopRequested = false
    private var loadedOnce = false
    /// Наибольший id записей «campaign» журнала до начала отправки (nil — не прочитали).
    private var auditBaseline: Int?
    /// Когда ушла порция с неизвестным исходом.
    private var uncertainSentAt: Date?

    /// Ожидание ответа на порцию, с (до 500 push синхронно).
    static let batchTimeout: TimeInterval = 200
    /// «Отправить порцию снова» — не раньше, чем через столько секунд после её отправки:
    /// сервер мог ещё дорассылать её (и его защита от повтора — 120 с).
    static let resendDelay: TimeInterval = 200

    /// Записи журнала о порциях рассылок (новые сверху, первая страница).
    private static func auditEntries() async throws -> [JSON] {
        let d = try await API.shared.get("/api/admin/audit", query: [
            "action": "campaign", "entity": "marketing", "page": "1",
        ])
        return d["items"].array.filter { $0["action"].stringValue == "campaign" }
    }

    func count(for segment: String) -> Int? { counts[segment].int }

    func loadCountsIfNeeded() async {
        if !loadedOnce { await loadCounts() }
    }

    func loadCounts() async {
        countsLoading = true
        countsError = nil
        do {
            counts = try await API.shared.get("/api/admin/campaigns/segments")
            loadedOnce = true
        } catch {
            if !APIError.isCancellation(error) {
                countsError = "Не удалось посчитать аудиторию: " + APIError.describe(error)
            }
        }
        countsLoading = false
    }

    /// Новая рассылка с начала сегмента (новый campaign_id).
    func start(segment: String, title: String, body: String) async {
        let job = CampaignsJob(segment: segment, title: title, body: body, after: 0, sent: 0,
                               campaignId: CampaignsJob.newCampaignId(), tracked: nil)
        await run(job)
    }

    /// Продолжить оборванную рассылку с курсора.
    func resume() async {
        guard let job = resumeJob else { return }
        await run(job)
    }

    /// Остановить после текущей порции.
    func stop() {
        stopRequested = true
    }

    /// Убрать итог и незавершённую рассылку. Порцию с неизвестным исходом не забываем:
    /// иначе «Отправить» с начала разослал бы её второй раз.
    func clearOutcome() {
        guard uncertainJob == nil else { return }
        outcome = nil
        resumeJob = nil
        uncertainJob = nil
        checkedMissing = false
        checkNote = nil
    }

    /// «Отправить порцию снова» — после проверки, что в журнале её нет (старый сервер).
    func resendUncertain() async {
        guard let job = uncertainJob, checkedMissing, !checking else { return }
        await run(job, resending: true)
    }

    /// «Повторить» после неизвестного исхода: сервер держит курсор по campaign_id и
    /// продолжит с последнего получившего — дублей нет, проверять журнал не нужно.
    func retryUncertain() async {
        guard let job = uncertainJob, job.tracked == true, !checking, !sending else { return }
        await run(job, resending: true)
    }

    /// Перечитать ход рассылки из журнала: дошла ли порция с неизвестным исходом.
    func checkUncertain() async {
        guard let job = uncertainJob, !checking, !sending else { return }
        checking = true
        defer { checking = false }
        do {
            let rows = try await CampaignsModel.auditEntries()
            let base = auditBaseline
            let since = uncertainSentAt?.addingTimeInterval(-600)
            var best: (after: Int, sent: Int, more: Bool)?
            var ownSeen = false
            for r in rows {
                if let b = base {
                    guard let id = r.id, id > b else { continue }
                } else {
                    guard let s = since, let d = Fmt.parseDate(r["created_at"].string), d >= s else { continue }
                }
                let n = CourierHistoryRow.parsed(r["new_json"])
                // Запись другой рассылки (свой campaign_id) — не наша порция.
                if let cid = n["campaign_id"].nonEmptyString {
                    guard cid == job.campaignId else { continue }
                    ownSeen = true
                }
                guard n["segment"].stringValue == job.segment, let a = n["after"].int, a > job.after else { continue }
                // Следующая за курсором порция — с наименьшим «after».
                if best == nil || a < (best?.after ?? Int.max) {
                    best = (a, n["sent"].intValue, n["more"].boolValue)
                }
            }
            let tracked: Bool? = ownSeen ? true : job.tracked
            guard let found = best else {
                if ownSeen && job.tracked != true {
                    // Сервер ведёт эту рассылку по campaign_id — повтор безопасен.
                    uncertainJob = job.moved(after: job.after, sent: job.sent, tracked: true)
                    checkedMissing = false
                    checkNote = "Проверено в " + MoneyOp.nowText() + ": сервер ведёт эту рассылку сам. «Повторить» продолжит с последнего получившего — дублей не будет."
                    return
                }
                let elapsed = Date().timeIntervalSince(uncertainSentAt ?? .distantPast)
                let checked = "Проверено в " + MoneyOp.nowText() + ": в отчёте рассылки (журнал действий) этой порции нет."
                if elapsed < CampaignsModel.resendDelay {
                    checkedMissing = false
                    let wait = Int((CampaignsModel.resendDelay - elapsed).rounded(.up))
                    checkNote = checked + " Сервер мог ещё отправлять её — проверьте снова через " + String(wait) + " с; отправить заново можно будет после этого."
                } else {
                    checkedMissing = true
                    checkNote = checked + " Сервер мог ещё отправлять — подождите минуту и проверьте снова."
                }
                return
            }
            let total = job.sent + found.sent
            uncertainJob = nil
            checkedMissing = false
            sentSoFar = total
            Haptics.success()
            if found.more {
                resumeJob = job.moved(after: found.after, sent: total, tracked: tracked)
                checkNote = "Порция дошла (по журналу): ещё " + Fmt.number(found.sent) + ". Можно продолжить с места остановки."
                outcome = .stopped(sent: total, after: found.after)
            } else {
                resumeJob = nil
                checkNote = "Последняя порция дошла (по журналу), ответ сервера просто не пришёл."
                outcome = .finished(sent: total)
            }
        } catch {
            if APIError.isCancellation(error) { return }
            checkNote = "Проверить не удалось: " + APIError.describe(error)
        }
    }

    private func run(_ job: CampaignsJob, resending: Bool = false) async {
        guard !sending else { return }
        sending = true
        stopRequested = false
        outcome = nil
        resumeJob = nil
        uncertainJob = nil
        checkedMissing = false
        checkNote = nil
        batches = 0
        sentSoFar = job.sent
        UIApplication.shared.isIdleTimerDisabled = true
        // Запомнить, что уже есть в журнале: по нему проверим порцию без ответа.
        // При повторе проверенной порции прежняя отметка годится.
        if !resending || auditBaseline == nil {
            auditBaseline = (try? await CampaignsModel.auditEntries()).map { MoneyOp.maxId($0) ?? 0 }
        }
        var after = job.after
        var total = job.sent
        var tracked = job.tracked
        /// Номер рассылки занят другим текстом — продолжать её нечем.
        var conflict = false
        var result: CampaignsOutcome?
        var round = 0
        while round < CampaignsModel.maxBatches {
            round += 1
            if stopRequested {
                result = .stopped(sent: total, after: after)
                break
            }
            let body: [String: Any?] = ["segment": job.segment, "title": job.title, "body": job.body, "after": after,
                                        "campaign_id": job.campaignId]
            let sentAt = Date()
            do {
                let r = try await API.shared.post("/api/admin/campaigns/send", body: body,
                                                  timeout: CampaignsModel.batchTimeout)
                if r["campaign_id"].nonEmptyString == job.campaignId {
                    // Сервер ведёт рассылку: «всего» — его счётчик (с прошлыми порциями и повторами).
                    tracked = true
                    total = r["sent_total"].int ?? (total + r["sent"].intValue)
                } else {
                    tracked = false
                    total += r["sent"].intValue
                }
                after = r["after"].int ?? after
                sentSoFar = total
                batches += 1
                if !(r["more"].bool ?? false) {
                    result = .finished(sent: total)
                    break
                }
            } catch {
                let e = API.mapTransport(error)
                // 409 «Эта порция рассылки только что отправлена» (adminRepeatGuard, без
                // campaign_id) — она уже уходила: тоже неизвестный исход, а не ошибка.
                let repeatHit = e.status == 409 && e.message.contains("только что")
                // 409 «Порция этой рассылки уже отправляется» — сервер ведёт рассылку по
                // campaign_id, и прошлая порция ещё идёт: повторить чуть позже.
                let busyHit = e.status == 409 && e.message.contains("уже отправляется")
                // 409 «Этот номер рассылки уже занят другим текстом или сегментом».
                let takenHit = e.status == 409 && e.message.contains("уже занят")
                if busyHit {
                    tracked = true
                    uncertainSentAt = sentAt
                    result = .uncertain(message: "Прошлая порция этой рассылки ещё отправляется на сервере. Подождите немного и нажмите «Повторить».",
                                        sent: total, after: after)
                } else if takenHit {
                    conflict = true
                    result = .failed(message: "Номер рассылки уже занят другим текстом или сегментом — эту рассылку продолжить нельзя. Начните новую кнопкой «Отправить».",
                                     sent: total, after: after)
                } else if MoneyOp.isUnknown(e) || repeatHit {
                    // Ответа нет — порция могла уйти: курсор не двигаем и молча не повторяем.
                    uncertainSentAt = sentAt
                    let head = e == .cancelled ? "Отправка прервана." : e.message
                    result = .uncertain(message: head, sent: total, after: after)
                } else {
                    result = .failed(message: e.message, sent: total, after: after)
                }
                break
            }
        }
        let done = result ?? .stopped(sent: total, after: after)
        let left = job.moved(after: after, sent: total, tracked: tracked)
        switch done {
        case .finished:
            Haptics.success()
        case .stopped, .failed:
            Haptics.warning()
            resumeJob = conflict ? nil : left
        case .uncertain:
            Haptics.error()
            uncertainJob = left
        }
        outcome = done
        UIApplication.shared.isIdleTimerDisabled = false
        sending = false
        if case .uncertain = done, tracked != true {
            // Старый сервер (или ответа ещё не было): сразу смотрим журнал — часто порция уже
            // записана, и можно продолжить. Сервер с campaign_id сам продолжит при «Повторить».
            await checkUncertain()
        }
    }
}

/// Ход и итог рассылки: счётчик, «Остановить», «Продолжить с места остановки».
struct CampaignsProgressSection: View {
    @ObservedObject var model: CampaignsModel

    var body: some View {
        if model.sending {
            sendingSection
        } else if let o = model.outcome {
            outcomeSection(o)
        }
    }

    private var sendingSection: some View {
        Section("Отправка") {
            HStack(spacing: 10) {
                ProgressView()
                Text("Отправлено всего: " + Fmt.number(model.sentSoFar))
                    .monospacedDigit()
            }
            Text("Порций: " + String(model.batches) + ". Не закрывайте приложение до конца рассылки.")
                .font(.caption)
                .foregroundColor(Brand.muted)
            Button(role: .destructive) {
                model.stop()
            } label: {
                Label("Остановить после текущей порции", systemImage: "stop.circle")
            }
        }
    }

    @ViewBuilder
    private func outcomeSection(_ o: CampaignsOutcome) -> some View {
        Section("Итог") {
            switch o {
            case .finished(let sent):
                InfoBanner(finishedText(sent: sent),
                           systemImage: "checkmark.circle", color: Brand.green)
            case .stopped(let sent, let after):
                InfoBanner(stoppedText(sent: sent, after: after),
                           systemImage: "pause.circle", color: Brand.amber)
            case .failed(let message, let sent, let after):
                ErrorBanner(message: message + stoppedTail(sent: sent, after: after))
            case .uncertain(let message, let sent, let after):
                InfoBanner(message + uncertainHint + stoppedTail(sent: sent, after: after),
                           systemImage: "exclamationmark.triangle.fill", color: Brand.amber)
            }
            if let note = model.checkNote {
                Text(note)
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
            if model.uncertainJob != nil {
                uncertainButtons
            }
            if let job = model.resumeJob {
                resumeButton(job)
            }
            if model.uncertainJob == nil {
                Button("Скрыть") { model.clearOutcome() }
                    .foregroundColor(Brand.muted)
            }
        }
    }

    private var uncertainHint: String {
        if model.uncertainJob?.tracked == true {
            return " Порция могла уйти. «Повторить» — безопасно: сервер продолжит с последнего получившего, дублей не будет."
        }
        return " Порция могла уйти — проверьте отчёт рассылки (журнал действий)."
    }

    @ViewBuilder
    private var uncertainButtons: some View {
        if model.uncertainJob?.tracked == true {
            ActionButton("Повторить", systemImage: "arrow.uturn.forward", style: .prominent, fullWidth: true) {
                await model.retryUncertain()
            }
            .disabled(model.checking)
        }
        Button {
            Task { await model.checkUncertain() }
        } label: {
            HStack {
                Spacer()
                if model.checking {
                    ProgressView()
                    Text("Проверяем…")
                } else {
                    Label("Проверить отчёт рассылки", systemImage: "arrow.clockwise")
                }
                Spacer()
            }
        }
        .disabled(model.checking)
        if model.checkedMissing && model.uncertainJob?.tracked != true {
            ActionButton("Отправить порцию снова", systemImage: "paperplane", role: .destructive, style: .bordered,
                         confirm: ConfirmAction(title: "Порции нет в отчёте — отправить её ещё раз?",
                                                message: "Если она всё-таки ушла и просто не успела попасть в журнал, до 500 человек получат push второй раз.",
                                                confirmLabel: "Отправить снова", destructive: true),
                         fullWidth: true) {
                await model.resendUncertain()
            }
            .disabled(model.checking)
        }
    }

    private func finishedText(sent: Int) -> String {
        let n: String = Fmt.number(sent)
        return "Рассылка завершена. Отправлено всего: " + n
    }

    private func stoppedText(sent: Int, after: Int) -> String {
        let n: String = Fmt.number(sent)
        let a: String = String(after)
        return "Рассылка остановлена. Отправлено всего: " + n + ", остановились после пользователя #" + a + "."
    }

    private func stoppedTail(sent: Int, after: Int) -> String {
        if sent == 0 && after == 0 { return "" }
        let n: String = Fmt.number(sent)
        let a: String = String(after)
        return " · отправлено всего: " + n + ", остановились после пользователя #" + a
    }

    private func resumeText(label: String, after: Int) -> String {
        let a: String = String(after)
        return "Сегмент «" + label + "», с пользователя после #" + a + ". Уйдёт тот же заголовок и текст, что и в начале; кто уже получил — второй раз не получит."
    }

    private func resumeButton(_ job: CampaignsJob) -> some View {
        let label = CampaignsModel.segmentLabel(job.segment)
        let confirm = ConfirmAction(
            title: "Продолжить рассылку?",
            message: resumeText(label: label, after: job.after),
            confirmLabel: "Продолжить")
        return ActionButton("Продолжить с места остановки", systemImage: "play.fill", style: .bordered,
                            confirm: confirm, fullWidth: true) {
            await model.resume()
        }
    }
}
