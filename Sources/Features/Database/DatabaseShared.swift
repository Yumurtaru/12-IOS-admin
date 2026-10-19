import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Общие части раздела «База данных»: долгие запросы, подтверждение опасных
// операций (код 2FA или пароль + фраза), таблица результатов, выбор файла.

// MARK: - Долгий запрос

/// Запрос с долгим ожиданием ответа (копия базы, архив сайта, восстановление,
/// импорт, тяжёлый SQL, импорт организации в «Парсинге»).
///
/// Обычный `API.shared` ждёт ответа 30 с, а сервер на таких операциях молчит
/// минутами (set_time_limit 600–900). Здесь тот же формат запроса и разбор
/// ответа (`API.unwrap` / `API.error`), но таймаут задаётся на запрос.
/// 401 → один короткий запрос через `API.shared` (он сам обновит токен или
/// разлогинит) и повтор. Сырые байты ответа отдаются тоже — по ним
/// восстанавливается порядок колонок результата SQL.
enum DatabaseLongCall {
    /// Ответ: разобранный конверт и сырые байты.
    struct Output {
        let result: APIResult
        let rawData: Data
    }

    /// JSON-запрос (POST/PUT/DELETE) с долгим таймаутом.
    static func json(_ method: String, _ path: String, body: [String: Any?], timeout: TimeInterval = 900,
                     refreshVia: String = "/api/admin/db/backups") async throws -> Output {
        let data = try JSONBody.data(body)
        return try await perform(method, path, contentType: "application/json", body: data,
                                 timeout: timeout, refreshVia: refreshVia)
    }

    /// multipart/form-data: поля формы + файл (поле `file`).
    static func multipart(_ path: String, fileData: Data, fileName: String, mime: String,
                          fields: [String: String], timeout: TimeInterval = 900) async throws -> Output {
        let boundary = "Boundary-" + UUID().uuidString
        let body = multipartBody(boundary: boundary, fileData: fileData, fileName: fileName, mime: mime, fields: fields)
        return try await perform("POST", path, contentType: "multipart/form-data; boundary=" + boundary,
                                 body: body, timeout: timeout, refreshVia: "/api/admin/db/backups")
    }

    /// Своя сессия: у `API.shared.session` таймаут ожидания данных 30 с задан на всю
    /// сессию (timeoutIntervalForRequest), и он может оборвать запрос раньше, чем
    /// `URLRequest.timeoutInterval`. Cookie общие с API (PHP-сессия, access_token).
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 960
        cfg.timeoutIntervalForResource = 3600
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private static let userAgent: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "YumurtaAdmin/" + v + " (iOS)"
    }()

    private static func perform(_ method: String, _ path: String, contentType: String, body: Data,
                                timeout: TimeInterval, refreshVia: String) async throws -> Output {
        var attempt = 0
        while true {
            attempt += 1
            guard let url = API.url(path) else { throw APIError.badResponse("Неверный адрес запроса") }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            if let token = TokenStore.shared.accessToken {
                req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
            req.httpBody = body
            let pair: (Data, URLResponse)
            do {
                pair = try await session.data(for: req)
            } catch {
                throw API.mapTransport(error)
            }
            let raw = pair.0
            let status = (pair.1 as? HTTPURLResponse)?.statusCode ?? 0
            let json = JSON.parse(raw)
            let env = API.unwrap(json, status: status)
            // Не-JSON ответ 200 (HTML прокси, портал Wi-Fi) — не успех: иначе копия/импорт
            // «прошли» с пустыми данными, а проверка ниже была недостижима.
            if env.ok && json != nil && (200..<300).contains(status) {
                let res = APIResult(data: env.data, meta: env.meta, raw: json ?? .null, status: status)
                return Output(result: res, rawData: raw)
            }
            if status == 401 && attempt == 1 {
                // Токен истёк: короткий запрос через API обновит его (или разлогинит и бросит ошибку).
                _ = try await API.shared.get(refreshVia)
                continue
            }
            if json == nil && (200..<300).contains(status) {
                throw APIError.badResponse("Сервер вернул непонятный ответ. Повторите позже.")
            }
            throw API.error(status: status, message: env.message, details: env.details)
        }
    }

    private static func multipartBody(boundary: String, fileData: Data, fileName: String, mime: String,
                                      fields: [String: String]) -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        for key in fields.keys.sorted() {
            append("--" + boundary + crlf)
            append("Content-Disposition: form-data; name=\"" + key + "\"" + crlf + crlf)
            append((fields[key] ?? "") + crlf)
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "")
        append("--" + boundary + crlf)
        append("Content-Disposition: form-data; name=\"file\"; filename=\"" + safeName + "\"" + crlf)
        append("Content-Type: " + mime + crlf + crlf)
        body.append(fileData)
        append(crlf + "--" + boundary + "--" + crlf)
        return body
    }
}

