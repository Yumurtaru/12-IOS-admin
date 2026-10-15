import SwiftUI

// Поля форм с подписью над вводом — для Form/List. Значения держите в @State
// экрана, на сервер отправляйте через JSONBody/API (Fmt.parseDecimal для сумм).
//
// ```
// FormTextField("Название", text: $name, prompt: "Пекарня у дома")
// FormDecimalField("Комиссия", text: $commission, suffix: "%")     // «12,5» → Fmt.parseDecimal
// FormIntField("Порядок", text: $sort)
// FormToggle("Активен", isOn: $active)
// FormPicker("Тип", selection: $type, options: [PickerOption(value: "percent", label: "Процент")])
// FormDateField("С даты", date: $from)                                // Fmt.ymd(from) для сервера
// FormMultilineField("Текст", text: $body)
// ```

/// Однострочный текст с подписью.
struct FormTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var keyboard: UIKeyboardType = .default
    var autocapitalize: Bool = true

    init(_ title: String, text: Binding<String>, prompt: String = "", keyboard: UIKeyboardType = .default,
         autocapitalize: Bool = true) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.keyboard = keyboard
        self.autocapitalize = autocapitalize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldTitle(title)
            TextField(prompt, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(autocapitalize ? .sentences : .never)
                .autocorrectionDisabled(!autocapitalize)
        }
    }
}

/// Многострочный текст с подписью.
struct FormMultilineField: View {
    let title: String
    @Binding var text: String
    var minHeight: CGFloat = 100

    init(_ title: String, text: Binding<String>, minHeight: CGFloat = 100) {
        self.title = title
        self._text = text
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldTitle(title)
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
        }
    }
}

/// Целое число (строкой, чтобы поле можно было очистить). Разбор: `Int(text)`.
struct FormIntField: View {
    let title: String
    @Binding var text: String
    var prompt: String = "0"

    init(_ title: String, text: Binding<String>, prompt: String = "0") {
        self.title = title
        self._text = text
        self.prompt = prompt
    }

    private var invalid: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && Int(t) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldTitle(title)
            TextField(prompt, text: $text)
                .keyboardType(.numberPad)
            if invalid {
                Text("Введите целое число").font(.caption).foregroundColor(Brand.red)
            }
        }
    }
}

/// Десятичное число с запятой («12,5»). Разбор: `Fmt.parseDecimal(text)`.
struct FormDecimalField: View {
    let title: String
    @Binding var text: String
    var suffix: String? = "₽"
    var prompt: String = "0"

    init(_ title: String, text: Binding<String>, suffix: String? = "₽", prompt: String = "0") {
        self.title = title
        self._text = text
        self.suffix = suffix
        self.prompt = prompt
    }

    private var invalid: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && Fmt.parseDecimal(t) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldTitle(title)
            HStack {
                TextField(prompt, text: $text)
                    .keyboardType(.decimalPad)
                if let s = suffix {
                    Text(s).foregroundColor(Brand.muted)
                }
            }
            if invalid {
                Text("Число с запятой, не больше двух знаков после неё").font(.caption).foregroundColor(Brand.red)
            }
        }
    }
}

/// Переключатель.
struct FormToggle: View {
    let title: String
    @Binding var isOn: Bool
    var subtitle: String? = nil

    init(_ title: String, isOn: Binding<Bool>, subtitle: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.subtitle = subtitle
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let s = subtitle {
                    Text(s).font(.caption).foregroundColor(Brand.muted)
                }
            }
        }
    }
}

/// Выбор из списка (значение — строка для сервера).
struct FormPicker: View {
    let title: String
    @Binding var selection: String
    let options: [PickerOption]

    init(_ title: String, selection: Binding<String>, options: [PickerOption]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options) { opt in
                Text(opt.label).tag(opt.value)
            }
        }
    }
}

/// Дата (и при желании время). Для сервера: `Fmt.ymd(date)` / `Fmt.serverDateTime(date)`.
struct FormDateField: View {
    let title: String
    @Binding var date: Date
    var withTime: Bool = false

    init(_ title: String, date: Binding<Date>, withTime: Bool = false) {
        self.title = title
        self._date = date
        self.withTime = withTime
    }

    var body: some View {
        DatePicker(title, selection: $date, displayedComponents: withTime ? [.date, .hourAndMinute] : [.date])
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.timeZone, Fmt.moscow)
    }
}

/// Подпись поля (мелкая, серая).
struct FieldTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(Brand.muted)
    }
}
