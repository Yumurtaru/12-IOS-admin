import SwiftUI
import UIKit

/// Фото, открытое на весь экран (для `.fullScreenCover(item:)`).
struct CourierPhoto: Identifiable {
    let id = UUID()
    /// Подпись в шапке («Водительское удостоверение»).
    let title: String
    /// Уже загруженная картинка.
    let image: UIImage
}

/// Кэш документов курьеров в памяти (на диск не пишем — это личные документы).
/// Ключ — путь + «версия» (дата заявки): курьер подал заявку заново — фото новые.
enum CourierImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 40
        // Фото прав с телефона — до 12 Мп; без предела по объёму 40 таких картинок
        // заняли бы сотни мегабайт.
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// Ключ кэша: путь + версия.
    static func key(path: String, version: String) -> String {
        path + "#" + version
    }

    static func get(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// Положить в кэш; cost — примерный объём раскодированной картинки (ш × в × 4 байта).
    static func set(_ image: UIImage, _ key: String) {
        let w = image.size.width * image.scale
        let h = image.size.height * image.scale
        let cost = Int(max(1, w * h * 4))
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Забыть картинку (карточку обновили «потянув» — фото могли замениться).
    static func remove(path: String, version: String) {
        cache.removeObject(forKey: key(path: path, version: version) as NSString)
    }
}

/// Загрузка картинки, которую сервер отдаёт только администратору:
/// GET /api/admin/pool/couriers/{id}/doc/photo|license и /api/admin/pool/problems/{id}/photo
/// (CourierPool::streamImage — image/jpeg, а если фото нет — 404 JSON «Фото нет»).
/// Обычный AsyncImageView не подходит: он ходит без токена. Здесь — API.download
/// (токен, обновление сессии при 401, текст ошибки сервера); временный файл сразу удаляется.
@MainActor
final class CourierImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var failed: String?
    @Published private(set) var isLoading = false

    let path: String
    private let key: String

    init(path: String, version: String) {
        self.path = path
        self.key = CourierImageCache.key(path: path, version: version)
        self.image = CourierImageCache.get(CourierImageCache.key(path: path, version: version))
    }

    /// Загрузить, если ещё нет.
    func load() async {
        guard image == nil, !isLoading else { return }
        isLoading = true
        failed = nil
        do {
            let file = try await API.shared.download(path, suggestedName: "photo.jpg")
            // Временную папку с документом удаляем на любом исходе (и если чтение упало).
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let data = try Data(contentsOf: file)
            if let img = UIImage(data: data) {
                image = img
                CourierImageCache.set(img, key)
            } else {
                failed = "Фото не открылось"
            }
        } catch {
            if !APIError.isCancellation(error) { failed = APIError.describe(error) }
        }
        isLoading = false
    }

    /// Повторить после ошибки.
    func retry() async {
        failed = nil
        await load()
    }
}

/// Миниатюра документа с подписью: тап — на весь экран с увеличением,
/// при ошибке — тап повторяет загрузку.
///
/// ```
/// CourierDocThumb(path: "/api/admin/pool/couriers/5/doc/license", version: submittedAt,
///                 title: "Права", available: c["has_license"].boolValue) { photo in viewed = photo }
/// ```
struct CourierDocThumb: View {
    let title: String
    let available: Bool
    let height: CGFloat
    let onOpen: (CourierPhoto) -> Void

    @StateObject private var loader: CourierImageLoader

    /// - Parameters:
    ///   - path: ручка картинки (нужен токен администратора);
    ///   - version: меняется — фото грузится заново (дата заявки);
    ///   - title: подпись;
    ///   - available: сервер сообщил, что фото есть (has_photo / has_license);
    ///   - height: высота миниатюры;
    ///   - onOpen: открыть на весь экран.
    init(path: String, version: String, title: String, available: Bool, height: CGFloat = 150,
         onOpen: @escaping (CourierPhoto) -> Void) {
        self.title = title
        self.available = available
        self.height = height
        self.onOpen = onOpen
        _loader = StateObject(wrappedValue: CourierImageLoader(path: path, version: version))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(Brand.muted)
            Button {
                tapped()
            } label: {
                thumb
            }
            .buttonStyle(.borderless)
            .disabled(!available)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if available { await loader.load() }
        }
    }

    private func tapped() {
        if let img = loader.image {
            Haptics.tap()
            onOpen(CourierPhoto(title: title, image: img))
        } else if loader.failed != nil {
            Task { await loader.retry() }
        }
    }

    private var thumb: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbContent
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Brand.chip)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if loader.image != nil {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Circle())
                    .padding(6)
            }
        }
    }

    @ViewBuilder
    private var thumbContent: some View {
        if !available {
            placeholder("Фото нет", symbol: "photo")
        } else if let img = loader.image {
            // Обрезку по рамке делает clipShape у миниатюры (thumb).
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else if let f = loader.failed {
            placeholder(f + "\nНажмите, чтобы повторить", symbol: "exclamationmark.triangle")
        } else {
            ProgressView()
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .foregroundColor(Brand.muted)
        .padding(8)
    }
}

/// Документ на весь экран: щипок — увеличить (до 6×), двойной тап — 2,5× / обратно,
/// перетаскивание — двигать увеличенное фото (не дальше краёв; при масштабе 1 — на месте).
struct CourierPhotoViewer: View {
    let photo: CourierPhoto

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    init(photo: CourierPhoto) {
        self.photo = photo
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                GeometryReader { geo in
                    zoomable(in: geo.size)
                }
            }
            .navigationTitle(photo.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private func zoomable(in size: CGSize) -> some View {
        Image(uiImage: photo.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .offset(x: offset.width, y: offset.height)
            .gesture(magnify(in: size))
            .simultaneousGesture(drag(in: size))
            .onTapGesture(count: 2) { toggleZoom() }
    }

    private func magnify(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(6, max(1, lastScale * value))
                if scale <= 1.01 {
                    offset = .zero
                } else {
                    offset = clamped(offset, scale: scale, in: size)
                }
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 {
                    reset()
                } else {
                    lastOffset = offset
                }
            }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { g in
                guard scale > 1.01 else { return }
                let proposed = CGSize(width: lastOffset.width + g.translation.width,
                                      height: lastOffset.height + g.translation.height)
                offset = clamped(proposed, scale: scale, in: size)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    /// Сдвиг не дальше, чем увеличенная картинка выходит за экран: край фото не
    /// уезжает внутрь экрана (оценка по рамке; у фото «по ширине» запас по высоте больше).
    private func clamped(_ o: CGSize, scale s: CGFloat, in size: CGSize) -> CGSize {
        let maxX = max(0, size.width * (s - 1) / 2)
        let maxY = max(0, size.height * (s - 1) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)),
                      height: min(maxY, max(-maxY, o.height)))
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1 {
                reset()
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
