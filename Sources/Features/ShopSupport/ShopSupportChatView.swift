import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Чат с организацией (раздел «Сообщения продавцам», кнопка «Написать организации»
/// в карточке магазина, push `shop_support`). Работает и без прежней переписки —
/// первое сообщение её создаст.
///
/// Меню: «Отметить решённым» / «Открыть снова», «Карточка организации», звонок
/// в организацию и владельцу. Опрос новых сообщений — только пока чат на экране.
struct ShopSupportChatView: View {
    let shopId: Int

    @StateObject private var model: ShopSupportChatModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var onScreen = false
    @State private var showCard = false
    @State private var pickPhoto = false
    @State private var pickPDF = false
    @State private var viewed: ShopSupportViewedImage?

    init(shopId: Int) {
        self.shopId = shopId
        _model = StateObject(wrappedValue: ShopSupportChatModel(shopId: shopId))
    }

    var body: some View {
        AsyncContent(state: model.state, retry: { await model.load() }) {
            ShopSupportChatThread(model: model,
                                  onImage: { path in viewed = ShopSupportViewedImage(path: path) },
                                  onAttachPhoto: { pickPhoto = true },
                                  onAttachPDF: { pickPDF = true })
        }
        .navigationTitle(model.shopName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await model.loadIfNeeded() }
        .onAppear {
            onScreen = true
            updateVisible(screen: true)
        }
        .onDisappear {
            onScreen = false
            updateVisible(screen: false)
        }
        .onChange(of: scenePhase) { _ in updateVisible(screen: onScreen) }
        .onReceive(NotificationCenter.default.publisher(for: ShopSupportLive.poke)) { _ in
            Task { await model.poll() }
        }
        .navigationDestination(isPresented: $showCard) { ShopDetailView(id: shopId) }
        .sheet(isPresented: $pickPhoto) {
            ImagePicker(onPick: { img in model.attachImage(img) }, onFail: { msg in model.sendError = msg })
        }
        .fileImporter(isPresented: $pickPDF, allowedContentTypes: [UTType.pdf]) { result in
            model.attachPDF(result)
        }
        .fullScreenCover(item: $viewed) { v in
            ShopSupportImageViewer(path: v.path)
        }
        .alert("Не получилось", isPresented: actionErrorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    /// Опрос — только когда чат на экране и приложение активно.
    private func updateVisible(screen: Bool) {
        model.setVisible(screen && scenePhase == .active)
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }

    // MARK: - Меню

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                statusItem
                Button {
                    showCard = true
                } label: { Label("Карточка организации", systemImage: "building.2") }
                callItems
            } label: {
                if model.statusBusy { ProgressView() } else { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    @ViewBuilder
    private var statusItem: some View {
        if model.hasThread {
            if model.status == "closed" {
                Button {
                    runStatus("open")
                } label: { Label("Открыть снова", systemImage: "arrow.uturn.backward.circle") }
            } else {
                Button {
                    runStatus("closed")
                } label: { Label("Отметить решённым", systemImage: "checkmark.circle") }
            }
        }
    }

    @ViewBuilder
    private var callItems: some View {
        let shopPhone = model.shop["phone"].string
        let ownerPhone = model.shop["owner_phone"].string
        if let url = Fmt.phoneURL(shopPhone) {
            Button {
                openURL(url)
            } label: { Label("Позвонить: " + Fmt.phone(shopPhone), systemImage: "phone") }
        }
        if let url = Fmt.phoneURL(ownerPhone), ownerPhone != shopPhone {
            Button {
                openURL(url)
            } label: { Label(ownerCallTitle, systemImage: "person.crop.circle") }
        }
    }

    private var ownerCallTitle: String {
        let name = model.shop["owner_name"].nonEmptyString ?? "владелец"
        return "Владельцу (" + name + "): " + Fmt.phone(model.shop["owner_phone"].string)
    }

    private func runStatus(_ s: String) {
        let m = model
        Task { @MainActor in await m.setStatus(s) }
    }
}

/// Фото для полноэкранного просмотра.
struct ShopSupportViewedImage: Identifiable {
    let id = UUID()
    /// Путь сайта ("/assets/uploads/…") или полный URL.
    let path: String
}

/// Лента сообщений + поле ввода.
struct ShopSupportChatThread: View {
    @ObservedObject var model: ShopSupportChatModel
    let onImage: (String) -> Void
    let onAttachPhoto: () -> Void
    let onAttachPDF: () -> Void

    private static let bottomId = "shop-support-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ShopSupportChatHeader(shop: model.shop, status: model.status, hasThread: model.hasThread)
                    olderControl(proxy)
                    banners
                    if model.messages.isEmpty { emptyHint }
                    ForEach(model.messages, id: \.stableID) { m in
                        ShopSupportBubble(message: m, read: model.isRead(m), onImage: onImage)
                    }
                    Color.clear.frame(height: 1).id(ShopSupportChatThread.bottomId)
                }
                .padding(12)
            }
            .background(Brand.bg)
            .refreshable { await model.poll() }
            .onChange(of: model.lastId) { _ in scrollToBottom(proxy, animated: true) }
            .onAppear { scrollToBottom(proxy, animated: false) }
            .safeAreaInset(edge: .bottom) {
                ShopSupportComposer(model: model, onAttachPhoto: onAttachPhoto, onAttachPDF: onAttachPDF)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        // Через очередь: в момент появления ленты строки ещё не разложены.
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(ShopSupportChatThread.bottomId, anchor: .bottom) }
            } else {
                proxy.scrollTo(ShopSupportChatThread.bottomId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func olderControl(_ proxy: ScrollViewProxy) -> some View {
        if model.loadingOlder {
            ProgressView().padding(.vertical, 6)
        } else if let e = model.olderError {
            ErrorBanner(message: e, retry: { loadOlder(proxy) }, dismiss: { model.olderError = nil })
        } else if model.hasOlder {
            Button("Показать раньше") { loadOlder(proxy) }
                .font(.footnote)
                .padding(.vertical, 4)
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        let m = model
        Task { @MainActor in
            // Остаёмся на том сообщении, что было первым, — лента не прыгает.
            if let anchor = await m.loadOlder() {
                proxy.scrollTo(String(anchor), anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let e = model.pollError {
            ErrorBanner(message: e, retry: { retryPoll() }, dismiss: { model.pollError = nil })
        }
    }

    private func retryPoll() {
        let m = model
        Task { @MainActor in await m.poll() }
    }

    private var emptyHint: some View {
        EmptyStateView(title: "Переписки пока нет", systemImage: "bubble.left.and.bubble.right",
                       message: "Напишите организации — сообщение появится у неё в панели продавца (раздел «Техподдержка») и придёт push владельцу. Можно приложить фото или PDF.")
            .frame(minHeight: 260)
    }
}

/// Шапка чата: статус организации, город, номер; отметка «решён».
struct ShopSupportChatHeader: View {
    let shop: JSON
    let status: String
    let hasThread: Bool

    var body: some View {
        HStack(spacing: 8) {
            if shop.isObject {
                StatusBadge(ShopsLabels.status(shop["status"].string),
                            color: ShopsLabels.statusColor(shop["status"].string))
            }
            Text(line)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hasThread && status == "closed" {
                StatusBadge("Решён", color: Brand.green)
            }
        }
        .padding(.bottom, 2)
    }

    private var line: String {
        var parts: [String] = []
        if let id = shop["id"].int { parts.append("#" + String(id)) }
        if let c = shop["city"].nonEmptyString { parts.append(c) }
        if let o = shop["owner_name"].nonEmptyString { parts.append(o) }
        return parts.joined(separator: " · ")
    }
}

/// Полноэкранный просмотр фото из переписки (+ открыть в Safari).
struct ShopSupportImageViewer: View {
    let path: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImageView(path: path, cornerRadius: 0, contentMode: .fit)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = API.absoluteURL(path) {
                        Link(destination: url) { Image(systemName: "safari") }
                    }
                }
            }
        }
    }
}
