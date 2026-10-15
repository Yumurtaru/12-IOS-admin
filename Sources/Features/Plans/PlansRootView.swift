import SwiftUI

/// Раздел «Тарифы» (тарифные планы продавцов): список, добавление, правка
/// (название, цены, лимит товаров, функции, активность) и состояние
/// настройки «Тарифы включены» (seller_plans_enabled из настроек сайта).
///
/// Сервер: GET/POST /api/admin/plans, PUT /api/admin/plans/{id};
/// флаг — GET /api/admin/settings → seller_plans_enabled ("1" — включены).
/// Удаления тарифов на сервере нет — только выключение.
struct PlansRootView: View {
    let openId: Int?

    @StateObject private var model = PagedListModel(path: "/api/admin/plans", searchParam: nil)
    @StateObject private var flag = PlansFlagLoader()
    @State private var editing: PlansEditTarget?
    @State private var deepLinkDone = false

    init(openId: Int? = nil) {
        self.openId = openId
    }

    var body: some View {
        AdminListScreen("Тарифы", model: model, searchPrompt: nil, emptyText: "Тарифов нет",
                        header: AnyView(PlansFlagBanner(loader: flag))) { plan in
            planButton(plan)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = PlansEditTarget(plan: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Добавить тариф")
            }
        }
        .sheet(item: $editing) { target in
            PlansEditorSheet(plan: target.plan) {
                Task { await model.refresh() }
            }
        }
        .task { await flag.load() }
        .onChange(of: model.state) { _ in
            openDeepLinkIfReady()
        }
    }

    private func planButton(_ plan: JSON) -> some View {
        Button {
            editing = PlansEditTarget(plan: plan)
        } label: {
            PlansRow(plan: plan)
        }
        .buttonStyle(.plain)
    }

    private func openDeepLinkIfReady() {
        guard let id = openId, !deepLinkDone, model.state == .loaded else { return }
        deepLinkDone = true
        if let plan = model.items.first(where: { $0.id == id }) {
            editing = PlansEditTarget(plan: plan)
        }
    }
}

/// Что редактируем: nil — новый тариф.
struct PlansEditTarget: Identifiable {
    let id = UUID()
    let plan: JSON?
}

/// Состояние настройки «Тарифы (подписки) для продавцов».
@MainActor
final class PlansFlagLoader: ObservableObject {
    /// true — включены, false — выключены, nil — неизвестно (нет доступа к настройкам или ошибка).
    @Published private(set) var enabled: Bool?

    func load() async {
        do {
            let s = try await API.shared.get("/api/admin/settings")
            let raw = s["seller_plans_enabled"]
            enabled = raw.exists ? (raw.string == "1") : nil
        } catch {
            // Флаг — только подсказка: без доступа к настройкам раздел работает как обычно.
            if !APIError.isCancellation(error) { enabled = nil }
        }
    }
}

/// Плашка над списком: включены ли тарифы у продавцов.
struct PlansFlagBanner: View {
    @ObservedObject var loader: PlansFlagLoader