// MARK: - Форматирование

enum DatabaseFmt {
    /// Байты → «12,3 МБ» (как fmtSize в admin.js).
    static func size(_ bytes: Int) -> String {
        let b = Double(max(0, bytes))
        if b < 1024 { return String(Int(b)) + " Б" }
        if b < 1_048_576 { return one(b / 1024) + " КБ" }
        if b < 1_073_741_824 { return one(b / 1_048_576) + " МБ" }
        return two(b / 1_073_741_824) + " ГБ"
    }

    static func size(_ j: JSON) -> String { size(j.intValue) }

    private static func one(_ v: Double) -> String {
        String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    private static func two(_ v: Double) -> String {
        String(format: "%.2f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// Значение ячейки: NULL — «NULL», остальное — текстом.
    static func cell(_ v: JSON) -> String {
        switch v {
        case .null: return "NULL"
        case .string(let s): return s
        case .bool(let b): return b ? "1" : "0"
        case .number: return v.string ?? ""
        case .array, .object: return v.compactText
        }
    }

    /// Значение для поля ввода (NULL → пусто, как в форме сайта).
    static func editValue(_ v: JSON) -> String {
        if v.isNull { return "" }
        return cell(v)
    }

    /// Колонки, которые сервер прячет (DbAdmin::maskedColumns) — их правка ничего не даст.
    static let maskedColumns: Set<String> = ["password_hash", "token_hash", "session_token", "refresh_token", "password"]

    /// Похоже ли на запись (тот же грубый признак, что у сайта; окончательно решает сервер).
    static func looksLikeWrite(_ sql: String) -> Bool {
        let readPattern = "^\\s*(\\(|/\\*|--)*\\s*(select|show|describe|desc|explain|with)\\b"
        let outfilePattern = "\\binto\\s+(outfile|dumpfile)\\b"
        let range = NSRange(sql.startIndex..<sql.endIndex, in: sql)
        let opts: NSRegularExpression.Options = [.caseInsensitive]
        guard let read = try? NSRegularExpression(pattern: readPattern, options: opts),
              let outfile = try? NSRegularExpression(pattern: outfilePattern, options: opts) else { return true }
        let isRead = read.firstMatch(in: sql, options: [], range: range) != nil
        let isOutfile = outfile.firstMatch(in: sql, options: [], range: range) != nil
        // Несколько запросов через «;» — запись, если хоть один не чтение (сервер считает так же).
        let parts = sql.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmpty = parts.filter { !$0.isEmpty }
        if nonEmpty.count > 1 {
            for p in nonEmpty where looksLikeWrite(p) { return true }
            return isOutfile
        }
        return !isRead || isOutfile
    }
}

// MARK: - Порядок колонок

/// Порядок ключей первой строки каждого массива `"rows":[{…}]` в сыром ответе.
///
/// JSON-словарь порядок ключей теряет, а для результата `SELECT name, phone`
/// колонки должны идти в порядке запроса. Сканер проходит текст ответа и
/// записывает ключи первого объекта каждого массива rows (пустой массив — []).
enum DatabaseKeyOrder {
    private struct Frame {
        var isObject: Bool
        var expectKey: Bool
        var lastKey: String?
        var isRowsArray: Bool
        var sawElement: Bool
        var capture: Bool
    }

    static func rowsKeyOrders(_ data: Data, arrayKey: String = "rows") -> [[String]] {
        let b = [UInt8](data)
        var result: [[String]] = []
        var stack: [Frame] = []
        var i = 0
        let quote = UInt8(ascii: "\"")
        while i < b.count {
            let c = b[i]
            if c == quote {
                let end = stringEnd(b, from: i)
                let isKey = stack.last.map { $0.isObject && $0.expectKey } ?? false
                if isKey {
                    let key = decode(b, from: i, to: end)
                    var top = stack[stack.count - 1]
                    top.lastKey = key
                    top.expectKey = false
                    stack[stack.count - 1] = top
                    if top.capture, !result.isEmpty { result[result.count - 1].append(key) }
                } else {
                    markElement(&stack)
                }
                i = end + 1
                continue
            }
            switch c {
            case UInt8(ascii: "{"):
                let parentRows = stack.last.map { $0.isRowsArray && !$0.sawElement } ?? false
                markElement(&stack)
                stack.append(Frame(isObject: true, expectKey: true, lastKey: nil, isRowsArray: false,
                                   sawElement: false, capture: parentRows))
            case UInt8(ascii: "["):
                let isRows = stack.last.map { $0.isObject && $0.lastKey == arrayKey } ?? false
                markElement(&stack)
                if isRows { result.append([]) }
                stack.append(Frame(isObject: false, expectKey: false, lastKey: nil, isRowsArray: isRows,
                                   sawElement: false, capture: false))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if !stack.isEmpty { stack.removeLast() }
            case UInt8(ascii: ","):
                if var top = stack.last, top.isObject {
                    top.expectKey = true
                    stack[stack.count - 1] = top
                }
            default:
                // Числа/литералы внутри массива — тоже элемент.
                let isSpace = c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == UInt8(ascii: ":")
                if !isSpace { markElement(&stack) }
            }
            i += 1
        }
        return result
    }

    private static func markElement(_ stack: inout [Frame]) {
        guard var top = stack.last, !top.isObject else { return }
        top.sawElement = true
        stack[stack.count - 1] = top
    }

    /// Индекс закрывающей кавычки строки, начатой в `from`.
    private static func stringEnd(_ b: [UInt8], from: Int) -> Int {
        var j = from + 1
        while j < b.count {
            if b[j] == UInt8(ascii: "\\") { j += 2; continue }
            if b[j] == UInt8(ascii: "\"") { return j }
            j += 1
        }
        return b.count - 1
    }

    private static func decode(_ b: [UInt8], from: Int, to: Int) -> String {
        guard to > from, to < b.count else { return "" }
        let slice = Data(b[from...to])
        if let s = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) as? String {
            return s
        }
        return String(decoding: b[(from + 1)..<to], as: UTF8.self)
    }

    /// Колонки строки в порядке сервера, если порядок известен и совпадает с набором ключей.
    static func columns(of row: JSON, preferred: [String]?) -> [String] {
        let keys = row.object.keys
        if let p = preferred, p.count == keys.count, Set(p) == Set(keys) { return p }
        return JSONNodeList.orderedKeys(row.object)
    }
}

// MARK: - Подтверждение опасной операции

/// Что делать после подтверждения: перед вызовом в тело запроса подмешивается
/// `{"code": …}` (2FA включена) или `{"password": …}` (выключена) — ровно как confirmDanger() сайта.
struct DatabaseConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Фраза, которую надо набрать руками (nil — только код/пароль).
    let phrase: String?
    let confirmLabel: String
    /// Операция долгая (копия, восстановление, импорт) — предупредить не закрывать.
    let longRunning: Bool
    /// Само действие. Возвращает итог для показа (nil — просто закрыть лист).
    let perform: ([String: Any?]) async throws -> DatabaseOutcome?

    init(title: String, message: String, phrase: String? = nil, confirmLabel: String = "Подтверждаю",
         longRunning: Bool = false, perform: @escaping ([String: Any?]) async throws -> DatabaseOutcome?) {
        self.title = title
        self.message = message
        self.phrase = phrase
        self.confirmLabel = confirmLabel
        self.longRunning = longRunning
        self.perform = perform
    }
}

/// Итог опасной операции: текст и, при скачивании, файл.
struct DatabaseOutcome {
    let text: String
    let file: URL?

