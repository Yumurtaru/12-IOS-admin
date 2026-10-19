import SwiftUI
import UIKit

/// Логин и пароль владельца из ответа сервера (волна А76) — для карточки
/// результата после «Добавить организацию» и «Выдать новый пароль».
///
/// Пароль живёт только в памяти открытого листа: не пишется ни в журнал, ни в
/// UserDefaults/Keychain, в JSONInspectorView не попадает. Закрыли лист — пароля
/// больше нигде нет (снова — только «Выдать новый пароль»).
struct ShopCredentials {
    let title: String
    let message: String?
    let shopId: Int?
    let shopName: String?
    let status: String?
    let statusLabel: String?
    let loginPhone: String?
    let loginEmail: String?
    let password: String?
    /// Повтор запроса по ключу: сервер не хранит пароль и отдаёт password = null.
    let passwordHidden: Bool
    let ownerExisted: Bool
    /// owner.has_password (только создание): false — у аккаунта пароля нет вовсе.
    let ownerHasPassword: Bool?
    let loginURL: String?
    let emailSent: Bool
    let sessionsRevoked: Bool
    let blocked: Bool
    let warnings: [String]
    let shareText: String?
    let isReset: Bool

    /// POST /api/admin/shops/create → data (core/Admin.php createShopByAdmin).
    static func fromCreate(_ d: JSON) -> ShopCredentials {
        let owner = d["owner"]
        let existed = owner["existed"].boolValue
        return ShopCredentials(
            title: existed ? "Аккаунт владельца уже был" : "Новый аккаунт владельца",
            message: d["message"].nonEmptyString,
            shopId: d["shop_id"].int,
            shopName: d["shop_name"].nonEmptyString,
            status: d["status"].nonEmptyString,
            statusLabel: d["status_label"].nonEmptyString,
            loginPhone: owner["login_phone"].nonEmptyString,
            loginEmail: owner["login_email"].nonEmptyString,
            password: d["password"].nonEmptyString,
            passwordHidden: d["password_hidden"].boolValue,
            ownerExisted: existed,
            ownerHasPassword: owner["has_password"].bool,
            loginURL: d["login_url"].nonEmptyString,
            emailSent: d["email_sent"].boolValue,
            sessionsRevoked: d["sessions_revoked"].boolValue,
            blocked: false,
            warnings: d["warnings"].array.compactMap { $0.nonEmptyString },
            shareText: d["share_text"].nonEmptyString,
            isReset: false)
    }

    /// POST /api/admin/shops/{id}/owner-password → data (core/Admin.php resetOwnerPassword).
    static func fromReset(_ d: JSON, shopName: String) -> ShopCredentials {
        ShopCredentials(
            title: "Новый пароль выдан",
            message: "Прежний пароль больше не действует, прежние входы владельца завершены.",
            shopId: d["shop_id"].int,
            shopName: shopName,
            status: nil,
            statusLabel: nil,
            loginPhone: d["login_phone"].nonEmptyString,
            loginEmail: d["login_email"].nonEmptyString,
            password: d["password"].nonEmptyString,
            passwordHidden: false,
            ownerExisted: true,
            ownerHasPassword: nil,
            loginURL: d["login_url"].nonEmptyString,
            emailSent: false,
            sessionsRevoked: d["sessions_revoked"].boolValue,
            blocked: d["blocked"].boolValue,
            warnings: d["warnings"].array.compactMap { $0.nonEmptyString },
            shareText: d["share_text"].nonEmptyString,
            isReset: true)
    }

    /// «+7 (900) 123-45-67 или owner@mail.ru» — как логин показывает сайт.
    var loginText: String {
        var parts: [String] = []
        if let p = loginPhone { parts.append(ShopCredentials.phoneLogin(p)) }
        if let e = loginEmail { parts.append(e) }
        return parts.isEmpty ? "—" : parts.joined(separator: " или ")
    }

    /// Телефон-логин: сервер отдаёт цифры без «+» (phonePublic), сайт пишет «+» спереди.
    static func phoneLogin(_ p: String) -> String {
        let f = Fmt.phone(p)
        return f.hasPrefix("+") ? f : "+" + p
    }

    /// Скопировать пароль/текст: только на этом телефоне (без «Универсального
    /// буфера» на Mac/iPad) и не дольше 10 минут — пароль не залёживается в буфере.
    static func copySecret(_ text: String) {
        let expires = Date().addingTimeInterval(600)
        UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                      options: [.localOnly: true, .expirationDate: expires])
    }
}

/// Секции карточки результата (внутри Form): логин, пароль один раз,
/// «Скопировать пароль», «Скопировать текст владельцу», «Поделиться…»,
/// предупреждения сервера и переход в карточку организации.
struct ShopCredentialsSections: View {
    let creds: ShopCredentials
    /// «Открыть карточку организации» (nil — кнопки нет).
    let onOpenShop: ((Int) -> Void)?

    @State private var copied: String?
    @State private var showShare = false

