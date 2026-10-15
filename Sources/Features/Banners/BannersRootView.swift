import SwiftUI

/// Раздел «Баннеры»: список с картинками, просмотр, добавление (фото из галереи
/// → POST /api/admin/upload?dir=banners, или путь вручную) и удаление.
///
/// Сервер: GET/POST /api/admin/banners, DELETE /api/admin/banners/{id}.
/// Правки баннера на сервере нет (как и на сайте): чтобы изменить — создайте
/// новый и удалите старый.
/// `openId` — id баннера: после загрузки списка открывается его карточка.
struct BannersRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/banners", searchParam: nil)
    @State private var creating = false
    @State private var pendingDelete: ConfirmAction?
    @State private var deleteTarget: JSON = .null
    @State private var deepLinkDone = false
    @State private var deepLinkBanner: JSON?

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Баннеры", model: model, searchPrompt: nil, emptyText: "Баннеров нет",
                        row: { banner in bannerRow(banner) },
                        destination: { banner in detail(banner) })
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        creating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Добавить баннер")
                }
            }
            .sheet(isPresented: $creating) {
                BannersCreateSheet {
                    Task { await model.refresh() }
                }
            }
            .confirmAction($pendingDelete) {
                try await performDelete()
            }
            .onChange(of: model.state) { _ in
                openDeepLinkIfReady()
            }
            .navigationDestination(isPresented: deepLinkShown) {
                if let b = deepLinkBanner {
                    detail(b)
                }
            }
    }

    private var deepLinkShown: Binding<Bool> {
        Binding(get: { deepLinkBanner != nil }, set: { if !$0 { deepLinkBanner = nil } })
    }

    private func detail(_ banner: JSON) -> some View {
        BannersDetailView(banner: banner) { id in
            model.remove(id: id)
        }
    }

    private func bannerRow(_ banner: JSON) -> some View {
        BannersRow(banner: banner)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    askDelete(banner)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
    }

    private func askDelete(_ banner: JSON) {
        deleteTarget = banner
        pendingDelete = ConfirmAction(
            title: BannersText.deleteTitle(banner),
            message: "Баннер сразу пропадёт с сайта и из приложений. Отменить будет нельзя.",
            confirmLabel: "Удалить",
            destructive: true)
    }

    private func performDelete() async throws {
        guard let id = deleteTarget.id else { return }
        try await API.shared.delete("/api/admin/banners/" + String(id))
        model.remove(id: id)
    }

    private func openDeepLinkIfReady() {
        guard let id = openId, !deepLinkDone, model.state == .loaded else { return }
        deepLinkDone = true
        deepLinkBanner = model.items.first(where: { $0.id == id })
    }
}

/// Подписи и адреса баннеров.
enum BannersText {
    /// Варианты позиции (как на сайте).
    static let positions: [PickerOption] = [
        PickerOption(value: "home", label: "Главная"),
        PickerOption(value: "catalog", label: "Каталог"),
        PickerOption(value: "city", label: "Город"),
    ]

    static func positionLabel(_ code: String?) -> String {
        let c = code ?? ""
        if let p = positions.first(where: { $0.value == c }) { return p.label }
        return c.isEmpty ? "—" : c
    }

    /// Путь картинки для показа: "banners/…webp" лежит в /assets/uploads/.
    static func imagePath(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("/") { return s }
        return "/assets/uploads/" + s
    }

    static func deleteTitle(_ banner: JSON) -> String {
        if let t = banner["title"].nonEmptyString { return "Удалить баннер «" + t + "»?" }
        return "Удалить баннер?"
    }

    /// Ссылка, которую примет сервер: начинается с / или http(s)://, без пробелов и кавычек.
    static func isValidLink(_ s: String) -> Bool {
        let lower = s.lowercased()
        let prefixOK = s.hasPrefix("/") || lower.hasPrefix("http://") || lower.hasPrefix("https://")
        let bad = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>"))
        return prefixOK && s.rangeOfCharacter(from: bad) == nil && s.count <= 255
    }

    /// Путь картинки, который примет сервер: латиница/цифры/._-/ и расширение webp/jpg/jpeg/png.
    static func isValidImagePath(_ s: String) -> Bool {
        if s.contains("..") { return false }
        return s.range(of: "^[A-Za-z0-9_./-]+\\.(webp|jpe?g|png)$", options: .regularExpression) != nil
    }
}

/// Строка баннера: картинка, заголовок, позиция, город, ссылка.
private struct BannersRow: View {
    let banner: JSON

    private var title: String {
        banner["title"].nonEmptyString ?? "Без заголовка"
    }

    private var subtitle: String {
        let pos = BannersText.positionLabel(banner["position"].string)
        let city = banner["city"].nonEmptyString ?? "все города"
        return pos + " · " + city
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImageView(path: BannersText.imagePath(banner["image_webp"].string),
                           width: 96, height: 54, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if !banner["is_active"].boolValue {
                        StatusBadge("Скрыт", color: Brand.muted)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                if let link = banner["link"].nonEmptyString {
                    Text(link)
                        .font(.caption)
                        .foregroundColor(Brand.blue)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Карточка баннера: картинка крупно, поля, удаление, «Все поля».
struct BannersDetailView: View {
    let banner: JSON
    let onDeleted: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    init(banner: JSON, onDeleted: @escaping (Int) -> Void) {
        self.banner = banner
        self.onDeleted = onDeleted
    }

    private var linkURL: URL? {
        guard let l = banner["link"].nonEmptyString else { return nil }
        return API.absoluteURL(l)
    }

    var body: some View {
        List {
            Section {
                AsyncImageView(path: BannersText.imagePath(banner["image_webp"].string),
                               height: 180, cornerRadius: 12, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Section("Баннер") {
                KVRow("Заголовок", banner["title"].string)
                KVRow("Позиция", BannersText.positionLabel(banner["position"].string))
                KVRow("Город", banner["city"].nonEmptyString ?? "Все города")
                KVRow("Порядок", banner["sort_order"].string)
                KVRow("Показывается", Fmt.yesNo(banner["is_active"].bool))
                KVRow("Файл", banner["image_webp"].string, copyable: true)
            }
            linkSection
            Section {
                ActionButton("Удалить баннер", systemImage: "trash", role: .destructive, style: .plain,
                             confirm: deleteConfirm, fullWidth: true) {
                    guard let id = banner.id else { return }
                    try await API.shared.delete("/api/admin/banners/" + String(id))
                    onDeleted(id)
                    dismiss()
                }
            } footer: {
                Text("Изменить баннер нельзя — создайте новый и удалите этот.")
            }
            Section { JSONInspectorView(banner) }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(banner["title"].nonEmptyString ?? "Баннер")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var linkSection: some View {
        if let l = banner["link"].nonEmptyString {
            Section("Ссылка") {
                KVRow("Адрес", l, copyable: true)
                if let u = linkURL {
                    Link(destination: u) {
                        Label("Открыть в Safari", systemImage: "safari")
                    }
                }
            }
        }
    }

    private var deleteConfirm: ConfirmAction {
        ConfirmAction(title: BannersText.deleteTitle(banner),
                      message: "Баннер сразу пропадёт с сайта и из приложений. Отменить будет нельзя.",
                      confirmLabel: "Удалить",
                      destructive: true)
    }
}
