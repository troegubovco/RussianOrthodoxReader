import SwiftUI

/// Кольцо прогресса плана чтения — один компонент на iPhone и часы (§5.1).
///
/// Цвета передаются снаружи: iPhone — `OrthodoxColorsFallback.accent`, часы —
/// `WatchTheme.accent`; ни то, ни другое не доступно из `Shared/`, поэтому
/// компонент не знает о конкретной цветовой схеме.
///
/// Центр кольца и подписи вокруг него (название плана, «Кафизма 13»,
/// `accessibilityLabel`/`accessibilityValue`/`accessibilityHint`) задаёт
/// вызывающий код — кольцо ничего не знает о смысле плана, только рисует
/// дугу.
struct ProgressRingView<Label: View>: View {
    /// 0…1 — доля выполненного; вне диапазона зажимается внутри `body`.
    let progress: Double
    var diameter: CGFloat
    var lineWidth: CGFloat
    /// Цвет дуги прогресса (золото на обеих платформах, разный оттенок).
    var stroke: Color
    var trackOpacity: Double = 0.15
    /// Доля «сегодняшней» единицы — дуга-подсказка сразу за прогрессом,
    /// 0, если сегодня уже отмечено (единица влилась в основную дугу).
    var todayHint: Double = 0
    /// Кольцо завершено целиком — рисуется сплошной дугой без зазора на
    /// стыке (`trim(to: progress)` может не дотягивать один-два пикселя из-за
    /// `lineCap: .round`, что на скруглении круга в 360° заметно как щель).
    var isComplete: Bool = false
    @ViewBuilder var label: () -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var effectiveProgress: Double {
        isComplete ? 1 : clampedProgress
    }

    // На чёрном фоне Always-On (`isLuminanceReduced`) обычная дорожка почти
    // не видна и анимация не идёт — приглушаем дугу и отключаем анимацию,
    // как на самих часах в этом режиме.
    private var effectiveStroke: Color {
        isLuminanceReduced ? stroke.opacity(0.75) : stroke
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(effectiveStroke.opacity(trackOpacity), lineWidth: lineWidth)

            if todayHint > 0 {
                Circle()
                    .trim(from: effectiveProgress, to: min(1, effectiveProgress + todayHint))
                    .stroke(effectiveStroke.opacity(0.28),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            Circle()
                .trim(from: 0, to: effectiveProgress)
                .stroke(effectiveStroke, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            label()
        }
        .frame(width: diameter, height: diameter)
        .animation((reduceMotion || isLuminanceReduced) ? nil : .easeOut(duration: 0.45), value: effectiveProgress)
    }
}

#if DEBUG
struct ProgressRingView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 24) {
            ProgressRingView(progress: 0.3, diameter: 108, lineWidth: 8, stroke: .yellow, todayHint: 1.0 / 40) {
                VStack(spacing: 0) {
                    Text("12").font(.title2.bold())
                    Text("из 40").font(.caption2)
                }
            }
            ProgressRingView(progress: 1, diameter: 108, lineWidth: 8, stroke: .yellow, isComplete: true) {
                Image(systemName: "checkmark")
            }
        }
        .padding()
    }
}
#endif
