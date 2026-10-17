import SwiftUI
import UIKit

/// Общее для чатов «Сообщения продавцам»: какой чат сейчас на экране и сигнал
/// «пришёл push — подтяни новое» (AppDelegate не показывает баннер о сообщении
/// организации, чей чат и так открыт).
enum ShopSupportLive {
    /// id организации, чей чат сейчас виден (nil — ни один).
    @MainActor static var visibleShopId: Int?
    /// Уведомление NotificationCenter: открытому чату опросить сервер сейчас.
    static let poke = Notification.Name("yumurta.admin.shopSupport.poke")
}

/// Подписи и время для переписки.
enum ShopSupportFmt {
    /// Сегодня — «14:05», иначе — «14 окт, 14:05» (по Москве, как весь Fmt).
    static func time(_ s: String?) -> String {
        guard Fmt.parseDate(s) != nil else { return "" }
        let today = Fmt.day(Fmt.serverDateTime(Date()))
        if Fmt.day(s) == today { return Fmt.time(s) }
        return Fmt.date(s)
    }

    /// «10 МБ» — для текстов о пределе файла.
    static func megabytes(_ bytes: Int) -> String {
        let mb = max(1, Int((Double(bytes) / 1_048_576).rounded()))
        return String(mb) + " МБ"
    }
}

/// Вложение, выбранное для отправки (одно на сообщение — так принимает сервер).
struct ShopSupportOutgoingFile: Identifiable {
    let id = UUID()
    /// Байты файла (фото уже уменьшено в JPEG).
    let data: Data
    /// Имя файла для сервера и подписи.
    let fileName: String
    /// MIME-тип: image/jpeg или application/pdf.
    let mime: String
    /// Миниатюра для показа над полем ввода (только у фото).
    let preview: UIImage?

    var isImage: Bool { mime.hasPrefix("image/") }
}

/// Переписка администратора с одной организацией:
/// GET /api/admin/shop-support/{shopId}/messages (after_id / before_id / limit),
/// POST …/messages (JSON или multipart с полем file, ключ повтора idempotency_key),
/// POST …/read {up_to_id}, POST …/status {status: open|closed}.
///
/// Новые сообщения — опросом after_id раз в 15 с, ТОЛЬКО пока чат на экране и
/// приложение активно (`setVisible`). `cursor` — наибольший id, до которого
/// сообщения получены сплошь (первая загрузка и опросы); своё отправленное
/// сообщение показываем сразу, но курсор не двигаем, чтобы реплика продавца,
/// пришедшая между опросом и отправкой, не потерялась.
@MainActor
final class ShopSupportChatModel: ObservableObject {
    /// Пауза между опросами.
    static let pollNanos: UInt64 = 15_000_000_000

    let shopId: Int

    /// Первая загрузка.
    @Published private(set) var state: LoadState = .idle
    /// Сообщения по возрастанию id.
    @Published private(set) var messages: [JSON] = []
    /// Организация (shop из ответа: name, phone, owner_*, city, status…).
    @Published private(set) var shop: JSON = .null
    /// Шапка переписки (status, unread, last_message_id, seller_read_id, admin_read_id).
    @Published private(set) var thread: JSON = .null
    /// Есть более ранние сообщения.
    @Published private(set) var hasOlder = false
    /// Идёт загрузка более ранних.
    @Published private(set) var loadingOlder = false
    /// Ошибка загрузки более ранних.
    @Published var olderError: String?
    /// Ошибка опроса (список при этом на экране).
    @Published var pollError: String?
    /// Предел длины сообщения.
    @Published private(set) var maxBody = 4000
    /// Предел файла (0 — сервер не сообщил).
    @Published private(set) var maxFile = 0
    /// Предел фото (0 — сервер не сообщил).
    @Published private(set) var maxImage = 0
    /// Текст в поле ввода.
    @Published var draft = ""
    /// Выбранное вложение.
    @Published var attachment: ShopSupportOutgoingFile?
    /// Идёт отправка.
    @Published private(set) var sending = false
    /// Ошибка отправки (текст и вложение остаются).
    @Published var sendError: String?
    /// Ошибка действия (смена статуса).
    @Published var actionError: String?
    /// Идёт смена статуса.
    @Published private(set) var statusBusy = false

