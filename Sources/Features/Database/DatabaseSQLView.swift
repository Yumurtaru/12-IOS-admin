import SwiftUI

/// Вкладка «SQL»: консоль. SELECT/SHOW/DESCRIBE/EXPLAIN выполняются сразу,
/// всё остальное — после подтверждения (фраза «ВЫПОЛНИТЬ» + код 2FA или пароль).
///
/// POST /api/admin/db/sql {sql, code|password} (rate 30/мин)
///   → {statements:[{sql, kind: read|write, ok, ms, rows?, count?, truncated?, affected?, error?}], kind}
/// Несколько запросов через «;» выполняются по очереди и останавливаются на первой ошибке.
/// Сервер сам решает, чтение это или запись: если приложение сочло запрос чтением,
/// а сервер потребовал подтверждение (403 need), — показываем подтверждение.
struct DatabaseSQLTab: View {
    let has2FA: Bool

    @AppStorage("admin.db.sqlDraft") private var sqlText = ""
    @State private var running = false
    @State private var error: String?
    @State private var results: [DatabaseSQLResult] = []
    @State private var resultKind: String?
    @State private var confirm: DatabaseConfirmRequest?
    @State private var openRow: DatabaseSQLRowTarget?

    init(has2FA: Bool) {
        self.has2FA = has2FA
    }

    private var trimmed: String { sqlText.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                editorCard
                if let e = error {
                    ErrorBanner(message: e, dismiss: { error = nil })
                }
                if let k = resultKind {
                    Text(k == "write" ? "Запрос изменял данные" : "Запрос только читал данные")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
                ForEach(results) { r in
                    DatabaseSQLResultCard(result: r, onOpenRow: { row in
                        openRow = DatabaseSQLRowTarget(row: row, columns: r.columns)
                    })
                }
            }
            .padding(12)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $confirm) { req in
            DatabaseConfirmSheet(request: req, has2FA: has2FA)
        }
        .sheet(item: $openRow) { t in
            DatabaseRowSheet(row: t.row, columns: t.columns)
        }
    }

    private var editorCard: some View {
        SectionCard("SQL-запрос") {
            TextEditor(text: $sqlText)
                .font(.footnote.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: 150)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Brand.border, lineWidth: 1)
                }
            Text("SELECT выполняется сразу. Любой запрос, который меняет данные, потребует подтверждения. Можно несколько запросов через точку с запятой — выполнятся по очереди и остановятся на первой ошибке.")
                .font(.caption)
                .foregroundColor(Brand.muted)
            HStack {
                Button {
                    run()
                } label: {
                    HStack(spacing: 6) {
                        if running { ProgressView() } else { Image(systemName: "play.fill") }
                        Text("Выполнить")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty || running)
                Spacer()
                if !sqlText.isEmpty {
                    Button("Очистить") {
                        sqlText = ""
                        results = []
                        resultKind = nil
                        error = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(running)
                }
            }
        }
    }

    // MARK: - Выполнение

    private func run() {
        let text = trimmed
        guard !text.isEmpty, !running else { return }
        error = nil
        if DatabaseFmt.looksLikeWrite(text) {
            askConfirm(text)
            return
        }
        running = true
        Task { @MainActor in
            do {
                let out = try await DatabaseSQLTab.execute(text, extra: [:])
                running = false
                apply(out)
            } catch {
                running = false
                handle(error, sql: text)
            }
        }
    }

    private func handle(_ err: Error, sql: String) {
        if APIError.isCancellation(err) { return }
        if let e = err as? APIError, e.status == 403, let need = e.details["need"].string,
           need == "2fa" || need == "password" {
            // Сервер счёл запрос записью — нужно подтверждение.
            askConfirm(sql)
            return
        }
        Haptics.error()
        error = APIError.describe(err)
    }

    private func askConfirm(_ text: String) {
        let preview = String(text.prefix(300))
        confirm = DatabaseConfirmRequest(
            title: "Выполнить запрос",
            message: "Этот запрос может изменить или удалить данные:\n\n" + preview,
            phrase: "ВЫПОЛНИТЬ", confirmLabel: "Выполнить", longRunning: true
        ) { extra in
            let out = try await DatabaseSQLTab.execute(text, extra: extra)
            await MainActor.run { apply(out) }
            return nil
        }
    }

    private func apply(_ out: DatabaseSQLOutput) {
        results = out.results
        resultKind = out.kind
        Haptics.success()
    }

    /// Выполнить запрос и разложить ответ, сохранив порядок колонок из сырого JSON.
    static func execute(_ sql: String, extra: [String: Any?]) async throws -> DatabaseSQLOutput {
        var payload = extra
        payload["sql"] = sql
        let finalPayload = payload
        let res = try await DatabaseLongCall.json("POST", "/api/admin/db/sql", body: finalPayload, timeout: 300)
        let data = res.result.data
        let orders = DatabaseKeyOrder.rowsKeyOrders(res.rawData)
        var list: [DatabaseSQLResult] = []
        var orderIndex = 0
        for (i, st) in data["statements"].array.enumerated() {
            var cols: [String] = []
            if st["rows"].isArray {
                let preferred: [String]? = orderIndex < orders.count ? orders[orderIndex] : nil
                orderIndex += 1
                let first = st["rows"][0]
                if first.isObject { cols = DatabaseKeyOrder.columns(of: first, preferred: preferred) }
            }
            list.append(DatabaseSQLResult(index: i, statement: st, columns: cols))
        }
        return DatabaseSQLOutput(results: list, kind: data["kind"].string)
    }
}

