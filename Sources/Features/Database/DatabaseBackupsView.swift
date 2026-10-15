import SwiftUI

/// Вкладка «Копии»: снять копию базы / архив сайта, скачать, восстановить, удалить.
///
/// GET    /api/admin/db/backups                → {backups:[{name, type: db|site, size, created_at}]}
/// POST   /api/admin/db/backup      {tables?, code|password} → {file, size, how}   (долго)
/// POST   /api/admin/db/backup/site {code|password}          → {file, size, files} (долго)
/// POST   /api/admin/db/backup/ticket {name, code|password}  → {ticket, expires_in}
/// GET    /api/admin/db/backup/download ?name&ticket         → файл потоком (403 need=ticket — билет истёк)
/// POST   /api/admin/db/restore {name, code|password}        → {executed, safety, …} (долго)
/// DELETE /api/admin/db/backup  {name, code|password}        → {deleted}
struct DatabaseBackupsTab: View {
    @ObservedObject var overview: ObjectLoader
    @StateObject private var loader = ObjectLoader(path: "/api/admin/db/backups")
    @State private var confirm: DatabaseConfirmRequest?

    init(overview: ObjectLoader) {
        self.overview = overview
    }

    private var has2FA: Bool { overview.data["has_2fa"].boolValue }
    /// Архив сайта требует расширения PHP zip (caps.zip); пока обзор не загружен — не блокируем.
    private var zipAvailable: Bool { overview.data["caps"]["zip"].bool ?? true }
    private var backups: [JSON] { loader.data["backups"].array }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            List {
                if let e = loader.lastRefreshError {
                    Section { ErrorBanner(message: e, retry: { Task { await loader.load() } }) }
                }
                createSection
                Section {
                    if backups.isEmpty {
                        Text("Копий пока нет")
                            .foregroundColor(Brand.muted)
                    }
                    ForEach(backups, id: \.self) { b in
                        DatabaseBackupRow(backup: b,
                                          onDownload: { askDownload(b) },
                                          onRestore: { askRestore(b) },
                                          onDelete: { askDelete(b) })
                    }
                } header: {
                    Text("Сохранённые копии")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await reloadAll() }
        }
        .task { await loader.loadIfNeeded() }
        .sheet(item: $confirm) { req in
            DatabaseConfirmSheet(request: req, has2FA: has2FA)
        }
    }

    private var createSection: some View {
        Section {
            Button {
                askBackupDB()
            } label: {
                Label("Копия базы", systemImage: "cylinder.split.1x2")
            }
            Button {
                askBackupSite()
            } label: {
                Label("Копия сайта", systemImage: "archivebox")
            }
            .disabled(!zipAvailable)
        } header: {
            Text("Создать копию")
        } footer: {
            Text(zipAvailable
                 ? "Копия базы — дамп всех таблиц. Копия сайта — архив всех файлов проекта (кроме самих копий, кэша и логов). Оба файла лежат вне доступа из интернета и скачиваются только отсюда."
                 : "Копия сайта недоступна: на сервере нет расширения PHP zip.")
        }
    }

    private func reloadAll() async {
        await loader.load()
        await overview.load()
    }

    // MARK: - Действия

    private func askBackupDB() {
        confirm = DatabaseConfirmRequest(
            title: "Снять копию базы",
            message: "В файл попадёт вся база целиком, включая персональные данные покупателей.",
            confirmLabel: "Снять копию", longRunning: true
        ) { extra in
            let res = try await DatabaseLongCall.json("POST", "/api/admin/db/backup", body: extra, timeout: 660)
            let d = res.result.data
            await reloadAll()
            let text: String = "Копия готова: " + d["file"].stringValue + " (" + DatabaseFmt.size(d["size"]) + ", " + d["how"].stringValue + ")"
            return DatabaseOutcome(text: text)
        }
    }

    private func askBackupSite() {
        confirm = DatabaseConfirmRequest(
            title: "Снять архив сайта",
            message: "В архив попадут файлы конфигурации с паролями и ключами. Это может занять минуту и больше.",
            confirmLabel: "Снять архив", longRunning: true
        ) { extra in
            let res = try await DatabaseLongCall.json("POST", "/api/admin/db/backup/site", body: extra, timeout: 960)
            let d = res.result.data
            await reloadAll()
            let text: String = "Архив готов: " + d["file"].stringValue + " (" + DatabaseFmt.size(d["size"]) + ", файлов " + Fmt.number(d["files"]) + ")"
            return DatabaseOutcome(text: text)
        }
    }

    private func askDownload(_ b: JSON) {
        let name = b["name"].stringValue
        confirm = DatabaseConfirmRequest(
            title: "Скачать копию",
            message: "Файл «" + name + "» содержит данные всей площадки.",
            confirmLabel: "Скачать", longRunning: true
        ) { extra in
            var payload = extra
            payload["name"] = name
            // Сначала одноразовый билет (подтверждение — обычным POST), потом сам файл по билету.
            let t = try await API.shared.post("/api/admin/db/backup/ticket", body: payload)
            guard let ticket = t["ticket"].nonEmptyString else {
                throw APIError.badResponse("Сервер не выдал разрешение на скачивание. Повторите.")
            }
            let url = try await API.shared.download("/api/admin/db/backup/download",
                                                    query: ["name": name, "ticket": ticket],
                                                    suggestedName: name)
            return DatabaseOutcome(text: "Файл «" + name + "» скачан на телефон.", file: url)
        }
    }

    private func askRestore(_ b: JSON) {
        let name = b["name"].stringValue
        confirm = DatabaseConfirmRequest(
            title: "Восстановить базу",
            message: "Текущее содержимое базы будет ЗАМЕНЕНО на копию «" + name + "». Перед восстановлением автоматически снимется страховочная копия того, что есть сейчас.",
            phrase: "ВОССТАНОВИТЬ", confirmLabel: "Восстановить", longRunning: true
        ) { extra in
            var payload = extra
            payload["name"] = name
            do {
                let res = try await DatabaseLongCall.json("POST", "/api/admin/db/restore", body: payload, timeout: 960)
                let d = res.result.data
                await reloadAll()
                let text: String = "Восстановлено, запросов: " + Fmt.number(d["executed"]) + ". Страховочная копия: " + d["safety"].stringValue
                return DatabaseOutcome(text: text)
            } catch let e as APIError {
                throw DatabaseBackupsTab.withSafety(e)
            }
        }
    }

    private func askDelete(_ b: JSON) {
        let name = b["name"].stringValue
        confirm = DatabaseConfirmRequest(
            title: "Удалить копию",
            message: "Файл «" + name + "» будет удалён навсегда.",
            phrase: "УДАЛИТЬ", confirmLabel: "Удалить"
        ) { extra in
            var payload = extra
            payload["name"] = name
            try await API.shared.delete("/api/admin/db/backup", body: payload)
            await reloadAll()
            return nil
        }
    }

    /// Ошибка восстановления/импорта: добавить страховочную копию и упавший запрос из errors.
    static func withSafety(_ e: APIError) -> APIError {
        let d = e.details
        var extra: [String] = []
        if let s = d["safety"].nonEmptyString { extra.append("Страховочная копия: " + s) }
        if let n = d["executed"].int { extra.append("Выполнено запросов: " + String(n)) }
        if let f = d["failed_sql"].nonEmptyString { extra.append("На запросе: " + String(f.prefix(300))) }
        if extra.isEmpty { return e }
        let text = e.message + "\n" + extra.joined(separator: "\n")
        return APIError.server(status: e.status, message: text, details: d)
    }
}