    init(creds: ShopCredentials, onOpenShop: ((Int) -> Void)? = nil) {
        self.creds = creds
        self.onOpenShop = onOpenShop
    }

    var body: some View {
        Group {
            mainSection
            passwordSection
            if !creds.warnings.isEmpty || creds.blocked {
                problemsSection
            }
            actionsSection
            if let text = creds.shareText {
                Section {
                    Text(text)
                        .font(.footnote)
                        .textSelection(.enabled)
                } header: {
                    Text("Текст для владельца")
                }
            }
        }
    }

    private var mainSection: some View {
        Section {
            if let m = creds.message {
                Text(m)
                    .font(.subheadline)
                    .foregroundColor(Brand.text)
            }
            if let name = creds.shopName {
                HStack(alignment: .firstTextBaseline) {
                    Text("Организация").foregroundColor(Brand.muted)
                    Spacer(minLength: 8)
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
            }
            if creds.status != nil || creds.statusLabel != nil {
                HStack {
                    Text("Статус").foregroundColor(Brand.muted)
                    Spacer()
                    StatusBadge(creds.statusLabel ?? ShopsLabels.status(creds.status),
                                color: ShopsLabels.statusColor(creds.status))
                }
                .font(.subheadline)
            }
            KVRow("Логин", creds.loginText, copyable: true)
            if let url = creds.loginURL {
                Text("Вход: " + url + " или приложение «Yumurta Seller»")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if creds.emailSent {
                Text("Письмо со ссылкой на вход отправлено владельцу (без пароля).")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if creds.sessionsRevoked {
                Text("Все прежние входы владельца завершены (сайт, приложения, касса по его логину).")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        } header: {
            Text(creds.title)
        }
    }

    @ViewBuilder
    private var passwordSection: some View {
        Section {
            if let pw = creds.password {
                Text(pw)
                    .font(.title2.monospaced().weight(.semibold))
                    // Без выделения текста: системное «Скопировать» кладёт пароль в общий
                    // буфер без срока — копируем только кнопкой (только это устройство, 10 мин).
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                Text("Пароль показывается один раз — скопируйте его сейчас. Потом — только «Выдать новый пароль».")
                    .font(.caption)
                    .foregroundColor(Brand.red)
            } else {
                KVRow("Пароль", creds.passwordHidden ? "скрыт (повтор запроса)" : "прежний")
                InfoBanner(noPasswordHint, systemImage: "key", color: Brand.amber)
            }
        } header: {
            Text("Пароль")
        }
    }

    /// Почему пароля нет и что делать.
    private var noPasswordHint: String {
        if creds.passwordHidden {
            return "Пароль показывался в первом ответе сервера и повторно не выдаётся. Если он не сохранён — откройте карточку организации и нажмите «Выдать новый пароль»."
        }
        if creds.ownerHasPassword == false {
            return "У аккаунта владельца нет пароля. Выдайте его кнопкой «Выдать новый пароль» в карточке организации (или владелец задаст сам через «Забыли пароль»)."
        }
        return "Владелец входит со своим прежним паролем. Если он его не помнит — откройте карточку организации и нажмите «Выдать новый пароль»."
    }

    private var problemsSection: some View {
        Section {
            if creds.blocked {
                InfoBanner("Аккаунт владельца заблокирован — с новым паролем он не войдёт, пока его не разблокируют в разделе «Пользователи».",
                           systemImage: "hand.raised", color: Brand.red)
            }
            if !creds.warnings.isEmpty {
                InfoBanner("Не всё выполнено: " + creds.warnings.joined(separator: "; "),
                           systemImage: "exclamationmark.triangle", color: Brand.amber)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            if let pw = creds.password {
                Button {
                    ShopCredentials.copySecret(pw)
                    Haptics.success()
                    copied = "Пароль скопирован"
                } label: {
                    Label("Скопировать пароль", systemImage: "doc.on.doc")
                }
            }
            if let text = creds.shareText {
                Button {
                    ShopCredentials.copySecret(text)
                    Haptics.success()
                    copied = "Текст скопирован — отправьте его владельцу"
                } label: {
                    Label("Скопировать текст владельцу", systemImage: "text.badge.checkmark")
                }
                Button {
                    showShare = true
                } label: {
                    Label("Отправить текст владельцу…", systemImage: "square.and.arrow.up")
                }
                // Лист «Поделиться» висит на самой кнопке: модификатор на Group
                // размножился бы на каждую секцию.
                .sheet(isPresented: $showShare) {
                    ShareSheet(items: [text])
                }
            }
            if let open = onOpenShop, let sid = creds.shopId {
                Button {
                    open(sid)
                } label: {
                    Label(creds.password == nil ? "Открыть карточку — «Выдать новый пароль»" : "Открыть карточку организации",
                          systemImage: "building.2")
                }
            }
        } footer: {
            Text((copied.map { $0 + ". " } ?? "") + "Скопированное хранится в буфере обмена 10 минут и только на этом телефоне.")
        }
    }
}
