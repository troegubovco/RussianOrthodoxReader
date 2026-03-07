import SwiftUI

// MARK: - Color Palette

extension Color {
    static let orthodox = OrthodoxColors()
}

struct OrthodoxColors {
    let background = Color("Background", bundle: nil)
    let card = Color("Card", bundle: nil)
    let text = Color("TextPrimary", bundle: nil)
    let muted = Color("TextMuted", bundle: nil)
    let accent = Color("Accent", bundle: nil)
    let border = Color("Border", bundle: nil)
    let fastBackground = Color("FastBackground", bundle: nil)
    let fastText = Color("FastText", bundle: nil)
    let todayHighlight = Color("TodayHighlight", bundle: nil)
    
    // Fallback initializers when asset catalog isn't set up yet
    static let fallback = OrthodoxColorsFallback()
}

/// Use these directly until you create an Asset Catalog with named colors.
/// Once you add the colors to Assets.xcassets, switch to `Color.orthodox.*`
struct OrthodoxColorsFallback {
    let background = Color(red: 0.98, green: 0.973, blue: 0.961)       // #FAF8F5
    let card = Color.white
    let text = Color(red: 0.173, green: 0.141, blue: 0.094)            // #2C2418
    let muted = Color(red: 0.62, green: 0.58, blue: 0.518)             // #9E9484
    let accent = Color(red: 0.545, green: 0.412, blue: 0.078)          // #8B6914
    let border = Color(red: 0.929, green: 0.91, blue: 0.878)           // #EDE8E0
    let fastBackground = Color(red: 0.941, green: 0.922, blue: 0.89)   // #F0EBE3
    let fastText = Color(red: 0.651, green: 0.545, blue: 0.357)        // #A68B5B
    let todayHighlight = Color(red: 0.961, green: 0.941, blue: 0.902)  // #F5F0E6
}

// MARK: - Typography

struct AppFont {
    /// Cormorant Garamond must be added to the project bundle.
    /// Download from Google Fonts and add to Info.plist under "Fonts provided by application".
    /// Fallback: Georgia (system serif) preserves the feel if Cormorant isn't available.
    
    static func regular(_ size: CGFloat) -> Font {
        .custom("CormorantGaramond-Regular", size: size, relativeTo: .body)
    }
    
    static func medium(_ size: CGFloat) -> Font {
        .custom("CormorantGaramond-Medium", size: size, relativeTo: .body)
    }
    
    static func semiBold(_ size: CGFloat) -> Font {
        .custom("CormorantGaramond-SemiBold", size: size, relativeTo: .body)
    }
    
    static func bold(_ size: CGFloat) -> Font {
        .custom("CormorantGaramond-Bold", size: size, relativeTo: .body)
    }
    
    static func italic(_ size: CGFloat) -> Font {
        .custom("CormorantGaramond-Italic", size: size, relativeTo: .body)
    }
    
    // System serif fallback
    static func fallbackRegular(_ size: CGFloat) -> Font {
        .system(size: size, design: .serif)
    }
}

// MARK: - Reusable View Modifiers

struct CardStyle: ViewModifier {
    let theme = OrthodoxColorsFallback()
    
    func body(content: Content) -> some View {
        content
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

struct SectionHeader: ViewModifier {
    let theme = OrthodoxColorsFallback()
    
    func body(content: Content) -> some View {
        content
            .font(AppFont.regular(13))
            .foregroundColor(theme.muted)
            .textCase(.uppercase)
            .tracking(1)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
    
    func sectionHeader() -> some View {
        modifier(SectionHeader())
    }
}