/// Строка копии: имя, тип, размер, дата; действия — меню и свайп.
struct DatabaseBackupRow: View {
    let backup: JSON
    let onDownload: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void

    init(backup: JSON, onDownload: @escaping () -> Void, onRestore: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.backup = backup
        self.onDownload = onDownload
        self.onRestore = onRestore
        self.onDelete = onDelete
    }

    private var isSite: Bool { backup["type"].string == "site" }

    private var meta: String {
        DatabaseFmt.size(backup["size"]) + " · " + Fmt.date(backup["created_at"])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSite ? "archivebox" : "cylinder.split.1x2")
                .foregroundColor(isSite ? Brand.blue : Brand.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(backup["name"].stringValue)
                    .font(.footnote.weight(.semibold).monospaced())
                    .lineLimit(2)
                HStack(spacing: 6) {
                    StatusBadge(isSite ? "Сайт" : "База", color: isSite ? Brand.blue : Brand.accent)
                    Text(meta)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            Spacer(minLength: 4)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.vertical, 2)
        .contextMenu { menuItems }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onDownload) {
            Label("Скачать", systemImage: "arrow.down.circle")
        }
        if !isSite {
            Button(action: onRestore) {
                Label("Восстановить базу", systemImage: "arrow.counterclockwise")
            }
        }
        Button(role: .destructive, action: onDelete) {
            Label("Удалить", systemImage: "trash")
        }
    }
}
