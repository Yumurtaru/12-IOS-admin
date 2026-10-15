import SwiftUI
import UIKit

/// «Все поля»: любой JSON-объект как читаемое дерево «ключ — значение».
/// Ставится в конец экрана деталей, чтобы ничего из ответа сервера не было скрыто.
///
/// ```
/// List {
///     Section("Основное") { ... }
///     Section { JSONInspectorView(loader.data) }   // свёрнуто по умолчанию
/// }
/// ```
/// Вложенные объекты и массивы раскрываются по нажатию; долгое нажатие на
/// значение копирует его.
struct JSONInspectorView: View {
    let json: JSON
    let title: String
    @State private var expanded: Bool

    /// - Parameters:
    ///   - json: что показать;
    ///   - title: подпись раскрывашки;
    ///   - expanded: раскрыто ли сразу.
    init(_ json: JSON, title: String = "Все поля", expanded: Bool = false) {
        self.json = json
        self.title = title
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            JSONNodeList(json: json)
        } label: {
            Label(title, systemImage: "curlybraces")
                .foregroundColor(Brand.text)
        }
    }
}

/// Содержимое узла: строки ключей объекта или элементов массива.
struct JSONNodeList: View {
    let json: JSON

    init(json: JSON) { self.json = json }

    private var entries: [JSONEntry] {
        switch json {
        case .object(let o):
            return JSONNodeList.orderedKeys(o).map { JSONEntry(key: $0, value: o[$0] ?? .null) }
        case .array(let a):
            var out: [JSONEntry] = []
            for (i, v) in a.enumerated() { out.append(JSONEntry(key: "[" + String(i) + "]", value: v)) }
            return out
        default:
            return [JSONEntry(key: "значение", value: json)]
        }
    }

    var body: some View {
        if entries.isEmpty {
            Text(json.isArray ? "пустой список" : "пусто")
                .font(.footnote)
                .foregroundColor(Brand.muted)
        } else {
            ForEach(entries) { entry in
                JSONNodeRow(key: entry.key, value: entry.value)
            }
        }
    }

    /// id первым, затем по алфавиту.
    static func orderedKeys(_ o: [String: JSON]) -> [String] {
        let sorted = o.keys.sorted()
        let head = sorted.filter { $0 == "id" }
        let tail = sorted.filter { $0 != "id" }
        return head + tail
    }
}

/// Пара «ключ — значение» узла.
struct JSONEntry: Identifiable {
    let key: String
    let value: JSON
    var id: String { key }

    init(key: String, value: JSON) {
        self.key = key
        self.value = value
    }
}

/// Одна строка дерева. Вложенное раскрывается (рекурсия через AnyView).
struct JSONNodeRow: View {
    let key: String
    let value: JSON

    init(key: String, value: JSON) {
        self.key = key
        self.value = value
    }

    private var isContainer: Bool { value.isObject || value.isArray }

    private var summary: String {
        switch value {
        case .object(let o): return "{" + String(o.count) + "}"
        case .array(let a): return "[" + String(a.count) + "]"
        default: return value.raw
        }
    }

    var body: some View {
        if isContainer {
            DisclosureGroup {
                AnyView(JSONNodeList(json: value))
            } label: {
                keyValue
            }
        } else {
            keyValue
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = value.raw
                        Haptics.tap()
                    } label: { Label("Скопировать значение", systemImage: "doc.on.doc") }
                }
        }
    }

    private var keyValue: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.caption.monospaced())
                .foregroundColor(Brand.muted)
            Spacer(minLength: 6)
            Text(summary)
                .font(.footnote)
                .foregroundColor(value.isNull ? Brand.muted : Brand.text)
                .multilineTextAlignment(.trailing)
                .lineLimit(isContainer ? 1 : 12)
                .textSelection(.enabled)
        }
    }
}
