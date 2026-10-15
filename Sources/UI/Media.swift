import PhotosUI
import SwiftUI
import UIKit

/// Системное меню «Поделиться» (файл CSV/копии базы, текст, ссылка).
///
/// ```
/// @State private var shared: SharedFile?
/// shared = SharedFile(url: try await API.shared.download("/api/admin/…"))
/// .sheet(item: $shared) { f in ShareSheet(items: [f.url]) }
/// ```
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    init(items: [Any]) { self.items = items }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Файл для `.sheet(item:)` с ShareSheet (URL сам по себе не Identifiable).
struct SharedFile: Identifiable {
    let id = UUID()
    /// Локальный файл (например, из API.download).
    let url: URL

    init(url: URL) { self.url = url }
}

/// Выбор одного фото из галереи (PHPicker, разрешение на доступ к галерее не нужно).
///
/// ```
/// @State private var pick = false
/// .sheet(isPresented: $pick) {
///     ImagePicker { image in
///         guard let data = ImageDownscaler.jpeg(image) else { return }
///         Task { let r = try? await API.shared.upload("/api/admin/upload", fileData: data, fileName: "banner.jpg",
///                                                   mime: "image/jpeg", query: ["dir": "banners"]) }
///     }
/// }
/// ```
struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    var onFail: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    /// - Parameters:
    ///   - onPick: выбранное фото (на главном потоке);
    ///   - onFail: фото не открылось (iCloud без сети, битый файл).
    init(onPick: @escaping (UIImage) -> Void, onFail: ((String) -> Void)? = nil) {
        self.onPick = onPick
        self.onFail = onFail
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Делегат PHPicker.
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let pick = parent.onPick
            let fail = parent.onFail
            parent.dismiss()
            guard let provider = results.first?.itemProvider else { return }
            let failText = "Не удалось открыть фото. Если оно в iCloud — дождитесь загрузки на телефон и выберите снова."
            guard provider.canLoadObject(ofClass: UIImage.self) else { fail?(failText); return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async {
                    if let img = image { pick(img) } else { fail?(failText) }
                }
            }
        }
    }
}

/// Уменьшение фото перед загрузкой: длинная сторона ≤ 2048 px, JPEG.
enum ImageDownscaler {
    /// JPEG-данные (nil — не удалось закодировать).
    static func jpeg(_ image: UIImage, maxSide: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let k = min(1, maxSide / longest)
        let target = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // реальные пиксели, а не @3x
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }
}

/// Картинка по адресу сайта с кэшем в памяти и на диске.
///
/// ```
/// AsyncImageView(path: row["photo"].string, size: 44)            // "/uploads/…" или полный URL
/// AsyncImageView(path: banner["image"].string, height: 120, cornerRadius: 12)
/// ```
struct AsyncImageView: View {
    let url: URL?
    let width: CGFloat?
    let height: CGFloat?
    let cornerRadius: CGFloat
    let contentMode: ContentMode

    @State private var image: UIImage?
    @State private var failed: Bool

    /// - Parameters:
    ///   - path: путь сайта ("/uploads/x.webp") или полный URL;
    ///   - size: квадрат со стороной size (иначе width/height);
    ///   - width, height: размеры (nil — по содержимому);
    ///   - cornerRadius: скругление;
    ///   - contentMode: .fill (обрезать) или .fit.
    init(path: String?, size: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil,
         cornerRadius: CGFloat = 8, contentMode: ContentMode = .fill) {
        self.url = API.absoluteURL(path)
        self.width = size ?? width
        self.height = size ?? height
        self.cornerRadius = cornerRadius
        self.contentMode = contentMode
        let cached = self.url.flatMap { ImagePipeline.memoryImage(for: $0) }
        _image = State(initialValue: cached)
        _failed = State(initialValue: false)
    }

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Brand.chip
                Image(systemName: failed || url == nil ? "photo" : "hourglass")
                    .foregroundColor(Brand.muted)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        guard let u = url else { return }
        if image != nil { return }
        do {
            let img = try await ImagePipeline.load(u)
            if !Task.isCancelled { image = img }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// Загрузка и кэш картинок (своя сессия: до 8 соединений, кэш на диске 200 МБ).
enum ImagePipeline {
    private static let memory: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 300
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 20
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("admin-images", isDirectory: true)
        cfg.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024, directory: dir)
        return URLSession(configuration: cfg)
    }()

    /// Уже раскодированная картинка из памяти.
    static func memoryImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Загрузить (или взять из кэша) и уменьшить до 1024 px по длинной стороне.
    static func load(_ url: URL) async throws -> UIImage {
        if let img = memoryImage(for: url) { return img }
        let pair = try await session.data(from: url)
        if let http = pair.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let raw = UIImage(data: pair.0) else { throw URLError(.cannotDecodeContentData) }
        let pxW = raw.size.width * raw.scale
        let pxH = raw.size.height * raw.scale
        let longest = max(pxW, pxH)
        var prepared: UIImage?
        if longest > 1024 {
            let k = 1024 / longest
            let target = CGSize(width: (pxW * k).rounded(), height: (pxH * k).rounded())
            prepared = await raw.byPreparingThumbnail(ofSize: target)
        }
        if prepared == nil { prepared = await raw.byPreparingForDisplay() }
        let img = prepared ?? raw
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        memory.setObject(img, forKey: url as NSURL, cost: cost)
        return img
    }
}
