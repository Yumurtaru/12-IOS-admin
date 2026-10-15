import SwiftUI
import UIKit

/// Просмотр таблицы: поиск по всем колонкам, сортировка, страницы по 50,
/// строка целиком, правка/добавление/удаление (подтверждение + фраза = имя таблицы), структура.
///
/// GET    /api/admin/db/table/{name} ?page&per_page&q&order&dir
///        → {rows, total, page, pages, columns[{name, type, nullable, key, default, extra, comment}], pk[]}
/// GET    /api/admin/db/table/{name}/ddl → {sql}
/// POST   /api/admin/db/table/{name}/row {data, code|password}     → {inserted, id}
/// PUT    /api/admin/db/table/{name}/row {pk, data, code|password} → {updated}
/// DELETE /api/admin/db/table/{name}/row {pk, code|password}       → {deleted}
/// Без первичного ключа сервер править/удалять не даёт — кнопок нет, как на сайте.
struct DatabaseTableView: View {
    let name: String
    let has2FA: Bool

    @StateObject private var model: PagedListModel
    @State private var editor: DatabaseEditorTarget?

    init(name: String, has2FA: Bool) {
        self.name = name
        self.has2FA = has2FA
        let path = "/api/admin/db/table/" + DatabaseTableView.encode(name)
        _model = StateObject(wrappedValue: PagedListModel(path: path, itemsKey: "rows", searchParam: "q",
                                                          perPage: ("per_page", 50)))
    }

    static func encode(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? name
    }

    private var columns: [JSON] { model.lastData["columns"].array }
    private var columnNames: [String] { columns.compactMap { $0["name"].string } }
    private var pk: [String] { model.lastData["pk"].array.compactMap { $0.string } }
    private var order: String? { model.filter("order") }
    private var descending: Bool { model.filter("dir") == "desc" }

