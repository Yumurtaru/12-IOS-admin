import SwiftUI

/// Вид поля настройки.
enum SettingsFieldKind {
    /// Обычный текст.
    case text
    /// Ссылка/адрес (без автозамены, клавиатура URL).
    case url
    /// Сумма или процент (дробное, запятая допустима — сервер сам заменит на точку).
    case decimal
    /// Целое ≥ 0.
    case integer
    /// Число со знаком (порог баланса, id чата Telegram).
    case signed
    /// Выбор из вариантов (значение → подпись).
    case choice([PickerOption])
}

/// Одно поле экрана «Настройки» (подпись и подсказка — как на сайте).
struct SettingsField: Identifiable {
    let key: String
    let label: String
    let hint: String?
    let kind: SettingsFieldKind

    var id: String { key }

    init(_ key: String, _ label: String, hint: String? = nil, kind: SettingsFieldKind = .text) {
        self.key = key
        self.label = label
        self.hint = hint
        self.kind = kind
    }
}

/// Группа полей (заголовок H3 на сайте) с пояснением под ней.
struct SettingsGroup: Identifiable {
    let title: String
    let note: String?
    let fields: [SettingsField]

    var id: String { title }

    init(_ title: String, note: String? = nil, fields: [SettingsField]) {
        self.title = title
        self.note = note
        self.fields = fields
    }
}

/// Состав экрана — ровно поля и группы admin.js settings() в том же порядке.
/// Ключи, которые сервер отдаёт, а сайт не показывает, экран выводит отдельно
/// «только для просмотра» (SettingsCatalog.knownKeys помогает их отличить).
enum SettingsCatalog {
    private static func opts(_ pairs: [(String, String)]) -> [PickerOption] {
        pairs.map { PickerOption(value: $0.0, label: $0.1) }
    }

    private static let onOffFemale = opts([("0", "Выключена"), ("1", "Включена")])
    private static let yesNo = opts([("1", "Да"), ("0", "Нет")])

