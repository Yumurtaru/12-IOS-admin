import Foundation

/// Скрытие номеров телефона (раздел «Розыгрыши»: «показывать имя и последние 5 цифр»).
///
/// Только Foundation — файл проверяется отдельным скриптом без SwiftUI/UIKit.
///
/// ```
/// Fmt.maskPhone("79381121191")          // «+7 (•••) ••2-11-91»
/// Fmt.maskPhone("89381121191")          // «+7 (•••) ••2-11-91»
/// Fmt.maskPhone("+7 (938) 112-11-91")   // «+7 (•••) ••2-11-91»
/// Fmt.maskPhone("380501234567")         // «•••34567»
/// Fmt.maskPhone("")                     // nil — телефона нет, показывается только имя
/// Fmt.contactPhone("79381121191", hidden: false) // «79381121191» — как отдал сервер
/// Fmt.personName("  ", hidden: true)    // «Без имени»
/// ```
extension Fmt {
    /// Сколько последних цифр остаётся видно.
    static let maskVisibleDigits = 5

    /// Номер со скрытыми цифрами: видны только последние 5.
    ///
    /// Российский номер (11 цифр с 7 или 8 в начале, а также 10 цифр — так же, как
    /// его разбирает `Fmt.phone`, который покажет его «+7 (…)») →
    /// «+7 (•••) ••2-11-91». Другая длина → «•••» + последние 5 цифр (если цифр
    /// меньше пяти — «•••» + все, что есть). Буквы и знаки отбрасываются.
    /// Цифр нет (nil, пусто, «o:…» без цифр) → nil.
    static func maskPhone(_ s: String?) -> String? {
        guard let raw = s else { return nil }
        // Только ASCII-цифры: Character.isNumber пропустил бы «½», «٣» и т.п.
        var digits = String(raw.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init))
        if digits.isEmpty { return nil }
        if digits.count == 11, digits.hasPrefix("8") { digits = "7" + digits.dropFirst() }
        if digits.count == 10 { digits = "7" + digits }
        if digits.count == 11, digits.hasPrefix("7") {
            // 7 938 112 11 91 → видны «2», «11», «91» (последние 5 цифр).
            let a = Array(digits)
            let p1 = String(a[6]), p2 = String(a[7...8]), p3 = String(a[9...10])
            return "+7 (•••) ••" + p1 + "-" + p2 + "-" + p3
        }
        return "•••" + String(digits.suffix(maskVisibleDigits))
    }

    /// Телефон для показа в разделе: скрыт — `maskPhone`, иначе — как отдал сервер.
    /// nil — телефона нет (строку телефона не показывать).
    static func contactPhone(_ s: String?, hidden: Bool) -> String? {
        if hidden { return maskPhone(s) }
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Имя человека для показа. Пустое → «Без имени».
    ///
    /// Когда номера скрыты, в имени маскируются:
    ///  * почта — слово с «@» и точкой после него: «Анар ivan@mail.ru» → «Анар iv•••»;
    ///  * любая последовательность от 7 цифр (пробелы, скобки, дефисы, точки внутри
    ///    номера допускаются) — как `maskPhone`: «Анар 89381121191» →
    ///    «Анар +7 (•••) ••2-11-91», «Анар 380501234567» → «Анар •••34567».
    /// Остальное имя не трогается. Ничего не осталось — «Без имени».
    static func personName(_ s: String?, hidden: Bool) -> String {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { return "Без имени" }
        guard hidden else { return t }
        // Сначала почта (в ней бывают длинные цифры: 89381121191@mail.ru), потом номера.
        var out = replaceMatches(in: t, regex: nameEmailRegex) { email in
            let local = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let head = String(local.prefix(2))
            return head + "•••"
        }
        out = replaceMatches(in: out, regex: namePhoneRegex) { run in
            let digits = run.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.count
            guard digits >= 7 else { return run }
            return maskPhone(run) ?? run
        }
        let r = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "Без имени" : r
    }

    /// Слово с «@» и точкой после «@» — почта внутри имени. Скобки, кавычки, запятые
    /// вокруг почты в неё не входят: «Анар (ivan@mail.ru)» → «Анар (iv•••)».
    private static let nameEmailRegex = try? NSRegularExpression(
        pattern: "[^\\s@()<>\\[\\]\"«»,;:]*@[^\\s@()<>\\[\\]\"«»,;:]+\\.[^\\s@()<>\\[\\]\"«»,;:]+")

    /// Номер внутри имени: необязательные «+» и «(», затем цифры, между которыми
    /// пробелы, скобки, дефисы, точки; не меньше 7 цифр (проверяется отдельно —
    /// шаблон берёт от 7). Только ASCII-цифры.
    private static let namePhoneRegex = try? NSRegularExpression(pattern: "\\+?\\(?[0-9](?:[\\s\\u00A0().\\-]*[0-9]){6,}")

    /// Заменить все совпадения `regex` в `s` результатом `transform` (с конца, чтобы не сбить диапазоны).
    private static func replaceMatches(in s: String, regex: NSRegularExpression?,
                                       _ transform: (String) -> String) -> String {
        guard let re = regex else { return s }
        let ns = s as NSString
        var out = s
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: transform(String(out[r])))
        }
        return out
    }
}
