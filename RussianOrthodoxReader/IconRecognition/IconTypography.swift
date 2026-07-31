import CoreGraphics

/// Типографика экранов распознавания икон. Это справочный интерфейс, а не
/// читалка: размер шрифта Писания (по умолчанию 33pt, до 52pt) сюда напрямую
/// не переносится, а учитывается с потолком — иначе жития, молитвы и кнопки
/// разрастаются до плакатных размеров.
extension AppTypography {
    static func iconScreen(userFontSize: CGFloat) -> AppTypography {
        AppTypography(base: min(userFontSize, 26))
    }
}
