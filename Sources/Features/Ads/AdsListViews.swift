import SwiftUI

/// Список объявлений: поиск (заголовок, текст, телефон), статус, категория.
struct AdsListScreen: View {
    @ObservedObject var model: PagedListModel
    @ObservedObject var categories: ObjectLoader
    @ObservedObject var stats: ObjectLoader

    var body: some View {
        AdminListScreen("Объявления", model: model, searchPrompt: "Заголовок, текст или телефон",
                        filters: filters, emptyText: "Объявлений нет",
                        header: AnyView(AdsStatsHeader(stats: stats)),
                        row: { item in AdsRow(ad: item) },
                        destination: { item in AdsAdDetailView(ad: item, model: model, stats: stats) })
            .task {
                await categories.loadIfNeeded()
                await stats.loadIfNeeded()
            }
    }

    private var filters: [ListFilter] {
        var list = [AdsFormat.statusFilter]
        let cats = AdsFormat.flatCategories(categories.data)
        if !cats.isEmpty {
            list.append(ListFilter(key: "category_id", title: "Категория", options: categoryOptions(cats),
                                   allLabel: "Все категории"))
        }
        return list
    }

    private func categoryOptions(_ cats: [JSON]) -> [PickerOption] {
        var out: [PickerOption] = []
        for c in cats {
            guard let id = c.id else { continue }
            let child = !c["parent_id"].isNull
            let name = c["name"].stringValue
            out.append(PickerOption(value: String(id), label: child ? "— " + name : name))
        }
        return out
    }
}

/// Строка объявления.
struct AdsRow: View {
    let ad: JSON

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImageView(path: ad["photo"].string, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                Text(counters)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    priceText
                    StatusBadge(AdsFormat.statusLabel(ad["status"].string),
                                color: AdsFormat.statusColor(ad["status"].string))
                }
                Text(authorLine)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
                if let r = ad["block_reason"].nonEmptyString {
                    Text(r)
                        .font(.caption)
                        .foregroundColor(Brand.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(ad["title"].nonEmptyString ?? "Без заголовка")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if ad["reports"].intValue > 0 {
                StatusBadge("жалоб: " + ad["reports"].stringValue, color: Brand.red)
            }
        }
    }

    @ViewBuilder
    private var priceText: some View {
        if ad["price"].isNull {
            Text("цена не указана").font(.caption).foregroundColor(Brand.muted)
        } else {
            MoneyText(ad["price"]).font(.subheadline)
        }
    }

    private var counters: String {
        let cat = ad["category_name"].nonEmptyString ?? "—"
        let a = "фото " + ad["photos"].stringValue
        let b = "просмотров " + ad["views_count"].stringValue
        let c = "телефон " + ad["contacts_count"].stringValue
        return cat + " · " + a + " · " + b + " · " + c
    }

    private var authorLine: String {
        let name = ad["user_name"].nonEmptyString ?? "—"
        let paid = "оплачено " + Fmt.money(ad["paid"])
        if let till = ad["expires_at"].nonEmptyString {
            return name + " · " + paid + " · до " + Fmt.day(till)
        }
        return name + " · " + paid
    }
}

/// Карточка объявления (строка списка; ручки «объявление по id» нет) с действиями.
struct AdsAdDetailView: View {
    let model: PagedListModel
    @ObservedObject var stats: ObjectLoader
    @Environment(\.dismiss) private var dismiss
    @State private var ad: JSON
    @State private var askBlock = false
    @State private var info: String?
    @State private var deletedInfo: String?
    /// Итог блокировки: показываем после закрытия листа (алерт поверх
    /// закрывающегося листа iOS может не показать).
    @State private var blockInfo: String?

    init(ad: JSON, model: PagedListModel, stats: ObjectLoader) {
        self.model = model
        self.stats = stats
        _ad = State(initialValue: ad)
    }

    private var id: Int { ad.id ?? 0 }
    private var status: String { ad["status"].stringValue }

