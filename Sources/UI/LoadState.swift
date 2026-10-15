import SwiftUI

/// Состояние загрузки экрана.
enum LoadState: Equatable {
    /// Ещё не загружали.
    case idle
    /// Идёт первая загрузка (показывается спиннер).
    case loading
    /// Данные есть.
    case loaded
    /// Загрузилось, но пусто (текст — что показать; nil — текст экрана по умолчанию).
    case empty(String?)
    /// Ошибка (русский текст).
    case failed(String)

    /// true для .loading.
    var isLoading: Bool { self == .loading }
}

/// Обёртка «спиннер / ошибка с «Повторить» / пусто / содержимое».
///
/// ```
/// AsyncContent(state: loader.state, emptyText: "Заявок нет", retry: { await loader.load() }) {
///     List { ... }
/// }
/// ```
struct AsyncContent<Content: View>: View {
    let state: LoadState
    var emptyText: String = "Пусто"
    var emptySymbol: String = "tray"
    let retry: () async -> Void
    let content: () -> Content

    /// - Parameters:
    ///   - state: состояние загрузки;
    ///   - emptyText: текст для пустого результата;
    ///   - emptySymbol: значок пустого результата;
    ///   - retry: что делать по «Повторить»;
    ///   - content: содержимое при `.loaded` (и при `.idle`, чтобы не мигать).
    init(state: LoadState, emptyText: String = "Пусто", emptySymbol: String = "tray",
         retry: @escaping () async -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.state = state
        self.emptyText = emptyText
        self.emptySymbol = emptySymbol
        self.retry = retry
        self.content = content
    }

    var body: some View {
        switch state {
        case .loading:
            ProgressView("Загрузка…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            ErrorStateView(message: msg, retry: retry)
        case .empty(let text):
            EmptyStateView(title: text ?? emptyText, systemImage: emptySymbol)
        case .idle, .loaded:
            content()
        }
    }
}

/// Полноэкранная ошибка с кнопкой «Повторить».
struct ErrorStateView: View {
    let message: String
    let retry: () async -> Void
    @State private var busy = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundColor(Brand.muted)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundColor(Brand.text)
                .padding(.horizontal, 24)
            Button {
                Task {
                    busy = true
                    await retry()
                    busy = false
                }
            } label: {
                if busy { ProgressView() } else { Text("Повторить") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Загрузчик одного объекта (экран деталей): GET path → data.
///
/// ```
/// @StateObject private var loader: ObjectLoader
/// init(id: Int) {   // путь с id — только в init: в инициализаторе свойства `id` недоступен
///     _loader = StateObject(wrappedValue: ObjectLoader(path: "/api/admin/shops/" + String(id)))
/// }
/// var body: some View {
///     AsyncContent(state: loader.state, retry: { await loader.load() }) {
///         List { KVRow("Название", loader.data["name"].string) ... }
///     }
///     .task { await loader.loadIfNeeded() }
///     .refreshable { await loader.load() }
/// }
/// ```
@MainActor
final class ObjectLoader: ObservableObject {
    /// Состояние.
    @Published private(set) var state: LoadState = .idle
    /// Поле data последнего успешного ответа.
    @Published var data: JSON = .null
    /// Поле meta последнего ответа.
    @Published private(set) var meta: JSON = .null

    /// Путь запроса (можно поменять и перезагрузить).
    var path: String
    /// Параметры запроса.
    var query: [String: String?]
    private var generation = 0

    /// - Parameters:
    ///   - path: путь GET, например "/api/admin/users/5";
    ///   - query: параметры.
    init(path: String, query: [String: String?] = [:]) {
        self.path = path
        self.query = query
    }

    /// Загрузить, если ещё не загружено.
    func loadIfNeeded() async {
        if state == .idle { await load() }
    }

    /// Загрузить заново. Пока данные есть, спиннер не показывается (обновление «тихое»).
    func load() async {
        generation += 1
        let gen = generation
        if data.isNull { state = .loading }
        do {
            let res = try await API.shared.getResult(path, query: query)
            guard gen == generation else { return }
            data = res.data
            meta = res.meta
            lastRefreshError = nil
            state = .loaded
        } catch {
            guard gen == generation, !APIError.isCancellation(error) else { return }
            if data.isNull {
                state = .failed(APIError.describe(error))
            } else {
                state = .loaded
                lastRefreshError = APIError.describe(error)
            }
        }
    }

    /// Ошибка «тихого» обновления (данные на экране старые). Показывайте ErrorBanner.
    @Published var lastRefreshError: String?
}
