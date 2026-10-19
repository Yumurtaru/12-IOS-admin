import SwiftUI

/// Раздел «Страницы» (CMS-страницы): список, создание и правка заголовка и
/// HTML-содержимого с предпросмотром.
///
/// Сервер: GET /api/admin/pages (id, slug, title), GET /api/admin/pages/{id},
/// POST /api/admin/pages {title, content} (адрес-slug сервер строит из заголовка),
/// PUT /api/admin/pages/{id} {title, content}. Удаления на сервере нет.
/// Публичная страница /page/{slug} есть с волны А72 (П-29.5: по прямой ссылке, noindex) —
/// в редакторе кнопка «Открыть на сайте»; предпросмотр HTML в приложении остаётся.
/// `openId` — id страницы: сразу открывается её редактор.
struct PagesRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/pages", searchParam: nil)
    @State private var pushTarget: PagesPushTarget?
    @State private var deepLinkDone = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Страницы", model: model, searchPrompt: nil, emptyText: "Страниц нет",
                        row: { page in PagesRow(page: page) },
                        destination: { page in editor(page.id) })
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pushTarget = PagesPushTarget(pageId: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Новая страница")
                }
            }
            .navigationDestination(isPresented: pushShown) {
                if let t = pushTarget {
                    editor(t.pageId)
                }
            }
            .onAppear(perform: openDeepLinkIfNeeded)
    }

    private var pushShown: Binding<Bool> {
        Binding(get: { pushTarget != nil }, set: { if !$0 { pushTarget = nil } })
    }

    private func editor(_ id: Int?) -> some View {
        PagesEditorView(pageId: id) {
            Task { await model.refresh() }
        }
    }

    private func openDeepLinkIfNeeded() {
        guard let id = openId, !deepLinkDone else { return }
        deepLinkDone = true
        pushTarget = PagesPushTarget(pageId: id)
    }
}

/// Куда перейти: id страницы или nil — новая.
struct PagesPushTarget: Identifiable {
    let id = UUID()
    let pageId: Int?
}

/// Строка страницы: заголовок и адрес.
private struct PagesRow: View {
    let page: JSON

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(page["title"].nonEmptyString ?? "Без заголовка")
                .font(.body.weight(.medium))
                .foregroundColor(Brand.text)
            Text("/page/" + page["slug"].stringValue)
                .font(.caption.monospaced())
                .foregroundColor(Brand.muted)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
