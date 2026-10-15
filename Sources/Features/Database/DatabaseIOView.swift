import SwiftUI

/// Вкладка «Файлы» (на сайте — «Импорт и экспорт»).
///
/// Экспорт: POST /api/admin/db/backup {tables:[…], code|password} → {file, size, how};
///   ничего не отмечено — выгрузится вся база; файл появляется во вкладке «Копии».
/// Импорт: POST /api/admin/db/import multipart: file (.sql / .sql.gz) + code|password
///   → {executed, safety, file}; перед импортом сервер сам снимает страховочную копию.
struct DatabaseIOTab: View {
    @ObservedObject var overview: ObjectLoader

    @State private var selected: Set<String> = []
    @State private var filter = ""
    @State private var showPicker = false
    @State private var pickedURL: URL?
    @State private var pickedSize: Int = 0
    @State private var pickError: String?
    @State private var confirm: DatabaseConfirmRequest?

    init(overview: ObjectLoader) {
        self.overview = overview
    }

    private var has2FA: Bool { overview.data["has_2fa"].boolValue }
    private var dbName: String { overview.data["db_name"].string ?? overview.data["summary"]["database"].stringValue }

    private var tableNames: [String] {
        let all = overview.data["tables"].array.compactMap { $0["name"].string }
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        AsyncContent(state: overview.state, retry: { await overview.load() }) {
            List {
                importSection
                exportSection
            }
            .listStyle(.insetGrouped)
        }
        .sheet(isPresented: $showPicker) {
            DatabaseDocumentPicker { url in
                picked(url)
            }
        }
        .sheet(item: $confirm) { req in
            DatabaseConfirmSheet(request: req, has2FA: has2FA)
        }
    }

    // MARK: - Экспорт

    private var exportSection: some View {
        Section {
            Button {
                askExport()
            } label: {
                Label(selected.isEmpty ? "Выгрузить всю базу" : "Выгрузить выбранные (" + String(selected.count) + ")",
                      systemImage: "square.and.arrow.up.on.square")
            }
            if !selected.isEmpty {
                Button("Снять отметки") { selected = [] }
                    .foregroundColor(Brand.red)
            }
            TextField("Найти таблицу", text: $filter)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            ForEach(tableNames, id: \.self) { name in
                Button {
                    toggle(name)
                } label: {
                    HStack {
                        Image(systemName: selected.contains(name) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selected.contains(name) ? Brand.accent : Brand.muted)
                        Text(name)
                            .font(.footnote.monospaced())
                            .foregroundColor(Brand.text)
                    }
                }
            }
        } header: {
            Text("Экспорт")
        } footer: {
            Text("Ничего не отмечено — выгрузится вся база. Файл появится во вкладке «Копии», оттуда его можно скачать.")
        }
    }

    private func toggle(_ name: String) {
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
        Haptics.tap()
    }

    private func askExport() {
        let tables = selected.sorted()
        let what: String = tables.isEmpty
            ? "Будет создан файл со всей базой, включая персональные данные покупателей."
            : "Будет создан файл с содержимым таблиц: " + tables.joined(separator: ", ") + "."
        let reload = overview
        confirm = DatabaseConfirmRequest(
            title: tables.isEmpty ? "Снять копию базы" : "Снять копию выбранных таблиц",
            message: what, confirmLabel: "Выгрузить", longRunning: true
        ) { extra in
            var payload = extra
            payload["tables"] = tables
            let finalPayload = payload
            let res = try await DatabaseLongCall.json("POST", "/api/admin/db/backup", body: finalPayload, timeout: 660)
            let d = res.result.data
            await reload.load()
            let text: String = "Готово: " + d["file"].stringValue + " (" + DatabaseFmt.size(d["size"]) + "). Файл — во вкладке «Копии»."
            return DatabaseOutcome(text: text)
        }
    }

    // MARK: - Импорт

    private var importSection: some View {
        Section {
            Button {
                pickError = nil
                showPicker = true
            } label: {
                Label(pickedURL == nil ? "Выбрать файл .sql или .sql.gz" : "Выбрать другой файл", systemImage: "doc.badge.plus")
            }
            if let url = pickedURL {
                KVRow("Файл", url.lastPathComponent)
                KVRow("Размер", DatabaseFmt.size(pickedSize))
                Button(role: .destructive) {
                    askImport(url)
                } label: {
                    Label("Выполнить импорт", systemImage: "exclamationmark.triangle")
                }
            }
            if let e = pickError {
                Text(e)
                    .font(.footnote)
                    .foregroundColor(Brand.red)
            }
        } header: {
            Text("Импорт")
        } footer: {
            Text("Файл .sql или .sql.gz будет выполнен на этой базе. Перед импортом автоматически снимется страховочная копия текущего состояния — если что-то пойдёт не так, будет куда вернуться.")
        }
    }

    private func picked(_ url: URL) {
        let lower = url.lastPathComponent.lowercased()
        guard lower.hasSuffix(".sql") || lower.hasSuffix(".gz") else {
            pickedURL = nil
            pickError = "Нужен файл .sql или .sql.gz"
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        pickedURL = url
        pickedSize = size
        pickError = nil
    }

    private func askImport(_ url: URL) {
        let name = url.lastPathComponent
        let mime = name.lowercased().hasSuffix(".gz") ? "application/gzip" : "application/sql"
        let what: String = "Файл «" + name + "» (" + DatabaseFmt.size(pickedSize) + ") будет выполнен на базе «" + dbName + "». Это может изменить или удалить данные."
        let reload = overview
        confirm = DatabaseConfirmRequest(
            title: "Выполнить импорт", message: what,
            phrase: "ИМПОРТ", confirmLabel: "Импортировать", longRunning: true
        ) { extra in
            let fileData: Data
            do {
                fileData = try Data(contentsOf: url)
            } catch {
                throw APIError.badResponse("Не удалось прочитать файл: " + error.localizedDescription)
            }
            var fields: [String: String] = [:]
            for (k, v) in extra {
                if let s = v as? String { fields[k] = s }
            }
            let finalFields = fields
            do {
                let res = try await DatabaseLongCall.multipart("/api/admin/db/import", fileData: fileData, fileName: name,
                                                               mime: mime, fields: finalFields, timeout: 960)
                let d = res.result.data
                await reload.load()
                let text: String = "Импорт выполнен, запросов: " + Fmt.number(d["executed"]) + ". Страховочная копия: " + d["safety"].stringValue
                return DatabaseOutcome(text: text)
            } catch let e as APIError {
                throw DatabaseBackupsTab.withSafety(e)
            }
        }
    }
}