    init(text: String, file: URL? = nil) {
        self.text = text
        self.file = file
    }
}

/// Лист подтверждения: (фраза) + код 2FA или пароль администратора.
///
/// Сервер (dbConfirm) отвечает 403 с `errors.need`:
///   "2fa" — нужен/неверен/использован код (reason: bad/used) → поле кода;
///   "password" — нужен/неверен пароль → поле пароля;
///   "setup" — нет ни пароля, ни 2FA: подтвердить нечем (текст сервера объясняет, что сделать).
/// 429 — слишком много неудачных попыток. Лист не закрывается, текст ошибки виден.
struct DatabaseConfirmSheet: View {
    let request: DatabaseConfirmRequest

    @Environment(\.dismiss) private var dismiss
    @State private var useCode: Bool
    @State private var typed = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?
    @State private var blocked = false
    @State private var outcome: DatabaseOutcome?
    @State private var shared: SharedFile?

    init(request: DatabaseConfirmRequest, has2FA: Bool) {
        self.request = request
        _useCode = State(initialValue: has2FA)
    }

    private var phraseOK: Bool {
        guard let p = request.phrase else { return true }
        let want = p.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let got = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !want.isEmpty && want == got
    }

    private var canRun: Bool {
        phraseOK && !secret.trimmingCharacters(in: .whitespaces).isEmpty && !busy && !blocked
    }