/// Ответ консоли.
struct DatabaseSQLOutput {
    let results: [DatabaseSQLResult]
    let kind: String?

    init(results: [DatabaseSQLResult], kind: String?) {
        self.results = results
        self.kind = kind
    }
}

/// Результат одного запроса.
struct DatabaseSQLResult: Identifiable {
    let index: Int
    let statement: JSON
    let columns: [String]

    var id: Int { index }

    init(index: Int, statement: JSON, columns: [String]) {
        self.index = index
        self.statement = statement
        self.columns = columns
    }
}

/// Строка результата, открытая целиком.
struct DatabaseSQLRowTarget: Identifiable {
    let id = UUID()
    let row: JSON
    let columns: [String]

    init(row: JSON, columns: [String]) {
        self.row = row
        self.columns = columns
    }
}

/// Карточка результата запроса (как на сайте: текст запроса · мс, ошибка / затронуто / таблица).
struct DatabaseSQLResultCard: View {
    let result: DatabaseSQLResult
    let onOpenRow: (JSON) -> Void

    init(result: DatabaseSQLResult, onOpenRow: @escaping (JSON) -> Void) {
        self.result = result
        self.onOpenRow = onOpenRow
    }

    private var st: JSON { result.statement }
    private var rows: [JSON] { st["rows"].array }

    private var head: String {
        st["sql"].stringValue + " · " + Fmt.number(st["ms"]) + " мс"
    }

    var body: some View {
        SectionCard(nil) {
            Text(head)
                .font(.caption.monospaced())
                .foregroundColor(Brand.muted)
                .lineLimit(4)
                .textSelection(.enabled)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if !st["ok"].boolValue {
            Text(st["error"].nonEmptyString ?? "Ошибка")
                .font(.footnote)
                .foregroundColor(Brand.red)
                .textSelection(.enabled)
        } else if st["kind"].string == "write" {
            Text("Затронуто строк: " + Fmt.number(st["affected"]))
                .font(.subheadline.weight(.semibold))
        } else if rows.isEmpty {
            Text("Пусто")
                .foregroundColor(Brand.muted)
        } else {
            if st["truncated"].boolValue {
                Text("Показаны первые " + String(rows.count) + " из " + Fmt.number(st["count"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            } else {
                Text(Fmt.plural(rows.count, "строка", "строки", "строк") + " · нажмите строку, чтобы открыть целиком")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            DatabaseGrid(columns: result.columns, rows: rows, onTap: onOpenRow)
        }
    }
}
