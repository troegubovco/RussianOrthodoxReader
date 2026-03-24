import SwiftUI

struct PrayerOverlay: View {
    let onComplete: () -> Void
    @State private var appeared = false
    
    private let theme = OrthodoxTheme.shared
    
    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {} // Block taps through
            
            VStack(spacing: 24) {
                Spacer()
                
                VStack(spacing: 20) {
                    // Cross
                    Text("☦")
                        .font(.system(size: 36))
                        .foregroundColor(theme.accent)
                    
                    // Title
                    Text("Молитва перед чтением")
                        .font(.custom("CormorantGaramond-SemiBold", size: 20))
                        .foregroundColor(theme.text)
                    
                    // Prayer text
                    Text("""
                    Господи Иисусе Христе, отверзи ми уши сердечныя, \
                    услышати Слово Твоё и разумети и творити волю Твою, \
                    яко пришлец есмь на земли, не скрый от мене заповедей Твоих, \
                    но открый очи мои, да уразумею чудеса от закона Твоего. \
                    Скажи мне безвестная и тайная премудрости Твоея! \
                    На Тя уповаю, Боже мой, да ми просветиши ум и смысл \
                    светом разума Твоего, не точию чести написанная, \
                    но и творити я. Да не в грех себе святых жития \
                    и словеса прочитаю, но в обновление и просвещение, \
                    и в святыню, и во спасение души, и в наследие жизни вечныя. \
                    Яко Ты еси просвещаяй лежащих во тьме \
                    и от Тебе есть всякое даяние благо и всяк дар совершен.
                    """)
                    .font(.custom("CormorantGaramond-Regular", size: 15))
                    .foregroundColor(theme.text)
                    .lineSpacing(6)
                    .multilineTextAlignment(.center)
                    
                    // Amen button
                    Button(action: onComplete) {
                        Text("Аминь")
                            .font(.custom("CormorantGaramond-SemiBold", size: 18))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .accessibilityLabel("Аминь. Нажмите, чтобы перейти к чтению Писания")
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white)
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
