import SwiftUI
import UIKit

/// Пузырь сообщения: поддержка (мы) справа, организация слева.
/// Автор, пометка «Рассылка», вложение, текст, время, «Отправлено» / «Прочитано».
struct ShopSupportBubble: View {
    let message: JSON
    let read: Bool
    let onImage: (String) -> Void

    /// Наше сообщение — сторона admin (сервер для админки ставит mine = side == admin).
    private var mine: Bool { message["mine"].bool ?? (message["side"].string == "admin") }
    private var textColor: Color { mine ? Color.white : Brand.text }
    private var subColor: Color { mine ? Color.white.opacity(0.8) : Brand.muted }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if mine { Spacer(minLength: 48) }
            bubble
            if !mine { Spacer(minLength: 48) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            authorLine
            if message["broadcast"].boolValue {
                Label("Рассылка", systemImage: "megaphone")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(subColor)
            }
            if message["attachment"].isObject {
                ShopSupportAttachmentView(attachment: message["attachment"], mine: mine, onImage: onImage)
            }
            if let text = message["body"].nonEmptyString {
                Text(text)
                    .font(.subheadline)
                    .foregroundColor(textColor)
                    .textSelection(.enabled)
            }
            footer
        }
        .padding(10)
        .background(mine ? Brand.accent : Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// У организации — имя сотрудника («Иван (владелец)»), у нас — кто из админов ответил.
    @ViewBuilder
    private var authorLine: some View {
        let name = mine ? message["sender_name"].nonEmptyString : message["author"].nonEmptyString
        if let n = name {
            Text(n)
                .font(.caption2.weight(.semibold))
                .foregroundColor(subColor)
                .lineLimit(1)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(ShopSupportFmt.time(message["created_at"].string))
            if mine {
                Image(systemName: read ? "checkmark.circle.fill" : "checkmark.circle")
                Text(read ? "Прочитано" : "Отправлено")
            }
        }
        .font(.caption2)
        .foregroundColor(subColor)
    }
}

/// Вложение в пузыре: фото (тап — во весь экран) или PDF строкой (тап — открыть).
struct ShopSupportAttachmentView: View {
    let attachment: JSON
    let mine: Bool
    let onImage: (String) -> Void

    private var url: String { attachment["url"].stringValue }
    private var isPDF: Bool { attachment["type"].string == "pdf" }

    var body: some View {
        if isPDF {
            pdfRow
        } else {
            AsyncImageView(path: url, width: 220, height: 165, cornerRadius: 10)
                .contentShape(Rectangle())
                .onTapGesture { onImage(url) }
        }
    }

    @ViewBuilder
    private var pdfRow: some View {
        let name = attachment["name"].nonEmptyString ?? "Документ.pdf"
        if let link = API.absoluteURL(url) {
            Link(destination: link) { pdfLabel(name) }
        } else {
            pdfLabel(name)
        }
    }

    private func pdfLabel(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.title3)
            Text(name)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundColor(mine ? Color.white : Brand.blue)
        .padding(8)
        .background((mine ? Color.white : Brand.blue).opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Поле ввода: вложение, многострочный текст, счётчик у предела, отправка.
struct ShopSupportComposer: View {
    @ObservedObject var model: ShopSupportChatModel
    let onAttachPhoto: () -> Void
    let onAttachPDF: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let e = model.sendError {
                ErrorBanner(message: e, retry: retryAction, dismiss: { model.sendError = nil })
            }
            if model.hasThread && model.status == "closed" {
                Text("Вопрос отмечен решённым. Новое сообщение снова откроет переписку.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let f = model.attachment {
                ShopSupportAttachmentChip(file: f, onRemove: { model.attachment = nil })
            }
            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                field
                sendButton
            }
            counter
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Brand.bg)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(Brand.border), alignment: .top)
    }

    /// «Повторить» — только если есть что отправить (тем же ключом повтора).
    private var retryAction: (() -> Void)? {
        guard model.canSend else { return nil }
        let m = model
        return { Task { @MainActor in await m.send() } }
    }

    private var attachMenu: some View {
        Menu {
            Button {
                onAttachPhoto()
            } label: { Label("Фото из галереи", systemImage: "photo") }
            Button {
                onAttachPDF()
            } label: { Label("PDF-файл", systemImage: "doc") }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 20))
                .frame(width: 34, height: 34)
        }
        .disabled(model.sending)
    }

    private var field: some View {
        TextField("Сообщение организации…", text: $model.draft, axis: .vertical)
            .lineLimit(1...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var sendButton: some View {
        Button {
            let m = model
            Task { @MainActor in await m.send() }
        } label: {
            Group {
                if model.sending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                }
            }
            .frame(width: 34, height: 34)
        }
        .foregroundColor(model.canSend ? Brand.accent : Brand.muted)
        .disabled(!model.canSend)
    }

    /// Счётчик символов — только у предела (за 300 до него и дальше).
    @ViewBuilder
    private var counter: some View {
        let n = model.draft.count
        if n > model.maxBody - 300 {
            Text(String(n) + " / " + String(model.maxBody))
                .font(.caption2.monospacedDigit())
                .foregroundColor(n > model.maxBody ? Brand.red : Brand.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Выбранное вложение над полем ввода, с крестиком «убрать».
struct ShopSupportAttachmentChip: View {
    let file: ShopSupportOutgoingFile
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            thumb
            Text(file.isImage ? "Фото" : file.fileName)
                .font(.footnote)
                .lineLimit(1)
            Text(ShopSupportAttachmentChip.size(file.data.count))
                .font(.caption2)
                .foregroundColor(Brand.muted)
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(Brand.muted)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var thumb: some View {
        if let img = file.preview {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundColor(Brand.blue)
                .frame(width: 40, height: 40)
        }
    }

    /// «850 КБ» / «2,4 МБ».
    static func size(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
