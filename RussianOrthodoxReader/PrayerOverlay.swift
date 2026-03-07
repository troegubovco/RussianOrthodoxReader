import SwiftUI

// MARK: - Prayer Data

struct Prayers {
    static let beforeReading = """
    Господи Иисусе Христе, отверзи ми уши сердечныя \
    услышати слово Твое, и разумети и творити волю Твою, \
    яко пришлец есмь на земли: не скрый от мене заповедей \
    Твоих, но открый очи мои, да разумею чудеса от закона \
    Твоего; скажи мне безвестнея и тайная премудрости Твоея. \
    На Тя уповаю, Боже мой, да ми просветиши ум и смысл \
    светом разума Твоего не токмо чести написанная, но и \
    творити я, да не в грех себе святых жития и словесе \
    прочитаю, но в обновление, и просвещение, и в святыню, \
    и в спасение души, и в наследие жизни вечныя. Яко Ты \
    еси просвещаяй лежащих во тьме и от Тебе есть всякое \
    даяние благо и всяк дар совершен. Аминь.
    """
}

// MARK: - Prayer Overlay View

struct PrayerOverlay: View {
    let onComplete: () -> Void

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography(base: userFontSize) }

    @State private var appeared = false

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(appeared ? 0.5 : 0)
                .ignoresSafeArea()
                .onTapGesture { } // Prevent tap-through

            // Prayer card
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 24) {
                    // Cross ornament
                    Text("☦")
                        .font(.system(size: 32))
                        .foregroundColor(theme.accent)

                    Text("Молитва перед чтением\nСвященного Писания")
                        .font(AppFont.semiBold(typ.callout))
                        .foregroundColor(theme.text)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)

                    // Divider
                    Rectangle()
                        .fill(theme.border)
                        .frame(width: 40, height: 1)

                    // Prayer text
                    ScrollView {
                        Text(Prayers.beforeReading)
                            .font(AppFont.regular(typ.body))
                            .foregroundColor(theme.text)
                            .lineSpacing(8)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 4)
                    }
                    .frame(maxHeight: 340)

                    // Amen button
                    Button(action: onComplete) {
                        Text("Аминь")
                            .font(AppFont.semiBold(typ.subheadline))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(theme.accent)
                            )
                    }
                    .accessibilityLabel("Прочитано. Аминь.")
                    .accessibilityHint("Нажмите, чтобы перейти к чтению Писания")
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(theme.card)
                )
                .padding(.horizontal, 20)
                .offset(y: appeared ? 0 : 300)

                Spacer()
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: appeared)
        .onAppear {
            appeared = true
        }
    }
}

#Preview {
    PrayerOverlay(onComplete: {})
}
