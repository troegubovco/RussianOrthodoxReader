//
//  FragmentView.swift
//  RussianOrthodoxReaderWatch
//
//  Отображает один фрагмент молитвы: заголовок молитвы (на первом фрагменте),
//  подзаголовок (только для одиночной молитвы на первом фрагменте), абзацы
//  текста и абзацы-указания курсивом.
//

import SwiftUI

struct FragmentView: View {
    let fragment: Fragment
    /// Показывать подзаголовок молитвы — только для одиночной молитвы на её первом фрагменте.
    let showsSubtitle: Bool
    let textStep: WatchTheme.TextStep

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var effectiveSize: CGFloat {
        WatchTheme.effectiveSize(step: textStep, dynamicTypeSize: dynamicTypeSize)
    }

    private var bodyLineSpacing: CGFloat {
        WatchTheme.lineSpacing(effectiveSize: effectiveSize)
    }

    private var bodyColor: Color {
        WatchTheme.bodyColor(luminanceReduced: isLuminanceReduced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: textStep.paragraphGap) {
            if fragment.showsTitle {
                Text(fragment.prayerTitle)
                    .font(WatchTheme.serif(effectiveSize + 1, weight: .semibold))
                    .foregroundStyle(WatchTheme.accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .allowsTightening(true)
                    // Меньше воздуха над заголовком: строка управления уже
                    // отделяет его от навигационной панели (снимки симулятора).
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                if showsSubtitle, let subtitle = fragment.prayerSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(WatchTheme.chrome(max(12, effectiveSize - 4)))
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsTightening(true)
                }
            }

            ForEach(Array(fragment.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                if paragraph.isRubric {
                    Text(paragraph.text)
                        .font(WatchTheme.serif(effectiveSize - 3, weight: .regular).italic())
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsTightening(true)
                        .accessibilityLabel("Указание: \(paragraph.text)")
                } else {
                    Text(WatchTheme.attributedBody(paragraph.text, base: bodyColor))
                        .font(WatchTheme.serif(effectiveSize))
                        .lineSpacing(bodyLineSpacing)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsTightening(true)
                        .accessibilityLabel(StressMarks.strip(WatchTheme.plainBody(paragraph.text)))
                }
            }
        }
    }
}