    var body: some View {
        List {
            headerSection
            if let err = model.refreshError {
                ErrorBanner(message: err, retry: { Task { await model.refresh() } })
                    .listRowSeparator(.hidden)
            }
            stateSection
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
        .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Поиск по всем колонкам")
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                sortMenu
            }
        }
        .sheet(item: $editor) { target in
            DatabaseRowEditor(table: name, columns: columns, pk: pk, row: target.row, has2FA: has2FA) {
                Task { await model.refresh() }
            }
        }
        .task { await model.loadIfNeeded() }
    }

    /// Шапка — отдельными строками списка (несколько кнопок в одной строке List срабатывают разом).
    @ViewBuilder
    private var headerSection: some View {
        Text(totalText)
            .font(.subheadline)
            .foregroundColor(Brand.muted)
        NavigationLink {
            DatabaseDDLView(table: name)
        } label: {
            Label("Структура таблицы", systemImage: "doc.text")
        }
        if model.state == .loaded || model.state == .empty(nil) {
            Button {
                editor = DatabaseEditorTarget(row: nil)
            } label: {
                Label("Добавить строку", systemImage: "plus")
            }
            .disabled(columns.isEmpty)
        }
        if model.state == .loaded && pk.isEmpty {
            InfoBanner("У таблицы нет первичного ключа — править и удалять строки отсюда нельзя, используйте вкладку SQL.",
                       systemImage: "key.slash", color: Brand.amber)
                .listRowSeparator(.hidden)
        }
    }

    private var totalText: String {
        let t = model.total ?? model.items.count
        var s = Fmt.plural(t, "строка", "строки", "строк")
        if let o = order { s += " · по " + o + (descending ? " ↓" : " ↑") }
        return s
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
            EmptyStateView(title: "Строк нет", systemImage: "tablecells")
                .frame(minHeight: 200)
                .listRowSeparator(.hidden)
        case .loaded:
            ForEach(Array(model.items.enumerated()), id: \.offset) { pair in
                NavigationLink {
                    DatabaseRowView(table: name, row: pair.element, columns: columns, pk: pk, has2FA: has2FA) {
                        Task { await model.refresh() }
                    }
                } label: {
                    DatabaseRowSummary(row: pair.element, columns: columnNames, pk: pk)
                }
                .task { await model.loadMoreIfNeeded(current: pair.element) }
            }
            ListFooter(model: model)
        }
    }

    /// Сортировка по колонке: повторный выбор той же — смена направления (как клик по заголовку на сайте).
    private var sortMenu: some View {
        Menu {
            if order != nil {
                Button {
                    model.setFilter("order", nil)
                    model.setFilter("dir", nil)
                } label: {
                    Label("Без сортировки", systemImage: "xmark")
                }
            }
            ForEach(columnNames, id: \.self) { c in
                Button {
                    sort(by: c)
                } label: {
                    if order == c {
                        Label(c, systemImage: descending ? "arrow.down" : "arrow.up")
                    } else {
                        Text(c)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .disabled(columnNames.isEmpty)
    }

    private func sort(by column: String) {
        let newDir = (order == column && !descending) ? "desc" : "asc"
        if order != column { model.setFilter("order", column) }
        model.setFilter("dir", newDir)
    }
}

/// Что открыть в редакторе: nil — новая строка.
struct DatabaseEditorTarget: Identifiable {
    let id = UUID()
    let row: JSON?

    init(row: JSON?) {
        self.row = row
    }
}

/// Строка в списке: ключ и первые колонки.
struct DatabaseRowSummary: View {
    let row: JSON
    let columns: [String]
    let pk: [String]

    init(row: JSON, columns: [String], pk: [String]) {
        self.row = row
        self.columns = columns
        self.pk = pk
    }

    private var title: String {
        if pk.isEmpty { return "Строка" }
        let parts = pk.map { $0 + " = " + DatabaseFmt.cell(row[$0]) }
        return parts.joined(separator: ", ")
    }

    private var preview: [String] {
        let rest = columns.filter { !pk.contains($0) }
        return Array(rest.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospaced())
                .lineLimit(1)
            ForEach(preview, id: \.self) { c in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c)
                        .font(.caption2.monospaced())
                        .foregroundColor(Brand.muted)
                        .lineLimit(1)
                    DatabaseCellText(value: row[c])
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Строка целиком: все колонки + правка/удаление.
struct DatabaseRowView: View {
    let table: String
    let row: JSON
    let columns: [JSON]
    let pk: [String]
    let has2FA: Bool
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editor: DatabaseEditorTarget?
    @State private var confirm: DatabaseConfirmRequest?
    @State private var deleted = false
    @State private var edited = false

    init(table: String, row: JSON, columns: [JSON], pk: [String], has2FA: Bool, onChanged: @escaping () -> Void) {
        self.table = table
        self.row = row
        self.columns = columns
        self.pk = pk
        self.has2FA = has2FA
        self.onChanged = onChanged
    }

    private var names: [String] {
        let fromColumns = columns.compactMap { $0["name"].string }
        return fromColumns.isEmpty ? JSONNodeList.orderedKeys(row.object) : fromColumns
    }

    private var pkText: String {
        pk.map { $0 + "=" + DatabaseFmt.cell(row[$0]) }.joined(separator: ", ")
    }

    var body: some View {
        List {
            if !pk.isEmpty {
                Section {
                    Button {
                        editor = DatabaseEditorTarget(row: row)
                    } label: {
                        Label("Править", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        askDelete()
                    } label: {
                        Label("Удалить строку", systemImage: "trash")
                    }
                }
            }
            Section("Колонки") {
                ForEach(names, id: \.self) { c in
                    DatabaseValueRow(name: c, value: row[c], note: note(for: c))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(pk.isEmpty ? "Строка" : pkText)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor, onDismiss: {
            // Строка на экране устарела — вернуться к списку (он обновится).
            if edited { dismiss() }
        }) { target in
            DatabaseRowEditor(table: table, columns: columns, pk: pk, row: target.row, has2FA: has2FA) {
                edited = true
                onChanged()
            }
        }
        .sheet(item: $confirm, onDismiss: {
            if deleted { dismiss() }
        }) { req in
            DatabaseConfirmSheet(request: req, has2FA: has2FA)
        }
    }

    private func note(for column: String) -> String? {
        guard let c = columns.first(where: { $0["name"].string == column }) else { return nil }
        var parts: [String] = [c["type"].stringValue]
        if pk.contains(column) { parts.append("ключ") }
        return parts.joined(separator: ", ")
    }

    private func askDelete() {
        var pkDraft: [String: Any?] = [:]
        for k in pk { pkDraft[k] = row[k].toAny() }
        let pkValues = pkDraft
        let path = "/api/admin/db/table/" + DatabaseTableView.encode(table) + "/row"
        let keyText = pkText
        let done = onChanged
        confirm = DatabaseConfirmRequest(
            title: "Удалить строку",
            message: "Из таблицы «" + table + "» будет удалена строка " + keyText + ".",
            phrase: table, confirmLabel: "Удалить"
        ) { extra in
            var payload = extra
            payload["pk"] = pkValues
            try await API.shared.delete(path, body: payload)
            await MainActor.run {
                deleted = true
                done()
            }
            return nil
        }
    }
}

/// Форма добавления/правки строки. Пустое поле — NULL (при добавлении — значение по умолчанию).
/// При правке отправляются только изменённые колонки: так нетронутые значения
/// (большие числа, даты) не переписываются своим же текстовым видом.
struct DatabaseRowEditor: View {
    let table: String
    let columns: [JSON]
    let pk: [String]
    let row: JSON?
    let has2FA: Bool
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String]
    @State private var confirm: DatabaseConfirmRequest?
    @State private var saved = false
    @State private var notice: String?

    init(table: String, columns: [JSON], pk: [String], row: JSON?, has2FA: Bool, onSaved: @escaping () -> Void) {
        self.table = table
        self.columns = columns
        self.pk = pk
        self.row = row
        self.has2FA = has2FA
        self.onSaved = onSaved
        var v: [String: String] = [:]
        for c in columns {
            guard let n = c["name"].string else { continue }
            v[n] = row.map { DatabaseFmt.editValue($0[n]) } ?? ""
        }
        _values = State(initialValue: v)
    }

    private var isNew: Bool { row == nil }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(columns, id: \.self) { c in
                    fieldRow(c)
                }
                Section {
                    Text(isNew ? "Пустое поле — значение по умолчанию." : "Пустое поле сохраняется как NULL. Отправятся только изменённые поля.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
            }
            .navigationTitle(isNew ? "Новая строка" : "Правка строки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { askSave() }
                }
            }
            .alert(notice ?? "", isPresented: noticeShown) {
                Button("OK", role: .cancel) {}
            }
        }
        .sheet(item: $confirm, onDismiss: {
            if saved {
                onSaved()
                dismiss()
            }
        }) { req in
            DatabaseConfirmSheet(request: req, has2FA: has2FA)
        }
    }

    private var noticeShown: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    @ViewBuilder
    private func fieldRow(_ c: JSON) -> some View {
        let n = c["name"].stringValue
        let auto = c["extra"].stringValue.contains("auto_increment")
        let locked = auto && isNew
        let masked = DatabaseFmt.maskedColumns.contains(n.lowercased())
        Section {
            if (values[n] ?? "").count > 120 {
                TextEditor(text: binding(n))
                    .font(.footnote.monospaced())
                    .frame(minHeight: 100)
                    .disabled(locked)
            } else {
                TextField(locked ? "авто" : "", text: binding(n))
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(locked)
            }
        } header: {
            Text(n)
        } footer: {
            Text(DatabaseRowEditor.columnHint(c, masked: masked))
        }
    }

    static func columnHint(_ c: JSON, masked: Bool) -> String {
        var parts: [String] = [c["type"].stringValue]
        if !c["nullable"].boolValue { parts.append("обязательное") }
        if let k = c["key"].nonEmptyString { parts.append("ключ " + k) }
        if let e = c["extra"].nonEmptyString { parts.append(e) }
        if !c["default"].isNull { parts.append("по умолчанию " + DatabaseFmt.cell(c["default"])) }
        if let cm = c["comment"].nonEmptyString { parts.append(cm) }
        var text = parts.joined(separator: " · ")
        if masked { text += "\nЗначение скрыто сервером — заглушку он обратно не запишет." }
        return text
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    /// Что отправить: новая строка — все непустые поля (кроме авто); правка — только изменённые.
    private func payloadData() -> [String: Any?] {
        var data: [String: Any?] = [:]
        for c in columns {
            guard let n = c["name"].string else { continue }
            let v = values[n] ?? ""
            if let r = row {
                if v != DatabaseFmt.editValue(r[n]) { data[n] = v }
            } else {
                let auto = c["extra"].stringValue.contains("auto_increment")
                if !auto && !v.isEmpty { data[n] = v }
            }
        }
        return data
    }

    private func askSave() {
        let data = payloadData()
        if data.isEmpty {
            notice = isNew ? "Заполните хотя бы одно поле." : "Изменений нет."
            return
        }
        let path = "/api/admin/db/table/" + DatabaseTableView.encode(table) + "/row"
        var pkDraft: [String: Any?] = [:]
        if let r = row {
            for k in pk { pkDraft[k] = r[k].toAny() }
        }
        let pkValues = pkDraft
        let creating = isNew
        let count = data.count
        let addText: String = "В таблицу «" + table + "» будет добавлена строка."
        let editText: String = "В таблице «" + table + "» изменятся поля: " + String(count) + "."
        let what = creating ? addText : editText
        confirm = DatabaseConfirmRequest(
            title: creating ? "Добавить строку" : "Сохранить изменения",
            message: what, phrase: table, confirmLabel: creating ? "Добавить" : "Сохранить"
        ) { extra in
            var payload = extra
            payload["data"] = data
            if creating {
                let r = try await API.shared.post(path, body: payload)
                await MainActor.run { saved = true }
                var added = "Строка добавлена"
                if let newId = r["id"].int { added += ", id " + String(newId) }
                return DatabaseOutcome(text: added + ".")
            }
            payload["pk"] = pkValues
            let r = try await API.shared.put(path, body: payload)
            await MainActor.run { saved = true }
            let n = r["updated"].intValue
            return DatabaseOutcome(text: n > 0 ? "Сохранено." : "Сервер ничего не изменил (значения совпали или строка не найдена).")
        }
    }
}

/// Структура таблицы (SHOW CREATE TABLE).
struct DatabaseDDLView: View {
    let table: String
    @StateObject private var loader: ObjectLoader

    init(table: String) {
        self.table = table
        _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/db/table/" + DatabaseTableView.encode(table) + "/ddl"))
    }

    private var sql: String { loader.data["sql"].stringValue }

    var body: some View {
        AsyncContent(state: loader.state, retry: { await loader.load() }) {
            ScrollView {
                Text(sql)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .navigationTitle("Структура " + table)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = sql
                    Haptics.tap()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(sql.isEmpty)
                .accessibilityLabel("Скопировать")
            }
        }
        .task { await loader.loadIfNeeded() }
    }
}
