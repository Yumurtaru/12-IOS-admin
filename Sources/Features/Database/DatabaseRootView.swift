import SwiftUI

/// Раздел «База данных» (admin/database.php) — самый опасный раздел площадки.
///
/// Вкладки как на сайте: Обзор · Копии · Таблицы · SQL · Импорт и экспорт.
/// GET /api/admin/db/overview → {summary{database, tables, bytes, rows_est, server, charset},
///     tables[{name, engine, rows_est, bytes, collation, comment, is_view}], backups[…],
///     caps{shell, zip, gzip, inside_webroot, backup_dir}, has_2fa, db_name}
/// Все изменяющие операции сервер подтверждает кодом 2FA (если включена) или паролем
/// администратора — см. DatabaseConfirmSheet; каждое действие пишется в журнал.
struct DatabaseRootView: View {
    let openId: Int?

    @StateObject private var overview = ObjectLoader(path: "/api/admin/db/overview")
    @State private var tab: DatabaseTab = .overview

    init(openId: Int? = nil) {
        self.openId = openId
    }

    private var has2FA: Bool { overview.data["has_2fa"].boolValue }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Вкладка", selection: $tab) {
                ForEach(DatabaseTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Brand.bg)
        .navigationTitle("База данных")
        .navigationBarTitleDisplayMode(.inline)
        .task { await overview.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            DatabaseOverviewTab(overview: overview)
        case .backups:
            DatabaseBackupsTab(overview: overview)
        case .tables:
            DatabaseTablesTab(overview: overview)
        case .sql:
            DatabaseSQLTab(has2FA: has2FA)
        case .io:
            DatabaseIOTab(overview: overview)
        }
    }
}

/// Вкладки раздела.
enum DatabaseTab: String, CaseIterable, Identifiable {
    case overview, backups, tables, sql, io

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .backups: return "Копии"
        case .tables: return "Таблицы"
        case .sql: return "SQL"
        case .io: return "Файлы"
        }
    }
}

// MARK: - Обзор

/// Сводка: предупреждения (нет 2FA, копии в корне сайта), размеры, возможности сервера.
struct DatabaseOverviewTab: View {
    @ObservedObject var overview: ObjectLoader

    init(overview: ObjectLoader) {
        self.overview = overview
    }

    private var d: JSON { overview.data }
    private var summary: JSON { d["summary"] }
    private var caps: JSON { d["caps"] }

    private var backupsSize: Int {
        var total = 0
        for b in d["backups"].array { total += b["size"].intValue }
        return total
    }

    var body: some View {
        AsyncContent(state: overview.state, retry: { await overview.load() }) {
            List {
                if let e = overview.lastRefreshError {
                    Section { ErrorBanner(message: e, retry: { Task { await overview.load() } }) }
                }
                warnings
                Section("База") {
                    KVRow("Имя базы", summary["database"].string, copyable: true)
                    KVRow("Сервер", summary["server"].string)
                    KVRow("Кодировка", summary["charset"].string)
                    KVRow("Таблиц", Fmt.number(summary["tables"]))
                    KVRow("Размер", DatabaseFmt.size(summary["bytes"]))
                    KVRow("Строк (оценка)", "~" + Fmt.number(summary["rows_est"]))
                }
                Section("Копии") {
                    KVRow("Сохранено копий", Fmt.number(d["backups"].array.count))
                    KVRow("Занимают", DatabaseFmt.size(backupsSize))
                    KVRow("Папка копий", caps["backup_dir"].string, copyable: true)
                }
                Section("Возможности сервера") {
                    KVRow("Двухфакторная аутентификация", d["has_2fa"].boolValue ? "включена" : "выключена")
                    KVRow("mysqldump (shell)", Fmt.yesNo(caps["shell"].bool))
                    KVRow("ZIP (архив сайта)", Fmt.yesNo(caps["zip"].bool))
                    KVRow("GZIP", Fmt.yesNo(caps["gzip"].bool))
                }
                Section {
                    JSONInspectorView(d)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await overview.load() }
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if overview.state == .loaded && !d["has_2fa"].boolValue {
            Section {
                InfoBanner("Двухфакторная аутентификация выключена. В этом разделе можно скачать всю базу и весь код сайта, включая пароли в config/secrets.php. Пока 2FA нет, опасные действия подтверждаются вашим паролем администратора. Включите 2FA в настройках администратора.",
                           systemImage: "exclamationmark.shield.fill", color: Brand.red)
            }
        }
        if caps["inside_webroot"].boolValue {
            Section {
                InfoBanner("Копии лежат внутри корня сайта (" + caps["backup_dir"].stringValue + "). Их закрывает только конфиг веб-сервера. Надёжнее вынести каталог наружу — создайте рядом с корнем сайта папку с именем корня и суффиксом «-backups», с правами на запись для веб-пользователя: копии переедут туда сами.",
                           systemImage: "exclamationmark.triangle.fill", color: Brand.amber)
            }
        }
    }
}

// MARK: - Таблицы

/// Список таблиц (поиск по имени) → просмотр таблицы.
struct DatabaseTablesTab: View {
    @ObservedObject var overview: ObjectLoader
    @State private var query = ""

    init(overview: ObjectLoader) {
        self.overview = overview
    }

    private var has2FA: Bool { overview.data["has_2fa"].boolValue }

    private var tables: [JSON] {
        let all = overview.data["tables"].array
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return all }
        return all.filter { $0["name"].stringValue.lowercased().contains(q) }
    }

    var body: some View {
        AsyncContent(state: overview.state, retry: { await overview.load() }) {
            List {
                Section {
                    TextField("Найти таблицу", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if tables.isEmpty {
                        Text("Таблиц не найдено")
                            .foregroundColor(Brand.muted)
                    }
                    ForEach(tables, id: \.self) { t in
                        NavigationLink {
                            DatabaseTableView(name: t["name"].stringValue, has2FA: has2FA)
                        } label: {
                            DatabaseTableRow(table: t)
                        }
                    }
                } header: {
                    Text("Таблицы: " + String(tables.count))
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await overview.load() }
        }
    }
}

/// Строка таблицы: имя, представление/комментарий, строки, размер, движок.
struct DatabaseTableRow: View {
    let table: JSON

    init(table: JSON) {
        self.table = table
    }

    private var meta: String {
        var parts: [String] = []
        parts.append("~" + Fmt.number(table["rows_est"]) + " строк")
        parts.append(DatabaseFmt.size(table["bytes"]))
        if let e = table["engine"].nonEmptyString { parts.append(e) }
        if let c = table["collation"].nonEmptyString { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(table["name"].stringValue)
                    .font(.subheadline.weight(.semibold).monospaced())
                if table["is_view"].boolValue {
                    StatusBadge("представление", color: Brand.blue)
                }
            }
            if let c = table["comment"].nonEmptyString {
                Text(c)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(meta)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