    static let groups: [SettingsGroup] = [
        SettingsGroup("Реквизиты площадки", fields: [
            SettingsField("site_name", "Название сайта"),
            SettingsField("site_phone", "Телефон"),
            SettingsField("site_email", "Email", kind: .url),
            SettingsField("support_email", "Email поддержки", kind: .url),
            SettingsField("support_phone", "Телефон поддержки"),
            SettingsField("mp_inn", "ИНН маркетплейса", kind: .integer),
            SettingsField("mp_account", "Расчётный счёт", kind: .integer),
            SettingsField("mp_bik", "БИК", kind: .integer),
        ]),
        SettingsGroup("Условия для новых магазинов",
                      note: "Сбор по умолчанию платит магазин из кошелька — в чек клиента он не добавляется. Чтобы сбор платил клиент, задайте его в карточке магазина.",
                      fields: [
            SettingsField("default_commission_type", "Комиссия по умолчанию",
                          kind: .choice(opts([("percent", "Процент %"), ("fixed", "Фикс ₽")]))),
            SettingsField("default_commission_value", "Значение комиссии", kind: .decimal),
            SettingsField("default_service_fee_percent", "Сервисный сбор по умолчанию, %", kind: .decimal),
            SettingsField("default_service_fee_fixed", "Или фикс. сбор по умолчанию, ₽",
                          hint: "если магазину не задан свой сбор — спишется этот", kind: .decimal),
        ]),
        SettingsGroup("Сбор за продажу через кассу/киоск (дефолт)", fields: [
            SettingsField("default_pos_service_fee_enabled", "Отдельный сбор за кассу/киоск по умолчанию",
                          kind: .choice(opts([("0", "Выключен"), ("1", "Включён")]))),
            SettingsField("default_pos_service_fee_type", "Тип сбора",
                          kind: .choice(opts([("fixed", "Фикс ₽"), ("percent", "Процент %")]))),
            SettingsField("default_pos_service_fee_fixed", "Фикс. сбор за кассу/киоск, ₽",
                          hint: "применяется к магазинам без своей настройки; в карточке магазина можно переопределить",
                          kind: .decimal),
            SettingsField("default_pos_service_fee_percent", "Или процент за кассу/киоск, %", kind: .decimal),
        ]),
        SettingsGroup("Лимиты", fields: [
            SettingsField("wallet_min_topup", "Мин. пополнение кошелька, ₽", kind: .decimal),
            SettingsField("low_balance_threshold", "Порог «низкий баланс», ₽", kind: .decimal),
            SettingsField("referral_min_order", "Реферальный бонус: первый заказ от, ₽",
                          hint: "считается по товарам без доставки и чаевых; бонус обоим начисляется, только если первый выполненный заказ приглашённого не меньше этой суммы; при возврате заказа бонус списывается",
                          kind: .decimal),
            SettingsField("referral_reward_points", "Реферальный бонус: сколько баллов каждому, ₽",
                          hint: "начисляется и приглашённому, и пригласившему; 0 — реферальная программа выключена",
                          kind: .integer),
            SettingsField("seller_bonus_daily_cap", "Магазин может начислить баллов за сутки, ₽",
                          hint: "потолок на ручные начисления баллов из кабинета продавца; 0 — без потолка",
                          kind: .decimal),
            SettingsField("plus_cashback_on_zero", "Надбавка Plus в магазинах с кешбэком 0 %",
                          hint: "«Да» — подписчик Plus получает надбавку в любом заведении, и её платит это заведение; «Нет» — «кешбэк 0 %» означает отказ и для Plus",
                          kind: .choice(yesNo)),
            SettingsField("sms_daily_cap", "Кодов входа (SMS/звонок) в сутки, не больше",
                          hint: "защита от накрутки платных SMS; 0 — без ограничения", kind: .integer),
            SettingsField("modifiers_required_enforce", "Заказ без обязательной добавки",
                          hint: "Включайте, когда у покупателей разойдутся новые версии приложений: старые Android и iOS проверяли только группы «выбрать одно», и такой заказ из них упрётся в отказ.",
                          kind: .choice(opts([("0", "Принимать (как раньше)"), ("1", "Отклонять")]))),
        ]),
        SettingsGroup("Тарифы продавцов", fields: [
            SettingsField("seller_plans_enabled", "Тарифы (подписки) для продавцов",
                          hint: "Выключено — раздел «Тариф» пропадает из панели продавца и из приложений продавца, подключить план нельзя. Уже оплаченные подписки продолжают действовать до конца оплаченного срока. Сами планы настраиваются в разделе «Тарифы» и появятся у продавцов сразу после включения.",
                          kind: .choice(opts([("1", "Включены"), ("0", "Выключены")]))),
        ]),
        SettingsGroup("Онлайн-оплата (ЮKassa)",
                      note: "В ЮKassa укажите URL уведомлений: https://yumurta.ru/api/payments/yookassa",
                      fields: [
            SettingsField("yukassa_enabled", "Онлайн-оплата на сайте", kind: .choice(onOffFemale)),
            SettingsField("yukassa_shop_id", "shopId (идентификатор магазина)"),
            SettingsField("yukassa_secret_key", "Секретный ключ", hint: "из личного кабинета ЮKassa"),
        ]),
        SettingsGroup("Касса (автообновление)",
                      note: "Страница для клиентов и продавцов: yumurta.ru/kassa — она сама показывает актуальный установщик, ссылку можно давать где угодно.",
                      fields: [
            SettingsField("pos_latest_version", "Актуальная версия кассы", hint: "напр. 1.0.1 (пусто = авто из /downloads)"),
            SettingsField("pos_update_mandatory", "Обязательное обновление",
                          kind: .choice(opts([("0", "Нет (спрашивать кассира)"), ("1", "Да (молча)")]))),
            SettingsField("pos_download_url", "Прямая ссылка на установщик",
                          hint: "необязательно; иначе берётся из папки /downloads", kind: .url),
        ]),
        SettingsGroup("Наши приложения",
                      note: "Эти ссылки показываются в футере сайта, в баннере «Скачать приложение» на телефоне и в панели продавца. Пустое поле = встроенный адрес (тот, что действует сейчас). Чтобы убрать ссылку совсем, впишите любой текст без http:// — например «нет».",
                      fields: [
            SettingsField("app_link_client_ios", "Приложение покупателя — App Store", kind: .url),
            SettingsField("app_link_client_android", "Приложение покупателя — RuStore", kind: .url),
            SettingsField("app_link_seller_ios", "Приложение продавца — App Store", kind: .url),
            SettingsField("app_link_seller_android", "Приложение продавца — RuStore",
                          hint: "пока пусто: сборки продавца для Android в магазине нет", kind: .url),
        ]),
        SettingsGroup("Яндекс.Карты (зоны доставки)", fields: [
            SettingsField("yandex_maps_key", "Ключ Яндекс.Карт (JS API)",
                          hint: "для редактора зон и карты доставки. Домен yumurta.ru и поддомены должны быть в белом списке ключа в кабинете разработчика Яндекса"),
        ]),
        SettingsGroup("Доска объявлений",
                      note: "Цену и срок для отдельной категории задавайте в разделе «Объявления» → «Категории и цены»: там значения этих полей можно переопределить.",
                      fields: [
            SettingsField("ads_enabled", "Доска объявлений",
                          hint: "Выключено — раздел пропадает с сайта и из приложений клиента, подать новое объявление нельзя. Уже размещённые не удаляются.",
                          kind: .choice(opts([("1", "Включена"), ("0", "Выключена")]))),
            SettingsField("ads_default_price", "Цена размещения по умолчанию, ₽",
                          hint: "применяется к категориям, у которых своя цена не задана", kind: .decimal),
            SettingsField("ads_default_days", "Срок публикации по умолчанию, дней", kind: .integer),
            SettingsField("ads_grace_days", "Удалять через, дней после истечения",
                          hint: "объявление и его фотографии стираются с сервера безвозвратно", kind: .integer),
            SettingsField("ads_max_photos", "Фотографий на объявление, макс.", kind: .integer),
            SettingsField("ads_max_active_per_user", "Активных объявлений на человека, макс.", kind: .integer),
        ]),
        SettingsGroup("Жильё", fields: [
            SettingsField("lodging_photos_max", "Фотографий на объект, макс.",
                          hint: "каждое фото хранится в трёх размерах; 0 или пусто — вернётся значение по умолчанию (30)",
                          kind: .integer),
        ]),
        SettingsGroup("Кошелёк и лимиты площадки", fields: [
            SettingsField("wallet_block_below", "Стоп приёма заказов при балансе ниже, ₽",
                          hint: "0 — останавливать при любом минусе; поставьте −5000, чтобы разрешить долг до этой суммы; очень большое отрицательное число выключает остановку совсем",
                          kind: .signed),
            SettingsField("wallet_max_topup", "Максимум одного пополнения, ₽",
                          hint: "пусто — действует встроенный потолок 300 000 ₽", kind: .decimal),
        ]),
        SettingsGroup("Баллы и скидки", fields: [
            SettingsField("points_redeem_max_percent", "Баллами можно оплатить, % от заказа",
                          hint: "потолок для всей площадки: если магазин задал свой процент, действует меньший из двух",
                          kind: .decimal),
            SettingsField("promo_max_discount_percent", "Максимальная скидка по акциям и промокодам, %", kind: .decimal),
        ]),
        SettingsGroup("Подписка Yumurta Plus", fields: [
            SettingsField("plus_enabled", "Подписка включена",
                          hint: "сейчас «Нет»: подписка нигде не предлагается, надбавка к кешбэку и бесплатная доставка по ней не действуют. Поставите «Да» — привилегии снова заработают у тех, у кого срок подписки ещё не истёк. ПРОДАЖА подписки закрыта отдельно и этой настройкой не открывается",
                          kind: .choice(yesNo)),
            SettingsField("plus_price_month", "Цена подписки в месяц, ₽", kind: .decimal),
            SettingsField("plus_cashback_bonus", "Надбавка к кешбэку подписчику, %", kind: .decimal),
        ]),
        SettingsGroup("Платное продвижение", fields: [
            SettingsField("boost_price_day_product", "Продвижение товара, ₽ в день", kind: .decimal),
            SettingsField("boost_price_day_shop", "Продвижение организации, ₽ в день", kind: .decimal),
        ]),
        SettingsGroup("Помощник", fields: [
            SettingsField("ai_desc_daily_limit", "Описаний товаров на магазин в сутки, макс.", kind: .integer),
            SettingsField("ai_review_moderation", "Предмодерация отзывов помощником",
                          kind: .choice(opts([("on", "Включена"), ("off", "Выключена")]))),
        ]),
        SettingsGroup("Напоминание о брошенной корзине", fields: [
            SettingsField("abandoned_promo_code", "Промокод в письме-напоминании", hint: "пусто — письмо уходит без кода"),
        ]),
        SettingsGroup("Telegram", fields: [
            SettingsField("telegram_bot_token", "Токен бота",
                          hint: "от @BotFather; нужен и для поддержки в Telegram, и для оповещений ниже"),
            SettingsField("wallet_alert_telegram_chat", "Чат для оповещений о кошельках",
                          hint: "id чата или канала; пусто — не слать", kind: .signed),
            SettingsField("health_alert_telegram_chat", "Чат для оповещений о сбоях",
                          hint: "id чата или канала; пусто — не слать", kind: .signed),
        ]),
        SettingsGroup("Dadata (подсказки адресов)", fields: [
            SettingsField("dadata_token", "Токен Dadata (API key)",
                          hint: "подсказки адреса при оформлении заказа и в профиле. Из кабинета dadata.ru → Интеграция"),
            SettingsField("dadata_secret", "Секретный ключ Dadata",
                          hint: "нужен только для геокодинга/проверки ИНН; для подсказок можно оставить пустым"),
        ]),
    ]

    /// Все ключи, которые показывает сайт.
    static var knownKeys: Set<String> {
        var out = Set<String>()
        for g in groups {
            for f in g.fields { out.insert(f.key) }
        }
        return out
    }

    /// Подпись ключа (для списка изменений и ошибок сервера).
    static func label(for key: String) -> String {
        for g in groups {
            for f in g.fields where f.key == key { return f.label }
        }
        return extraLabels[key] ?? key
    }

    /// Ключи, которые сервер отдаёт, но сайт не показывает (только просмотр).
    static let extraLabels: [String: String] = [
        "iiko_app_id": "iiko: ID приложения площадки",
        "iiko_client_secret": "iiko: секрет приложения",
        "phone_otp_enabled": "Вход по коду SMS/звонок (1 — да, 0 — нет)",
        "commission_default_fixed": "Комиссия, если у организации своя не задана, ₽",
        "default_service_fee_payer": "Кто платит сервисный сбор по умолчанию",
    ]
}
