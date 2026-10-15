import SwiftUI
import UIKit

/// Раздел «Рассылки»: push-уведомление пользователям выбранного сегмента.
///
/// Сервер: GET /api/admin/campaigns/segments → {all, buyers, inactive_30, new_7} (числа);
/// POST /api/admin/campaigns/send {segment, title, body, after} → {sent, audience, after, more}.
/// Сервер шлёт ПОРЦИЯМИ по 500 по курсору `after`: повторяем запрос, пока more == true
/// (как сайт, не больше 400 порций). Канал один — push в клиентские приложения
/// (android, ios, web); выбора каналов у ручки нет.
/// Если отправка оборвалась — курсор сохраняется, и её можно продолжить с места остановки.
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
            .disabled(trimmedText.isEmpty || model.sending)
        } footer: {
            if trimmedText.isEmpty {
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
    /// Ошибка сервера/сети на очередной порции.
    case failed(message: String, sent: Int, after: Int)
}

/// Незавершённая рассылка — чтобы продолжить с курсора.
struct CampaignsJob: Equatable {
    let segment: String
    let title: String
    let body: String
    let after: Int
    let sent: Int
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

    /// Сколько порций максимум (как на сайте: 400 × 500 = 200 000 человек).
    static let maxBatches = 400

    @Published private(set) var counts: JSON = .null
    @Published private(set) var countsLoading = false
    @Published private(set) var countsError: String?
    @Published private(set) var sending = false
    @Published private(set) var sentSoFar = 0
    @Published private(set) var batches = 0
    @Published private(set) var outcome: CampaignsOutcome?
    @Published private(set) var resumeJob: CampaignsJob?

    private var stopRequested = false
    private var loadedOnce = false

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

    /// Новая рассылка с начала сегмента.
    func start(segment: String, title: String, body: String) async {
        let job = CampaignsJob(segment: segment, title: title, body: body, after: 0, sent: 0)
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

    /// Убрать итог и незавершённую рассылку.
    func clearOutcome() {
        outcome = nil
        resumeJob = nil
    }

    private func run(_ job: CampaignsJob) async {
        guard !sending else { return }
        sending = true
        stopRequested = false
        outcome = nil
        resumeJob = nil
        batches = 0
        sentSoFar = job.sent
        UIApplication.shared.isIdleTimerDisabled = true
        var after = job.after
        var total = job.sent
        var result: CampaignsOutcome?
        var round = 0
        while round < CampaignsModel.maxBatches {
            round += 1
            if stopRequested {
                result = .stopped(sent: total, after: after)
                break
            }
            let body: [String: Any?] = ["segment": job.segment, "title": job.title, "body": job.body, "after": after]
            do {
                let r = try await API.shared.post("/api/admin/campaigns/send", body: body)
                total += r["sent"].intValue
                after = r["after"].int ?? after
                sentSoFar = total
                batches += 1
                if !(r["more"].bool ?? false) {
                    result = .finished(sent: total)
                    break
                }
            } catch {
                let msg = APIError.isCancellation(error) ? "Отправка прервана" : APIError.describe(error)
                result = .failed(message: msg, sent: total, after: after)
                break
            }
        }
        let done = result ?? .stopped(sent: total, after: after)
        switch done {
        case .finished:
            Haptics.success()
        case .stopped, .failed:
            Haptics.warning()
            resumeJob = CampaignsJob(segment: job.segment, title: job.title, body: job.body, after: after, sent: total)
        }
        outcome = done
        UIApplication.shared.isIdleTimerDisabled = false
        sending = false
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
                Text("Отправлено: " + Fmt.number(model.sentSoFar))
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
            }
            if let job = model.resumeJob {
                resumeButton(job)
            }
            Button("Скрыть") { model.clearOutcome() }
                .foregroundColor(Brand.muted)
        }
    }

    private func finishedText(sent: Int) -> String {
        let n: String = Fmt.number(sent)
        return "Рассылка завершена. Отправлено: " + n
    }

    private func stoppedText(sent: Int, after: Int) -> String {
        let n: String = Fmt.number(sent)
        let a: String = String(after)
        return "Рассылка остановлена. Отправлено: " + n + ", остановились после пользователя #" + a + "."
    }

    private func stoppedTail(sent: Int, after: Int) -> String {
        if sent == 0 && after == 0 { return "" }
        let n: String = Fmt.number(sent)
        let a: String = String(after)
        return " · отправлено: " + n + ", остановились после пользователя #" + a
    }

    private func resumeText(label: String, after: Int) -> String {
        let a: String = String(after)
        return "Сегмент «" + label + "», с пользователя после #" + a + ". Уйдёт тот же заголовок и текст, что и в начале."
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
