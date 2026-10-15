import SwiftUI
import UIKit

/// Лист «Новый баннер»: заголовок, ссылка, позиция, город, порядок, картинка.
///
/// Картинка: фото из галереи уменьшается до 2048 px (JPEG) и уходит в
/// POST /api/admin/upload?dir=banners (поле файла `file`), сервер отвечает
/// `{path}` — его и кладём в image_webp. Можно вписать путь вручную, как на сайте.
/// Создание: POST /api/admin/banners {title, link, position, image_webp, city_id, sort_order}.
struct BannersCreateSheet: View {
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var link = ""
    @State private var position = "home"
    @State private var cityId: Int?
    @State private var cityName: String?
    @State private var sortOrder = ""
    @State private var imagePath = ""
    @State private var pickPhoto = false
    @State private var pickCity = false
    @State private var uploading = false
    @State private var busy = false
    @State private var error: String?

    init(onCreated: @escaping () -> Void) {
        self.onCreated = onCreated
    }

    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPath: String { imagePath.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                imageSection
                Section {
                    FormTextField("Заголовок", text: $title, prompt: "Скидки недели")
                    FormTextField("Ссылка", text: $link, prompt: "/shop/... или https://…",
                                  keyboard: .URL, autocapitalize: false)
                    if !trimmedLink.isEmpty && !BannersText.isValidLink(trimmedLink) {
                        Text("Ссылка должна начинаться с / или https:// и быть без пробелов и кавычек — иначе сервер её не сохранит.")
                            .font(.caption)
                            .foregroundColor(Brand.red)
                    }
                }
                Section {
                    FormPicker("Позиция", selection: $position, options: BannersText.positions)
                    cityRow
                    FormIntField("Порядок показа", text: $sortOrder, prompt: "0")
                } footer: {
                    Text("Меньший порядок — раньше в ленте баннеров.")
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
            }
            .navigationTitle("Новый баннер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Создать") { create() }
                            .disabled(uploading)
                    }
                }
            }
            .sheet(isPresented: $pickPhoto) {
                ImagePicker(onPick: { image in
                    upload(image)
                }, onFail: { message in
                    error = message
                })
            }
            .sheet(isPresented: $pickCity) {
                CitiesPickerSheet(allowAll: true) { id, name in
                    cityId = id
                    cityName = name
                }
            }
        }
        .interactiveDismissDisabled(busy || uploading)
    }

    // MARK: - Картинка

    private var imageSection: some View {
        Section {
            if let p = BannersText.imagePath(trimmedPath), BannersText.isValidImagePath(trimmedPath) {
                AsyncImageView(path: p, height: 160, cornerRadius: 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
            Button {
                error = nil
                pickPhoto = true
            } label: {
                HStack {
                    if uploading {
                        ProgressView()
                        Text("Загрузка фото…")
                    } else {
                        Label(trimmedPath.isEmpty ? "Выбрать фото" : "Заменить фото", systemImage: "photo")
                    }
                }
            }
            .disabled(uploading || busy)
            FormTextField("Или путь вручную", text: $imagePath, prompt: "banners/...webp", autocapitalize: false)
            if !trimmedPath.isEmpty && !BannersText.isValidImagePath(trimmedPath) {
                Text("Путь вида banners/2026/10/x.webp (webp, jpg или png) — иначе сервер его не сохранит.")
                    .font(.caption)
                    .foregroundColor(Brand.red)
            }
        } header: {
            Text("Изображение")
        } footer: {
            Text("JPG/PNG/WebP. Лучше широкое изображение (≈1200 px).")
        }
    }

    private var cityRow: some View {
        Button {
            pickCity = true
        } label: {
            HStack {
                Text("Город")
                    .foregroundColor(Brand.text)
                Spacer()
                Text(cityName ?? "Все города")
                    .foregroundColor(Brand.muted)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
    }

    private func upload(_ image: UIImage) {
        guard let data = ImageDownscaler.jpeg(image) else {
            error = "Не удалось подготовить фото. Выберите другое."
            return
        }
        uploading = true
        error = nil
        Task { @MainActor in
            do {
                let r = try await API.shared.upload("/api/admin/upload", fileData: data, fileName: "banner.jpg",
                                                    mime: "image/jpeg", query: ["dir": "banners"])
                if let p = r["path"].nonEmptyString {
                    imagePath = p
                    Haptics.success()
                } else {
                    error = "Сервер не вернул путь к файлу. Попробуйте ещё раз."
                }
            } catch {
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    self.error = APIError.describe(error)
                }
            }
            uploading = false
        }
    }

    // MARK: - Создание

    private func create() {
        guard !busy, !uploading else { return }
        let l = trimmedLink
        let p = trimmedPath
        if !l.isEmpty && !BannersText.isValidLink(l) {
            error = "Проверьте ссылку: она должна начинаться с / или https:// и быть без пробелов."
            return
        }
        if p.isEmpty {
            error = "Добавьте изображение: выберите фото или впишите путь."
            return
        }
        if !BannersText.isValidImagePath(p) {
            error = "Проверьте путь к изображению."
            return
        }
        let sortText = sortOrder.trimmingCharacters(in: .whitespaces)
        var sort = 0
        if !sortText.isEmpty {
            guard let v = Int(sortText) else {
                error = "Порядок — целое число."
                return
            }
            sort = v
        }
        let cityAny: Any? = cityId
        let payload: [String: Any?] = [
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
            "link": l,
            "position": position,
            "image_webp": p,
            "city_id": cityAny,
            "sort_order": sort,
        ]
        busy = true
        error = nil
        Task { @MainActor in
            do {
                try await API.shared.post("/api/admin/banners", body: payload)
                Haptics.success()
                busy = false
                onCreated()
                dismiss()
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
