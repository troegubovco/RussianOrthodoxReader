//
//  WatchTheme.swift
//  RussianOrthodoxReaderWatch
//
//  Типографика и цвета экрана чтения на часах: системная антиква (New York)
//  для текста молитвы, системный шрифт для органов управления, шаги размера
//  текста и цвета, учитывающие режим Always-On (сниженная яркость).
//

import SwiftUI

enum WatchTheme {

    // MARK: - Цвета

    static let background = Color.black
    static let body = Color(white: 0.95)
    static let muted = Color(red: 0.604, green: 0.569, blue: 0.533)
    static let accent = Color(red: 0.851, green: 0.663, blue: 0.235)

    /// Цвет текста молитвы с учётом Always-On (сниженная яркость экрана).
    static func bodyColor(luminanceReduced: Bool) -> Color {
        luminanceReduced ? Color(white: 0.78) : body
    }

    // MARK: - Шаг размера текста

    enum TextStep: Int, CaseIterable {
        case small = 0
        case regular = 1
        case large = 2
        case extraLarge = 3

        var basePt: CGFloat {
            switch self {
            case .small: return 15
            case .regular: return 17
            case .large: return 19
            case .extraLarge: return 22
            }
        }

        var label: String {
            switch self {
            case .small: return "Мелкий"
            case .regular: return "Обычный"
            case .large: return "Крупный"
            case .extraLarge: return "Очень крупный"
            }
        }

        var paragraphGap: CGFloat {
            switch self {
            case .small: return 12
            case .regular: return 14
            case .large: return 15
            case .extraLarge: return 18
            }
        }
    }

    /// Коэффициент масштабирования по Dynamic Type.
    static func dynamicTypeFactor(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: return 0.88
        case .small: return 0.92
        case .medium: return 0.96
        case .large: return 1.0
        case .xLarge: return 1.08
        case .xxLarge: return 1.16
        case .xxxLarge: return 1.24
        case .accessibility1: return 1.40
        case .accessibility2: return 1.55
        case .accessibility3: return 1.70
        case .accessibility4: return 1.85
        case .accessibility5: return 2.00
        @unknown default: return 1.0
        }
    }

    /// Эффективный размер тела текста: базовый × фактор Dynamic Type, зажатый в 13…34.
    static func effectiveSize(step: TextStep, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let raw = (step.basePt * dynamicTypeFactor(dynamicTypeSize)).rounded()
        return min(max(raw, 13), 34)
    }

    /// Интерлиньяж: 0,22 × кегль (шаг строки ≈ 1,4 кегля). Измерено на
    /// симуляторе 42/49 мм: ударения (U+0301) не задевают верхнюю строку,
    /// а на экран помещается заметно больше текста, чем при 0,30.
    static func lineSpacing(effectiveSize: CGFloat) -> CGFloat {
        (effectiveSize * 0.22).rounded()
    }

    // MARK: - Шрифты

    /// Антиква (New York) — для текста молитвы.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Системный шрифт — для органов управления и служебного текста.
    static func chrome(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // MARK: - Подсветка вставленных имён

    /// Подсвечивает вставленные маркерами ⟦…⟧ имена акцентным цветом
    /// (порт `attributed()` из PrayerDetailView, без начертания — только цвет).
    /// Текст без маркеров имён ⟦…⟧ — для VoiceOver.
    static func plainBody(_ text: String) -> String {
        text.replacingOccurrences(of: PrayerTemplateRenderer.nameMarkerOpen, with: "")
            .replacingOccurrences(of: PrayerTemplateRenderer.nameMarkerClose, with: "")
    }

    static func attributedBody(_ text: String, base: Color) -> AttributedString {
        var result = AttributedString()
        var remainder = Substring(text)
        while let open = remainder.range(of: PrayerTemplateRenderer.nameMarkerOpen),
              let close = remainder.range(of: PrayerTemplateRenderer.nameMarkerClose,
                                          range: open.upperBound..<remainder.endIndex) {
            var plain = AttributedString(String(remainder[..<open.lowerBound]))
            plain.foregroundColor = base
            result += plain

            var name = AttributedString(String(remainder[open.upperBound..<close.lowerBound]))
            name.foregroundColor = accent
            result += name

            remainder = remainder[close.upperBound...]
        }
        var tail = AttributedString(String(remainder))
        tail.foregroundColor = base
        result += tail
        return result
    }
}

/// Простой переключатель на несколько значений в духе сегментированного
/// контрола — `PickerStyle.segmented` недоступен на watchOS.
struct WatchSegmentedControl<Value: Hashable>: View {
    let segments: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(segments, id: \.value) { segment in
                Button {
                    selection = segment.value
                } label: {
                    Text(segment.title)
                        .font(WatchTheme.chrome(13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selection == segment.value ? Color.black : WatchTheme.body)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == segment.value ? WatchTheme.accent : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension Int {
    /// «1 молитва», «4 молитвы», «12 молитв».
    var molitvCount: String {
        let n = abs(self) % 100
        let n1 = n % 10
        let word: String
        if (11...19).contains(n) { word = "молитв" }
        else if n1 == 1 { word = "молитва" }
        else if (2...4).contains(n1) { word = "молитвы" }
        else { word = "молитв" }
        return "\(self) \(word)"
    }
}