    var body: some View {
        Group {
            if loader.enabled == false {
                VStack(alignment: .leading, spacing: 8) {
                    InfoBanner("Тарифы отключены. Продавцы не видят раздел «Тариф» ни в панели, ни в приложениях, и подключить план нельзя. Планы можно настроить заранее — они появятся у продавцов, когда вы включите тарифы в настройках сайта.",
                               systemImage: "exclamationmark.triangle", color: Brand.amber)
                    Button {
                        AppRouter.shared.open(section: .settings)
                    } label: {
                        Label("Открыть настройки сайта", systemImage: "gearshape")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
            } else if loader.enabled == true {
                InfoBanner("Тарифы включены — продавцы видят и подключают активные планы.",
                           systemImage: "checkmark.circle", color: Brand.green)
            } else {
                EmptyView()
            }
        }
        .listRowSeparator(.hidden)
    }
}

/// Функции тарифа: features_json приходит строкой JSON (колонка json) или массивом.
enum PlansFeatures {
    static func list(_ plan: JSON) -> [String] {
        let f = plan["features_json"]
        var arr: [JSON] = []
        if f.isArray {
            arr = f.array
        } else if let s = f.string, let d = s.data(using: .utf8), let parsed = JSON.parse(d) {
            arr = parsed.array
        }
        var out: [String] = []
        for item in arr {
            if let t = item.nonEmptyString { out.append(t) }
        }
        return out
    }
}

/// Строка тарифа.
private struct PlansRow: View {
    let plan: JSON

    private var active: Bool { plan["is_active"].boolValue }

    private var pricesText: String {
        let m = Fmt.money(plan["price_monthly"]) + " / мес"
        let y = Fmt.money(plan["price_yearly"]) + " / год"
        return m + " · " + y
    }

    private var limitText: String {
        let n = plan["max_products"].int ?? 0
        if n <= 0 { return "Товаров: без ограничений" }
        return "Товаров: до " + Fmt.number(n)
    }

    private var featuresText: String? {
        let f = PlansFeatures.list(plan)
        if f.isEmpty { return nil }
        return f.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(plan["name"].stringValue)
                    .font(.body.weight(.semibold))
                    .foregroundColor(Brand.text)
                Spacer()
                StatusBadge(active ? "Активен" : "Выключен", color: active ? Brand.green : Brand.muted)
            }
            Text(pricesText)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundColor(Brand.text)
            Text(limitText)
                .font(.caption)
                .foregroundColor(Brand.muted)
            if let f = featuresText {
                Text(f)
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Лист добавления/правки тарифа.
struct PlansEditorSheet: View {
    let plan: JSON?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var priceMonthly: String
    @State private var priceYearly: String
    @State private var maxProducts: String
    @State private var features: String
    @State private var active: Bool
    @State private var busy = false
    @State private var error: String?
    @State private var askPrice = false

    init(plan: JSON?, onSaved: @escaping () -> Void) {
        self.plan = plan
        self.onSaved = onSaved
        _name = State(initialValue: plan?["name"].stringValue ?? "")
        _priceMonthly = State(initialValue: Fmt.decimalInput(plan?["price_monthly"].decimal ?? 0))
        _priceYearly = State(initialValue: Fmt.decimalInput(plan?["price_yearly"].decimal ?? 0))
        let maxP = plan?["max_products"].int ?? 0
        _maxProducts = State(initialValue: maxP > 0 ? String(maxP) : "")
        let feats = plan.map { PlansFeatures.list($0) } ?? []
        _features = State(initialValue: feats.joined(separator: "\n"))
        // Новый тариф — активен; у существующего — как на сервере.
        _active = State(initialValue: plan?["is_active"].bool ?? true)
    }

    private var planId: Int? { plan?.id }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FormTextField("Название", text: $name, prompt: "Стандарт")
                    FormDecimalField("Цена в месяц", text: $priceMonthly)
                    FormDecimalField("Цена в год", text: $priceYearly)
                    FormIntField("Лимит товаров", text: $maxProducts, prompt: "∞ — без ограничений")
                }
                Section {
                    FormMultilineField("Функции (по одной в строке)", text: $features, minHeight: 120)
                }
                Section {
                    FormToggle("Активен", isOn: $active, subtitle: "Доступен продавцам для подключения")
                }
                if let e = error {
                    Section { ErrorBanner(message: e) }
                }
                if let p = plan {
                    Section { JSONInspectorView(p) }
                }
            }
            .navigationTitle(planId == nil ? "Новый тариф" : "Тариф")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Сохранить") { trySave() }
                    }
                }
            }
            .confirmationDialog("Изменить цену тарифа?", isPresented: $askPrice, titleVisibility: .visible) {
                Button("Сохранить новую цену") { save() }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(priceChangeText)
            }
        }
        .interactiveDismissDisabled(busy)
    }

    // MARK: - Сохранение

    private struct Draft {
        let name: String
        let monthly: Decimal
        let yearly: Decimal
        let maxProducts: Int?
        let features: [String]
        let active: Bool
    }

    /// Разобрать поля; nil — ошибка уже показана.
    private func makeDraft() -> Draft? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { error = "Введите название"; return nil }
        guard let pm = parsePrice(priceMonthly) else { error = "Цена в месяц: введите число, например 990 или 990,50"; return nil }
        guard let py = parsePrice(priceYearly) else { error = "Цена в год: введите число, например 9900"; return nil }
        if pm < 0 || py < 0 { error = "Цена не может быть отрицательной"; return nil }
        let maxText = maxProducts.trimmingCharacters(in: .whitespaces)
        var maxValue: Int? = nil
        if !maxText.isEmpty {
            guard let v = Int(maxText), v >= 0 else { error = "Лимит товаров — целое число (пусто — без ограничений)"; return nil }
            maxValue = v > 0 ? v : nil
        }
        var lines: [String] = []
        for part in features.components(separatedBy: "\n") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { lines.append(t) }
        }
        return Draft(name: n, monthly: pm, yearly: py, maxProducts: maxValue, features: lines, active: active)
    }

    private func parsePrice(_ s: String) -> Decimal? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        return Fmt.parseDecimal(t)
    }

    private var priceChangeText: String {
        guard let d = makeDraftSilently() else { return "" }
        let oldM = Fmt.money(plan?["price_monthly"] ?? .null)
        let oldY = Fmt.money(plan?["price_yearly"] ?? .null)
        let newM = Fmt.money(d.monthly)
        let newY = Fmt.money(d.yearly)
        return "В месяц: " + oldM + " → " + newM + "\nВ год: " + oldY + " → " + newY
    }

    /// Разбор без показа ошибки (для текста подтверждения).
    private func makeDraftSilently() -> Draft? {
        guard let pm = parsePrice(priceMonthly), let py = parsePrice(priceYearly) else { return nil }
        return Draft(name: name, monthly: pm, yearly: py, maxProducts: nil, features: [], active: active)
    }

    private func priceChanged(_ d: Draft) -> Bool {
        guard let p = plan else { return false }
        let oldM = p["price_monthly"].decimal ?? 0
        let oldY = p["price_yearly"].decimal ?? 0
        return oldM != d.monthly || oldY != d.yearly
    }

    private func trySave() {
        error = nil
        guard let d = makeDraft() else { return }
        // Тарифы — деньги продавцов: смену цены подтверждаем с суммами.
        if priceChanged(d) {
            askPrice = true
        } else {
            save()
        }
    }

    private func payload(for d: Draft) -> [String: Any?] {
        let maxAny: Any? = d.maxProducts
        return [
            "name": d.name,
            "price_monthly": d.monthly,
            "price_yearly": d.yearly,
            "max_products": maxAny,
            "features": d.features,
            "is_active": d.active ? 1 : 0,
        ]
    }

    private func save() {
        guard !busy, let d = makeDraft() else { return }
        let requestBody = payload(for: d)
        let id = planId
        let wantActive = d.active
        busy = true
        error = nil
        Task { @MainActor in
            do {
                if let id = id {
                    try await API.shared.put("/api/admin/plans/" + String(id), body: requestBody)
                } else {
                    let res = try await API.shared.post("/api/admin/plans", body: requestBody)
                    // Сервер создаёт тариф всегда активным; если просили выключенный —
                    // сразу выключаем тем же PUT.
                    if !wantActive, let newId = res["id"].int {
                        try await API.shared.put("/api/admin/plans/" + String(newId), body: requestBody)
                    }
                }
                Haptics.success()
                busy = false
                onSaved()
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
