import SwiftUI
import WebKit

/// Редактор CMS-страницы: заголовок + содержимое (HTML) в многострочном поле,
/// предпросмотр, служебные поля, «Все поля».
///
/// `pageId == nil` — новая страница (POST), иначе загрузка GET /{id} и PUT.
struct PagesEditorView: View {
    let pageId: Int?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState
    @State private var page: JSON = .null
    @State private var title = ""
    @State private var content = ""
    @State private var savedTitle = ""
    @State private var savedContent = ""
    @State private var busy = false
    @State private var error: String?
    @State private var savedNotice = false
    @State private var showPreview = false

    init(pageId: Int?, onSaved: @escaping () -> Void) {
        self.pageId = pageId
        self.onSaved = onSaved
        _state = State(initialValue: pageId == nil ? .loaded : .idle)
    }

    private var isNew: Bool { pageId == nil }
    private var dirty: Bool { title != savedTitle || content != savedContent }
    private var canSave: Bool {
        !busy && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (isNew || dirty)
    }

    var body: some View {
        AsyncContent(state: state, emptyText: "Страница не найдена", emptySymbol: "doc.text",
                     retry: { await load() }) {
            form
        }
        .navigationTitle(isNew ? "Новая страница" : "Страница")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else {
                    Button(isNew ? "Создать" : "Сохранить") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            PagesPreviewSheet(title: title, html: content)
        }
        .alert("Сохранено", isPresented: $savedNotice) {
            Button("OK", role: .cancel) {}
        }
        .task { await loadIfNeeded() }
    }

    private var form: some View {
        Form {
            Section {
                FormTextField("Заголовок", text: $title, prompt: "О компании")
            } footer: {
                if isNew {
                    Text("Адрес страницы сервер составит из заголовка.")
                }
            }
            Section {
                TextEditor(text: $content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 320)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Содержимое (HTML)")
            } footer: {
                Text(Fmt.plural(content.count, "символ", "символа", "символов"))
            }
            Section {
                Button {
                    showPreview = true
                } label: {
                    Label("Предпросмотр", systemImage: "eye")
                }
                .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let e = error {
                Section { ErrorBanner(message: e) }
            }
            if !isNew {
                infoSection
                Section { JSONInspectorView(page) }
            }
        }
    }

    private var infoSection: some View {
        Section("Служебное") {
            KVRow("Адрес", "/page/" + page["slug"].stringValue, copyable: true)
            KVRow("Meta title", page["meta_title"].string)
            KVRow("Meta description", page["meta_description"].string)
            KVRow("ID", page["id"].string, copyable: true)
        }
    }

    // MARK: - Загрузка и сохранение

    private func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    private func load() async {
        guard let id = pageId else { return }
        if page.isNull { state = .loading }
        do {
            let data = try await API.shared.get("/api/admin/pages/" + String(id))
            // Нет такой страницы — сервер отдаёт пустое data (null/false).
            guard data.isObject else {
                state = .empty("Страница не найдена — возможно, её удалили.")
                return
            }
            page = data
            title = data["title"].stringValue
            content = data["content"].stringValue
            savedTitle = title
            savedContent = content
            state = .loaded
        } catch {
            if APIError.isCancellation(error) { return }
            if page.isNull {
                state = .failed(APIError.describe(error))
            } else {
                self.error = APIError.describe(error)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = content
        let id = pageId
        let done = onSaved
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let payload: [String: Any?] = ["title": t, "content": c]
                if let id = id {
                    try await API.shared.put("/api/admin/pages/" + String(id), body: payload)
                    title = t
                    savedTitle = t
                    savedContent = c
                    Haptics.success()
                    busy = false
                    done()
                    savedNotice = true
                } else {
                    try await API.shared.post("/api/admin/pages", body: payload)
                    Haptics.success()
                    busy = false
                    done()
                    dismiss()
                }
            } catch {
                busy = false
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
        }
    }
}

/// Лист предпросмотра HTML (JavaScript выключен).
struct PagesPreviewSheet: View {
    let title: String
    let html: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, html: String) {
        self.title = title
        self.html = html
    }

    var body: some View {
        NavigationStack {
            PagesHTMLView(html: PagesPreviewSheet.document(title: title, body: html))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Предпросмотр")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                    }
                }
        }
    }

    /// Обёртка: viewport для телефона и простой читаемый стиль.
    static func document(title: String, body: String) -> String {
        let esc = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let style = "body{font:-apple-system-body;font-family:-apple-system,sans-serif;padding:16px;line-height:1.5;color:#111}"
            + "img{max-width:100%;height:auto}table{max-width:100%;border-collapse:collapse}"
            + "@media (prefers-color-scheme: dark){body{background:#000;color:#eee}a{color:#6cf}}"
        let head = "<!doctype html><html><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + "<style>" + style + "</style></head><body>"
        return head + "<h1>" + esc + "</h1>" + body + "</body></html>"
    }
}

/// WKWebView для предпросмотра (JavaScript выключен). Картинки с относительными путями берутся с сайта.
struct PagesHTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded == html { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: API.baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Помнит последний загруженный HTML, чтобы не перезагружать то же самое.
    final class Coordinator {
        var loaded: String?
    }
}