    var body: some View {
        NavigationStack {
            Group {
                if let o = outcome {
                    DatabaseOutcomeView(outcome: o, onShare: { url in shared = SharedFile(url: url) },
                                        onClose: { dismiss() })
                } else {
                    form
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if outcome == nil {
                        Button("Отмена") { dismiss() }.disabled(busy)
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .sheet(item: $shared) { f in
            ShareSheet(items: [f.url])
        }
    }

    private var form: some View {
        Form {
            Section {
                Text(request.message)
                Text("Действие попадёт в журнал администратора.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
            }
            if let p = request.phrase {
                Section {
                    TextField("Введите для подтверждения", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(busy)
                } header: {
                    Text("Чтобы подтвердить, введите: «" + p + "»")
                }
            }
            Section {
                credentialField
            } header: {
                Text(useCode ? "Код двухфакторной аутентификации" : "Ваш пароль администратора")
            } footer: {
                Text(useCode ? "6 цифр из приложения-аутентификатора. Один код — одна операция."
                             : "Двухфакторная аутентификация выключена, поэтому сервер просит пароль.")
            }
            if let e = error {
                Section { ErrorBanner(message: e) }
            }
            Section {
                Button(role: .destructive) {
                    run()
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text(request.confirmLabel).bold() }
                        Spacer()
                    }
                }
                .disabled(!canRun)
            } footer: {
                if busy && request.longRunning {
                    Text("Это может занять несколько минут. Не закрывайте приложение и не блокируйте телефон.")
                }
            }
        }
    }

    @ViewBuilder
    private var credentialField: some View {
        if useCode {
            TextField("000000", text: $secret)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title3.monospacedDigit())
                .disabled(busy)
        } else {
            SecureField("Пароль", text: $secret)
                .textContentType(.password)
                .disabled(busy)
        }
    }

    private func run() {
        guard canRun else { return }
        busy = true
        error = nil
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra: [String: Any?] = useCode ? ["code": value] : ["password": value]
        let work = request.perform
        Task { @MainActor in
            do {
                let result = try await work(extra)
                busy = false
                Haptics.success()
                if let r = result {
                    outcome = r
                } else {
                    dismiss()
                }
            } catch {
                busy = false
                handle(error)
            }
        }
    }

    private func handle(_ err: Error) {
        if APIError.isCancellation(err) { return }
        Haptics.error()
        if let e = err as? APIError {
            switch e.details["need"].string ?? "" {
            case "2fa":
                useCode = true
                secret = ""
            case "password":
                useCode = false
                secret = ""
            case "setup":
                blocked = true
            default:
                break
            }
        }
        error = APIError.describe(err)
    }
}

/// Итог операции внутри листа подтверждения (с «Поделиться» для скачанного файла).
struct DatabaseOutcomeView: View {
    let outcome: DatabaseOutcome
    let onShare: (URL) -> Void
    let onClose: () -> Void

    init(outcome: DatabaseOutcome, onShare: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        self.outcome = outcome
        self.onShare = onShare
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(Brand.green)
            Text(outcome.text)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 24)
            if let url = outcome.file {
                Button {
                    onShare(url)
                } label: {
                    Label("Сохранить в «Файлы» или отправить", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Text("Файл содержит данные всей площадки — храните его надёжно.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button("Готово", action: onClose)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Таблица результатов

/// Таблица строк с горизонтальной прокруткой (SQL-консоль). Большие выборки
/// показываются по 100 строк с кнопкой «Показать ещё».
struct DatabaseGrid: View {
    let columns: [String]
    let rows: [JSON]
    let onTap: ((JSON) -> Void)?

    @State private var limit = 100
    private let cellWidth: CGFloat = 150

    init(columns: [String], rows: [JSON], onTap: ((JSON) -> Void)? = nil) {
        self.columns = columns
        self.rows = rows
        self.onTap = onTap
    }

    private var shown: [JSON] { Array(rows.prefix(limit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    ForEach(Array(shown.enumerated()), id: \.offset) { pair in
                        dataRow(pair.element, index: pair.offset)
                    }
                }
            }
            if rows.count > limit {
                Button("Показать ещё (" + String(rows.count - limit) + ")") {
                    limit += 100
                }
                .font(.footnote)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { c in
                Text(c)
                    .font(.caption.weight(.semibold).monospaced())
                    .lineLimit(1)
                    .frame(width: cellWidth, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
            }
        }
        .background(Brand.chip)
    }

    private func dataRow(_ row: JSON, index: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { c in
                DatabaseCellText(value: row[c])
                    .frame(width: cellWidth, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
            }
        }
        .background(index % 2 == 1 ? Brand.chip.opacity(0.35) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if let t = onTap { t(row) }
        }
    }
}

/// Ячейка: NULL серым, остальное моноширинным текстом в 3 строки.
struct DatabaseCellText: View {
    let value: JSON

    init(value: JSON) {
        self.value = value
    }

    var body: some View {
        Text(DatabaseFmt.cell(value))
            .font(.caption.monospaced())
            .foregroundColor(value.isNull ? Brand.muted : Brand.text)
            .lineLimit(3)
    }
}

/// Одна строка целиком: «колонка — значение» (лист из SQL-консоли).
struct DatabaseRowSheet: View {
    let row: JSON
    let columns: [String]
    @Environment(\.dismiss) private var dismiss

    init(row: JSON, columns: [String]) {
        self.row = row
        self.columns = columns
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(columns, id: \.self) { c in
                    DatabaseValueRow(name: c, value: row[c], note: nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Строка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

/// «Колонка — значение» в столбик (длинные значения целиком, долгое нажатие копирует).
struct DatabaseValueRow: View {
    let name: String
    let value: JSON
    let note: String?

    init(name: String, value: JSON, note: String?) {
        self.name = name
        self.value = value
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name)
                    .font(.caption.monospaced())
                    .foregroundColor(Brand.muted)
                if let n = note {
                    Text(n)
                        .font(.caption2)
                        .foregroundColor(Brand.muted)
                }
            }
            Text(DatabaseFmt.cell(value))
                .font(.footnote.monospaced())
                .foregroundColor(value.isNull ? Brand.muted : Brand.text)
                .textSelection(.enabled)
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = DatabaseFmt.editValue(value)
                Haptics.tap()
            } label: { Label("Скопировать значение", systemImage: "doc.on.doc") }
        }
    }
}

// MARK: - Выбор файла

/// Выбор файла .sql / .sql.gz из «Файлов» (копия во временную папку).
struct DatabaseDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
