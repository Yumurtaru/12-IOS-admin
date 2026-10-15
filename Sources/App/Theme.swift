import SwiftUI
import UIKit

private extension UIColor {
    convenience init(rgb: UInt) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Адаптивный цвет (светлая/тёмная тема).
private func dyn(_ light: UInt, _ dark: UInt) -> Color {
    Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
}

/// Палитра Yumurta (как в приложениях продавца и клиента). Тема — системная.
enum Brand {
    /// Фирменный оранжевый #FF3B00 — акцент, кнопки, выбранная вкладка.
    static let accent = Color(red: 1.0, green: 0.231, blue: 0.0)
    /// Янтарный #FFB800 — предупреждения «ждёт действия».
    static let amber  = Color(red: 1.0, green: 0.722, blue: 0.0)
    /// Фон экранов.
    static let bg     = dyn(0xF2F2F7, 0x111114)
    /// Фон карточек.
    static let card   = dyn(0xFFFFFF, 0x1C1C1E)
    /// Основной текст.
    static let text   = dyn(0x1C1C1E, 0xEDEDED)
    /// Второстепенный текст.
    static let muted  = dyn(0x8E8E93, 0x8E8E93)
    /// Рамки и разделители.
    static let border = dyn(0xE5E5EA, 0x2A2A2E)
    /// Фон чипов фильтров.
    static let chip   = dyn(0xE6E6EB, 0x2A2A2E)
    /// Успех / «активно».
    static let green  = Color(red: 0.20, green: 0.78, blue: 0.45)
    /// Ошибка / «заблокировано».
    static let red    = Color(red: 1.0, green: 0.231, blue: 0.188)
    /// Нейтральный синий — информационные статусы.
    static let blue   = Color(red: 0.0, green: 0.48, blue: 1.0)
}