    var body: some View {
        List {
            headerSection
            AdsAdInfoSection(ad: ad)
            authorSection
            actionsSection
            Section { JSONInspectorView(ad) }
        }
        .navigationTitle("Объявление #" + String(id))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $askBlock, onDismiss: showBlockInfo) { blockSheet }
        .alert(info ?? "", isPresented: infoShown) {
            Button("OK", role: .cancel) {}
        }
        .alert(deletedInfo ?? "", isPresented: deletedShown) {
            Button("OK", role: .cancel) { finishDelete() }
        }
    }

    private var infoShown: Binding<Bool> {
        Binding(get: { info != nil }, set: { if !$0 { info = nil } })
    }

    private var deletedShown: Binding<Bool> {
        Binding(get: { deletedInfo != nil }, set: { if !$0 { deletedInfo = nil } })
    }

    private var headerSection: some View {
        Section {
            if let p = ad["photo"].nonEmptyString {
                AsyncImageView(path: p, height: 200, cornerRadius: 12, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            Text(ad["title"].nonEmptyString ?? "Без заголовка")
                .font(.headline)
            HStack {
                if ad["price"].isNull {
                    Text("Цена не указана").foregroundColor(Brand.muted)
                } else {
                    MoneyText(ad["price"]).font(.title3.weight(.semibold))
                }
                Spacer()
                StatusBadge(AdsFormat.statusLabel(status), color: AdsFormat.statusColor(status))
            }
            if let r = ad["block_reason"].nonEmptyString {
                InfoBanner("Причина блокировки: " + r, systemImage: "hand.raised", color: Brand.red)
            }
        }
    }

    private var authorSection: some View {
        Section("Автор") {
            if let uid = ad["user_id"].int, uid > 0 {
                NavigationLink(destination: UserDetailView(id: uid)) {
                    KVRow("Имя", ad["user_name"].nonEmptyString ?? ("#" + String(uid)))
                }
            } else {
                KVRow("Имя", ad["user_name"].string)
            }
            phoneRow
        }
    }

    @ViewBuilder
    private var phoneRow: some View {
        let phone = ad["user_phone"].stringValue
        if let url = Fmt.phoneURL(phone) {
            Link(destination: url) { KVRow("Телефон", Fmt.phone(phone)) }
        } else {
            KVRow("Телефон", phone.isEmpty ? nil : phone)
        }
    }

    private var actionsSection: some View {
        Section {
            if status == "blocked" {
                ActionButton("Разблокировать", systemImage: "lock.open", style: .prominent,
                             confirm: ConfirmAction(title: "Разблокировать объявление?",
                                                    message: "Срок ещё идёт — вернётся в выдачу; кончился — станет «Истекло».",
                                                    confirmLabel: "Разблокировать"),
                             fullWidth: true) {
                    try await unblock()
                }
            } else {
                Button(role: .destructive) {
                    askBlock = true
                } label: {
                    Label("Заблокировать", systemImage: "hand.raised").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            ActionButton("Удалить вместе с фото", systemImage: "trash", role: .destructive, style: .bordered,
                         confirm: ConfirmAction(title: "Удалить объявление?",
                                                message: "Объявление и все его фотографии удалятся безвозвратно. За неиспользованные оплаченные дни автору вернутся деньги.",
                                                confirmLabel: "Удалить", destructive: true),
                         fullWidth: true) {
                try await remove()
            }
        }
    }

    private var blockSheet: some View {
        let aid = id
        return ModerationReasonSheet(title: "Заблокировать объявление", message: AdsFormat.blockMessage,
                                     reasons: AdsFormat.blockReasons, placeholder: "Причина (увидит автор)",
                                     submitTitle: "Заблокировать", allowEmpty: true) { reason in
            let text = try await AdsFormat.block(id: aid, reason: reason)
            let shown = reason.isEmpty ? "Нарушение правил площадки" : reason
            apply(["status": .string("blocked"), "block_reason": .string(shown)])
            blockInfo = text
            await stats.load()
        }
    }

    private func showBlockInfo() {
        if let t = blockInfo {
            blockInfo = nil
            info = t
        }
    }

    private func unblock() async throws {
        let r = try await API.shared.post("/api/admin/ads/\(id)/unblock")
        let newStatus = r["status"].nonEmptyString ?? "draft"
        apply(["status": .string(newStatus), "block_reason": .string("")])
        info = "Статус: " + AdsFormat.statusLabel(newStatus)
        await stats.load()
    }

    private func remove() async throws {
        let r = try await API.shared.delete("/api/admin/ads/\(id)")
        let files = r["files_removed"].intValue
        let refund = r["refund"].decimal ?? 0
        var text = "Удалено, файлов стёрто: " + String(files)
        if refund > 0 { text += ". Автору возвращено " + Fmt.money(refund) }
        deletedInfo = text
        await stats.load()
    }

    private func finishDelete() {
        let aid = id
        dismiss()
        model.remove(id: aid)
    }

    private func apply(_ fields: [String: JSON]) {
        ad = AdsFormat.patched(ad, fields)
        model.update(id: id) { row in
            row = AdsFormat.patched(row, fields)
        }
    }
}

/// Сведения об объявлении.
struct AdsAdInfoSection: View {
    let ad: JSON

    var body: some View {
        Section("Сведения") {
            KVRow("Категория", ad["category_name"].string)
            KVRow("Фото", ad["photos"].string)
            KVRow("Просмотров", ad["views_count"].string)
            KVRow("Показов телефона", ad["contacts_count"].string)
            KVRow("Новых жалоб", ad["reports"].string)
            KVRow("Оплачено", json: ad["paid"], money: true)
            KVRow("Создано", dateText("created_at"))
            KVRow("Опубликовано", dateText("published_at"))
            KVRow("Оплачено до", dateText("expires_at"))
            KVRow("Удалится после", dateText("delete_after"))
        }
    }

    private func dateText(_ key: String) -> String? {
        guard let s = ad[key].nonEmptyString else { return nil }
        return Fmt.date(s)
    }
}
