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
    /// Многострочный текст (указания помощнику).
    case area
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

    /// Та же настройка с другой подсказкой (сервер сообщил, что ключ уже задан в файле секретов).
    func withHint(_ newHint: String) -> SettingsField {
        SettingsField(key, label, hint: newHint, kind: kind)
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

/// Состав экрана — все 116 полей admin.js settings() (BLOCKS) плюс «Подпись APK»; группы
/// разбиты по подзаголовкам сайта. Динамические поля «Версии приложений» (app_ver_*) сайт строит
/// по списку приложений сервера — их здесь нет (их ведёт раздел «Приложения»).
/// Секреты (ключи API, токены) помечает сам сервер в `_secret_keys` — такие поля экран
/// показывает как «Сейчас: маска» + «Новое значение (пусто — не менять)» + «Стереть ключ».
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
            SettingsField("commission_default_fixed", "Комиссия, если у организации не задана, ₽",
                          hint: "у Yumurta комиссии нет — площадка живёт с сервисного сбора, поэтому обычно 0",
                          kind: .decimal),
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
            SettingsField("appointment_max_per_client_day", "Записей на услуги у одного клиента в организации за день",
                          hint: "0 — без ограничения; защищает мастера от того, кто занимает весь день записями",
                          kind: .integer),
            SettingsField("phone_otp_enabled", "Вход и подтверждение кодом по SMS/звонку",
                          hint: "выключено намеренно: SMS платные, а регистрация по чужому номеру открывала путь к захвату аккаунта. Включайте только с подключённым SMS-шлюзом и лимитом ниже",
                          kind: .choice(opts([("0", "Выключено — только почта"), ("1", "Включено")]))),
            SettingsField("sms_daily_cap", "Кодов входа (SMS/звонок) в сутки, не больше",
                          hint: "защита от накрутки платных SMS; 0 — без ограничения", kind: .integer),
            SettingsField("modifiers_required_enforce", "Заказ без обязательной добавки",
                          hint: "Включайте, когда у покупателей разойдутся новые версии приложений: старые Android и iOS проверяли только группы «выбрать одно», и такой заказ из них упрётся в отказ.",
                          kind: .choice(opts([("0", "Принимать (как раньше)"), ("1", "Отклонять")]))),
        ]),
        // Волна А75 сайта: автоактивация организации при регистрации (seller_auto_approve).
        // Без этой группы ключ попадал в «Прочие (только просмотр)» и поменять его было нельзя.
        SettingsGroup("Регистрация организаций", fields: [
            SettingsField("seller_auto_approve", "Новая организация после регистрации",
                          hint: "«Активируется сразу» — после подтверждения почты продавец сразу входит в панель, заполняет информацию и товары и нажимает «Показать организацию»; клиентам она не видна и заказы не принимает, пока вы не опубликуете её (раздел «Магазины» → «Готовы к публикации»). В «Заявках магазинов» такая заявка отмечена «автоматически». «Ждёт одобрения» — как раньше: каждую заявку одобряете вручную. Уже поданные заявки «на рассмотрении» переключатель не трогает.",
                          kind: .choice(opts([("1", "Активируется сразу (не опубликована)"), ("0", "Ждёт одобрения администратора")]))),
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
            SettingsField("app_link_courier_ios", "Приложение курьера — App Store", kind: .url),
            SettingsField("app_link_courier_android", "Приложение курьера — RuStore / Google Play",
                          hint: "пусто — «Стать курьером» ведёт на сайт /kurer", kind: .url),
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
        SettingsGroup("ИИ: поставщик",
                      note: "Откуда ИИ: данные уходят выбранному поставщику. Российские варианты (YandexGPT, GigaChat, Cloud.ru) обрабатывают данные в России; Claude и DeepSeek напрямую — за рубежом (трансграничная передача по 152-ФЗ). Проверка подключения, расход за сегодня и месяц, переписки и оценки — в разделе «Помощник (ИИ)».",
                      fields: [
            SettingsField("ai_provider", "Поставщик",
                          hint: "После выбора и сохранения нажмите «Проверить связь» в разделе «Помощник (ИИ)». Накладные по фото работают только через Claude.",
                          kind: .choice(opts([("", "Авто: есть ключ Anthropic — Claude, иначе первый поставщик с ключом"),
                                              ("claude", "Claude (Anthropic) — за рубежом; из России может не работать"),
                                              ("yandex", "YandexGPT (Yandex AI Studio) — данные в России"),
                                              ("gigachat", "GigaChat (Сбер) — данные в России"),
                                              ("openai", "OpenAI-совместимый API: Cloud.ru / DeepSeek / свой адрес")]))),
        ]),
        SettingsGroup("ИИ: Claude (Anthropic) — за рубежом", fields: [
            SettingsField("anthropic_api_key", "Ключ API Anthropic (Claude)",
                          hint: "console.anthropic.com → API Keys. Нужен также для «Накладная по фото»"),
        ]),
        SettingsGroup("ИИ: YandexGPT — данные в России",
                      note: "Yandex AI Studio: ключ — сервисный аккаунт с ролью ai.languageModels.user → API-ключ; идентификатор каталога — в консоли Yandex Cloud.",
                      fields: [
            SettingsField("ai_yandex_key", "Yandex: API-ключ", hint: "выдаётся один раз при создании — сохраните"),
            SettingsField("ai_yandex_folder", "Yandex: идентификатор каталога (folder id)", hint: "например b1gxxxxxxxxxxxxxxxxx"),
            SettingsField("ai_yandex_model", "Yandex: модель для описаний и модерации", hint: "yandexgpt-lite — дешевле (по умолчанию)"),
            SettingsField("ai_yandex_support_model", "Yandex: модель помощника",
                          hint: "yandexgpt (Pro) — умнее и в 6 раз дороже; для помощника сначала попробуйте yandexgpt-lite"),
        ]),
        SettingsGroup("ИИ: GigaChat (Сбер) — данные в России",
                      note: "developers.sber.ru → GigaChat API → Authorization key. Бесплатный тариф для физлиц (PERS) — только для некоммерческого использования; для бизнеса нужен B2B/CORP.",
                      fields: [
            SettingsField("ai_gigachat_key", "GigaChat: Authorization key", hint: "строка из личного кабинета (base64), без слова Basic"),
            SettingsField("ai_gigachat_scope", "GigaChat: доступ (scope)",
                          kind: .choice(opts([("GIGACHAT_API_PERS", "GIGACHAT_API_PERS — физлица (некоммерческое)"),
                                              ("GIGACHAT_API_B2B", "GIGACHAT_API_B2B — юрлица, пакеты токенов"),
                                              ("GIGACHAT_API_CORP", "GIGACHAT_API_CORP — юрлица, постоплата")]))),
            SettingsField("ai_gigachat_model", "GigaChat: модель для описаний и модерации",
                          hint: "GigaChat-2 по умолчанию; актуальные имена покажет «Проверить связь»"),
            SettingsField("ai_gigachat_support_model", "GigaChat: модель помощника", hint: "GigaChat-2-Pro по умолчанию"),
        ]),
        SettingsGroup("ИИ: OpenAI-совместимый API (Cloud.ru, DeepSeek, свой)",
                      note: "POST {адрес}/chat/completions, ключ в заголовке Authorization: Bearer.",
                      fields: [
            SettingsField("ai_openai_preset", "Пресет",
                          hint: "Cloud.ru: адрес https://foundation-models.api.cloud.ru/v1, ключ — «Учётные данные доступа → Создать API-ключ». Внутри Cloud.ru (данные в РФ): deepseek-ai/DeepSeek-V4-Pro, GigaChat, Qwen3.x, Kimi-K2.6, GLM, gpt-oss-120b. Через внешних провайдеров (данные за рубеж): deepseek-ai/DeepSeek-V4-Flash, Claude, Gemini и др.",
                          kind: .choice(opts([("cloudru", "Cloud.ru Foundation Models — оплата в рублях; DeepSeek V4 Pro внутри Cloud.ru, данные в РФ (рекомендуется)"),
                                              ("deepseek", "DeepSeek напрямую (api.deepseek.com) — серверы в Китае: 152-ФЗ, нужно уведомление Роскомнадзора"),
                                              ("custom", "Свой адрес API")]))),
            SettingsField("ai_openai_base_url", "Свой адрес API (только для пресета «Свой адрес»)",
                          hint: "https://…/v1 — только https", kind: .url),
            SettingsField("ai_openai_key", "API-ключ (Cloud.ru / DeepSeek / свой)"),
            SettingsField("ai_openai_model", "Модель для описаний и модерации",
                          hint: "пусто — по пресету (Cloud.ru: ai-sage/GigaChat3-10B-A1.8B, DeepSeek: deepseek-flash)"),
            SettingsField("ai_openai_support_model", "Модель помощника",
                          hint: "пусто — по пресету (Cloud.ru: deepseek-ai/DeepSeek-V4-Pro, DeepSeek: deepseek-flash). Рассуждающие модели отвечают медленнее"),
            SettingsField("ai_openai_region", "Для своего адреса: где обрабатываются данные",
                          hint: "У пресетов регион определяется моделью автоматически",
                          kind: .choice(opts([("abroad", "За рубежом (персональные данные скрываются)"), ("ru", "В России")]))),
            SettingsField("ai_openai_vision", "Для своего адреса: модель понимает фото",
                          kind: .choice(opts([("0", "Нет — описание по данным товара"), ("1", "Да — передавать первое фото")]))),
        ]),
        SettingsGroup("ИИ: цены для расчёта расхода",
                      note: "₽ за 1 млн токенов. Пусто — встроенные цены (видны в разделе «Помощник (ИИ)»). Расход считается по токенам из ответов поставщика.",
                      fields: [
            SettingsField("ai_usd_rub", "Курс ₽ за $1 (для цен в долларах)", hint: "Claude и DeepSeek считаются в долларах", kind: .decimal),
            SettingsField("ai_price_in_claude", "Claude: вход, ₽/1 млн", kind: .decimal),
            SettingsField("ai_price_out_claude", "Claude: выход, ₽/1 млн", kind: .decimal),
            SettingsField("ai_price_in_yandex", "Yandex: вход, ₽/1 млн", kind: .decimal),
            SettingsField("ai_price_out_yandex", "Yandex: выход, ₽/1 млн", kind: .decimal),
            SettingsField("ai_price_in_gigachat", "GigaChat: вход, ₽/1 млн", kind: .decimal),
            SettingsField("ai_price_out_gigachat", "GigaChat: выход, ₽/1 млн", kind: .decimal),
            SettingsField("ai_price_in_openai", "Cloud.ru / DeepSeek / свой: вход, ₽/1 млн",
                          hint: "Cloud.ru: цену модели смотрите в её карточке в консоли", kind: .decimal),
            SettingsField("ai_price_out_openai", "Cloud.ru / DeepSeek / свой: выход, ₽/1 млн", kind: .decimal),
        ]),
        SettingsGroup("ИИ: помощник и функции", fields: [
            SettingsField("ai_support_enabled", "Помощник на сайте и в кабинете",
                          kind: .choice(opts([("1", "Включён"), ("0", "Выключен")]))),
            SettingsField("ai_support_guests", "Отвечать гостям без входа",
                          kind: .choice(opts([("1", "Да"), ("0", "Нет — только вошедшим")]))),
            SettingsField("ai_support_model", "Claude: модель помощника",
                          kind: .choice(opts([("claude-haiku-5-5", "Claude Haiku 5.5 — быстро и дёшево (рекомендуется)"),
                                              ("claude-sonnet-5-5", "Claude Sonnet 5.5 — умнее, дороже"),
                                              ("claude-opus-5-5", "Claude Opus 5.5 — самый умный, дорогой"),
                                              ("claude-haiku-4-5", "Claude Haiku 4.5 — прежнее поколение")]))),
            SettingsField("ai_support_daily_user", "Вопросов в сутки на человека", hint: "0 — без ограничения", kind: .integer),
            SettingsField("ai_support_daily_guest", "Вопросов в сутки на гостя (по IP)", kind: .integer),
            SettingsField("ai_support_daily_total", "Вопросов в сутки на всю площадку",
                          hint: "защита бюджета API; 0 — без ограничения", kind: .integer),
            SettingsField("ai_support_extra", "Дополнительные указания помощнику",
                          hint: "необязательно: акции, часы работы поддержки, о чём говорить и о чём нет. До 4000 знаков",
                          kind: .area),
            SettingsField("ai_support_keep_days", "Хранить переписки, дней",
                          hint: "старые разговоры и IP гостей удаляются; 0 — хранить всегда", kind: .integer),
            SettingsField("ai_model", "Claude: модель для описаний и модерации",
                          kind: .choice(opts([("claude-haiku-5-5", "Claude Haiku 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                                              ("claude-opus-5-5", "Claude Opus 5.5"),
                                              ("claude-haiku-4-5", "Claude Haiku 4.5 (выводится из обращения)")]))),
            SettingsField("ai_desc_daily_limit", "Описаний товаров на магазин в сутки, макс.", kind: .integer),
            SettingsField("ai_review_moderation", "Предмодерация отзывов помощником",
                          kind: .choice(opts([("on", "Включена"), ("off", "Выключена")]))),
        ]),
        SettingsGroup("ИИ: накладная по фото и поиск фото", fields: [
            SettingsField("ai_invoice_enabled", "Накладная по фото (Склад → «Распознать накладную по фото»)",
                          hint: "фото уходят в сервис Claude; ключ API — выше",
                          kind: .choice(opts([("1", "Включена"), ("0", "Выключена")]))),
            SettingsField("ai_invoice_model", "Модель для накладных по фото",
                          kind: .choice(opts([("claude-opus-5-5", "Claude Opus 5.5 — точнее всех (рекомендуется), ≈ 20–40 ₽ за накладную"),
                                              ("claude-sonnet-5-5", "Claude Sonnet 5.5 — дешевле, чуть чаще ошибается"),
                                              ("claude-haiku-5-5", "Claude Haiku 5.5 — самая дешёвая, для чётких печатных накладных")]))),
            SettingsField("ai_invoice_effort", "Глубина разбора накладной",
                          kind: .choice(opts([("low", "low — быстро"), ("medium", "medium"), ("high", "high — рекомендуется"),
                                              ("xhigh", "xhigh"), ("max", "max — медленно и дорого")]))),
            SettingsField("ai_invoice_daily_limit", "Накладных по фото на магазин в сутки, макс.",
                          hint: "30 по умолчанию, 0 — выключить; защита бюджета API", kind: .integer),
            SettingsField("ai_invoice_keep_days", "Хранить фото накладных, дней",
                          hint: "14 по умолчанию; потом фото и задание удаляются (созданный приход остаётся)", kind: .integer),
            SettingsField("photo_search_daily_limit", "Поиск фото в Яндексе на магазин в сутки, макс.",
                          hint: "кнопка «Найти фото в интернете» в карточке товара; 30 по умолчанию, 0 — выключить. Один поиск ≈ 0,92 ₽; ключи Яндекс.Поиска лежат в файле секретов сервера",
                          kind: .integer),
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
        SettingsGroup("iiko", fields: [
            SettingsField("iiko_app_id", "iiko: ID приложения площадки", hint: "public-api.iikoweb.ru/portal → приложение"),
            SettingsField("iiko_client_secret", "iiko: секрет приложения"),
        ]),
        SettingsGroup("SEO и аналитика",
                      note: "Подтверждение сайта в поисковиках, счётчики посещаемости и быстрая переиндексация (IndexNow). Очередь IndexNow и её кнопки — на сайте.",
                      fields: [
            SettingsField("seo_yandex_verification", "Яндекс.Вебмастер: код подтверждения",
                          hint: "Вебмастер → Права доступа → метатег; можно вставить тег целиком. Выводится в <head> всегда, когда задан"),
            SettingsField("seo_google_verification", "Google Search Console: код подтверждения",
                          hint: "тег google-site-verification; можно вставить целиком"),
            SettingsField("seo_ym_id", "Яндекс.Метрика: номер счётчика", hint: "только цифры; пусто — счётчика нет"),
            SettingsField("seo_ga4_id", "Google Analytics 4: идентификатор потока", hint: "вида G-XXXXXXXXXX; пусто — GA нет"),
            SettingsField("analytics_scripts_enabled", "Подключать код счётчиков",
                          hint: "код — внешний файл /assets/js/analytics.js; домены Метрики и GA4 разрешены в политике безопасности (CSP) по официальным справкам. Вебвизор выключен",
                          kind: .choice(opts([("1", "Да — если задан номер счётчика"), ("0", "Нет — код не выводится совсем")]))),
            SettingsField("indexnow_enabled", "IndexNow: сообщать Яндексу и Bing об изменениях",
                          hint: "новые и изменённые товары, организации, объявления, вакансии, жильё и статьи справки уходят пачками раз в 10 минут (крон)",
                          kind: .choice(opts([("1", "Включено"), ("0", "Выключено")]))),
        ]),
        SettingsGroup("Подпись APK на сайте",
                      note: "Если отпечаток выложенного APK не совпадёт с ожидаемым — на сайте будет предупреждение.",
                      fields: [
            SettingsField("apk_cert_expected_client", "Покупатель: ожидаемый SHA-256 подписи", hint: SettingsCatalog.apkHint),
            SettingsField("apk_cert_expected_seller", "Продавец: ожидаемый SHA-256 подписи", hint: SettingsCatalog.apkHint),
            SettingsField("apk_cert_expected_courier", "Курьер: ожидаемый SHA-256 подписи", hint: SettingsCatalog.apkHint),
            SettingsField("apk_cert_expected_station", "Станция: ожидаемый SHA-256 подписи", hint: SettingsCatalog.apkHint),
        ]),
    ]

    private static let apkHint = "как в RuStore (Подпись приложения), apksigner verify --print-certs app.apk или keytool -list -v -keystore <ключ выпуска>; двоеточия можно"

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
        "default_service_fee_payer": "Кто платит сервисный сбор по умолчанию",
    ]
}