    private var cursor = 0
    private var generation = 0
    private var pollInFlight = false
    private var pollTask: Task<Void, Never>?
    private var visible = false
    private var readSentUpTo = 0
    // Ключ повтора текущей отправки и «подпись» её содержимого: повтор того же
    // текста и вложения идёт с тем же ключом (сервер не создаст дубль), правка — с новым.
    private var pendingKey: String?
    private var pendingSignature: String?

    init(shopId: Int) {
        self.shopId = shopId
    }

    // MARK: - Производные

    private var base: String { "/api/admin/shop-support/" + String(shopId) }

    /// open / closed (пока переписки нет — open).
    var status: String { thread["status"].nonEmptyString ?? "open" }

    /// Переписка уже есть (статус можно менять только у существующей).
    var hasThread: Bool { thread["last_message_id"].intValue > 0 || !messages.isEmpty }

    /// Название организации для заголовка.
    var shopName: String { shop["name"].nonEmptyString ?? ("Организация #" + String(shopId)) }

    /// id последнего показанного сообщения (0 — нет).
    var lastId: Int { messages.last?["id"].intValue ?? 0 }

    /// Есть что отправить и можно отправлять.
    var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !sending && (hasText || attachment != nil) && draft.count <= maxBody
    }

    /// Прочитала ли организация МОЁ сообщение: флаг сервера или позиция чтения
    /// продавца из шапки (шапка приходит с каждым опросом — флаг старых сообщений
    /// обновляется без их перезагрузки).
    func isRead(_ m: JSON) -> Bool {
        if m["read"].boolValue { return true }
        let id = m["id"].intValue
        return id > 0 && id <= thread["seller_read_id"].intValue
    }

    // MARK: - Видимость и опрос

    /// Чат на экране и приложение активно → опрос раз в 15 с; иначе опрос стоит.
    func setVisible(_ v: Bool) {
        if v { ShopSupportLive.visibleShopId = shopId }
        else if ShopSupportLive.visibleShopId == shopId { ShopSupportLive.visibleShopId = nil }
        guard v != visible else { return }
        visible = v
        pollTask?.cancel()
        pollTask = nil
        guard v else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ShopSupportChatModel.pollNanos)
                guard !Task.isCancelled, let me = self else { return }
                await me.poll()
            }
        }
        // Вернулись на экран — сразу догоняем пропущенное.
        if state == .loaded {
            Task { await self.poll() }
        }
    }

    // MARK: - Загрузка

    func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    /// Первая загрузка: последние 50 сообщений.
    func load() async {
        generation += 1
        let gen = generation
        if messages.isEmpty { state = .loading }
        do {
            let d = try await API.shared.get(base + "/messages", query: ["limit": "50"])
            guard gen == generation else { return }
            applyMeta(d)
            let items = d["items"].array
            messages = []
            merge(items)
            cursor = ShopSupportChatModel.maxId(items)
            hasOlder = d["has_more"].boolValue
            pollError = nil
            state = .loaded
            await markReadIfNeeded()
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            if messages.isEmpty {
                state = .failed(APIError.describe(error))
            } else {
                pollError = APIError.describe(error)
            }
        }
    }

    /// Новые сообщения после курсора (до 5 порций по 200, если их много).
    func poll() async {
        guard state == .loaded, !pollInFlight else { return }
        pollInFlight = true
        defer { pollInFlight = false }
        let gen = generation
        do {
            var rounds = 0
            while rounds < 5 {
                rounds += 1
                let after = cursor
                var q: [String: String?] = ["limit": "50"]
                if after > 0 { q["after_id"] = String(after) }
                let d = try await API.shared.get(base + "/messages", query: q)
                guard gen == generation else { return }
                applyMeta(d)
                let items = d["items"].array
                merge(items)
                cursor = max(cursor, ShopSupportChatModel.maxId(items))
                if after == 0 {
                    // Переписки не было: это первая страница, has_more — «есть раньше».
                    hasOlder = d["has_more"].boolValue
                    break
                }
                if items.isEmpty || !d["has_more"].boolValue { break }
            }
            pollError = nil
            await markReadIfNeeded()
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            pollError = APIError.describe(error)
        }
    }

    /// Более ранние сообщения. Возвращает id, к которому прокрутить (прежнее первое).
    func loadOlder() async -> Int? {
        guard hasOlder, !loadingOlder, let first = messages.first?["id"].int, first > 0 else { return nil }
        loadingOlder = true
        olderError = nil
        defer { loadingOlder = false }
        let gen = generation
        do {
            let d = try await API.shared.get(base + "/messages",
                                             query: ["before_id": String(first), "limit": "50"])
            guard gen == generation else { return nil }
            merge(d["items"].array)
            hasOlder = d["has_more"].boolValue
            return first
        } catch {
            if !APIError.isCancellation(error) { olderError = APIError.describe(error) }
            return nil
        }
    }

    /// Отметить прочитанным до курсора, если есть непрочитанное от организации
    /// и чат действительно виден (не под экраном блокировки).
    private func markReadIfNeeded() async {
        guard visible, cursor > 0, !AppLock.shared.isLocked else { return }
        let adminRead = thread["admin_read_id"].intValue
        let incoming = messages.last(where: { $0["side"].string == "seller" })
        let lastIncoming = incoming?["id"].intValue ?? 0
        guard lastIncoming > adminRead, lastIncoming > readSentUpTo else { return }
        let before = readSentUpTo
        readSentUpTo = lastIncoming
        do {
            let d = try await API.shared.post(base + "/read", body: ["up_to_id": cursor])
            if d.isObject { thread = d }
            // Бейдж «Заявок» и иконки — сразу, а не через минуту.
            Task { await Notifier.shared.refresh(force: true) }
        } catch {
            // Не вышло — попробуем при следующем опросе.
            readSentUpTo = before
        }
    }

    // MARK: - Отправка

    /// Отправить текст и/или вложение. Ошибка оставляет текст и вложение;
    /// повтор того же содержимого идёт с тем же ключом повтора.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let file = attachment
        guard !sending, !text.isEmpty || file != nil else { return }
        if text.count > maxBody {
            sendError = "Сообщение длиннее " + String(maxBody) + " символов — сократите или разбейте на несколько."
            return
        }
        let signature = text + "|" + (file?.id.uuidString ?? "")
        if pendingKey == nil || pendingSignature != signature {
            pendingKey = UUID().uuidString
            pendingSignature = signature
        }
        let key = pendingKey ?? UUID().uuidString
        sending = true
        sendError = nil
        defer { sending = false }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let d = try await postMessage(text: text, file: file, key: key)
                didSend(d, text: text, file: file)
                return
            } catch {
                if APIError.isCancellation(error) { return }
                // 409 «запрос уже выполняется» — прежняя попытка с этим ключом ещё идёт:
                // ждём 2 с и повторяем тем же ключом один раз.
                if let e = error as? APIError, e.status == 409, attempt == 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                Haptics.error()
                sendError = APIError.describe(error)
                return
            }
        }
    }

    private func postMessage(text: String, file: ShopSupportOutgoingFile?, key: String) async throws -> JSON {
        let path = base + "/messages"
        // seen_up_to — до какого сообщения администратор всё видел (сервер двигает
        // позицию прочтения отправителя только до него).
        let seen = cursor
        if let f = file {
            var fields: [String: String] = ["body": text, "idempotency_key": key]
            if seen > 0 { fields["seen_up_to"] = String(seen) }
            return try await API.shared.upload(path, fileData: f.data, fileName: f.fileName,
                                               mime: f.mime, fields: fields)
        }
        var body: [String: Any?] = ["body": text, "idempotency_key": key]
        if seen > 0 { body["seen_up_to"] = seen }
        return try await API.shared.post(path, body: body)
    }

    private func didSend(_ d: JSON, text: String, file: ShopSupportOutgoingFile?) {
        let msg = d["message"]
        if msg.isObject { merge([msg]) }
        if d["thread"].isObject { thread = d["thread"] }
        // Поле не трогаем, если человек уже набирает следующее.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        if let f = file, attachment?.id == f.id { attachment = nil }
        pendingKey = nil
        pendingSignature = nil
        Haptics.success()
        // Догоняем то, что могло прийти от организации между опросом и отправкой.
        Task { await self.poll() }
    }

    // MARK: - Статус

    /// «Отметить решённым» (closed) / «Открыть снова» (open).
    func setStatus(_ s: String) async {
        guard !statusBusy else { return }
        statusBusy = true
        defer { statusBusy = false }
        do {
            let d = try await API.shared.post(base + "/status", body: ["status": s])
            if d.isObject { thread = d }
            Haptics.success()
            Task { await Notifier.shared.refresh(force: true) }
        } catch {
            if !APIError.isCancellation(error) {
                Haptics.error()
                actionError = APIError.describe(error)
            }
        }
    }

    // MARK: - Вложения

    /// Фото из галереи → JPEG ≤ 2048 px (если не влезает в предел — сильнее).
    func attachImage(_ image: UIImage) {
        var data = ImageDownscaler.jpeg(image)
        if let d = data, maxImage > 0, d.count > maxImage {
            data = ImageDownscaler.jpeg(image, maxSide: 1600, quality: 0.6)
        }
        guard let d = data else {
            sendError = "Не удалось подготовить фото. Выберите другое."
            return
        }
        if maxImage > 0 && d.count > maxImage {
            sendError = "Фото больше " + ShopSupportFmt.megabytes(maxImage) + " — выберите другое."
            return
        }
        let thumb = image.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? image
        attachment = ShopSupportOutgoingFile(data: d, fileName: "photo.jpg", mime: "image/jpeg", preview: thumb)
        sendError = nil
    }

    /// PDF из «Файлов».
    func attachPDF(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e):
            if !APIError.isCancellation(e) { sendError = "Не удалось открыть файл: " + e.localizedDescription }
        case .success(let url):
            Task { await self.attachPDF(url: url) }
        }
    }

    /// Файл до 10 МБ (и из iCloud) читаем НЕ на главном потоке — интерфейс не замирает;
    /// проверки и показ — уже на главном.
    private func attachPDF(url: URL) async {
        let read = Task.detached(priority: .userInitiated) { () -> Data? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            // Копия, пока доступ к файлу открыт: отображённые страницы после
            // stopAccessing… могли бы оказаться недоступны при отправке.
            return mapped.withUnsafeBytes { Data($0) }
        }
        let loaded = await read.value
        guard let data = loaded, !data.isEmpty else {
            sendError = "Не удалось прочитать файл. Если он в iCloud — дождитесь загрузки и выберите снова."
            return
        }
        let head = String(data: data.prefix(5), encoding: .ascii) ?? ""
        guard head == "%PDF-" else {
            sendError = "Файл не похож на PDF."
            return
        }
        if maxFile > 0 && data.count > maxFile {
            sendError = "Файл больше " + ShopSupportFmt.megabytes(maxFile) + "."
            return
        }
        let name = url.lastPathComponent.isEmpty ? "Документ.pdf" : url.lastPathComponent
        attachment = ShopSupportOutgoingFile(data: data, fileName: name, mime: "application/pdf", preview: nil)
        sendError = nil
    }

    // MARK: - Внутреннее

    private func applyMeta(_ d: JSON) {
        if d["shop"].isObject { shop = d["shop"] }
        if d["thread"].isObject { thread = d["thread"] }
        if let m = d["max_body"].int, m > 0 { maxBody = m }
        if let m = d["max_file"].int, m > 0 { maxFile = m }
        if let m = d["max_image"].int, m > 0 { maxImage = m }
    }

    /// Влить сообщения без дублей (по id) и по возрастанию id.
    private func merge(_ items: [JSON]) {
        guard !items.isEmpty else { return }
        var byId: [Int: JSON] = [:]
        for m in messages { byId[m["id"].intValue] = m }
        for m in items {
            let id = m["id"].intValue
            if id > 0 { byId[id] = m }
        }
        let ids = byId.keys.sorted()
        messages = ids.compactMap { byId[$0] }
    }

    private static func maxId(_ items: [JSON]) -> Int {
        var top = 0
        for m in items { top = max(top, m["id"].intValue) }
        return top
    }
}
