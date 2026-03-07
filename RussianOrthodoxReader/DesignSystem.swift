import SwiftUI
import UIKit
import CoreText
import CoreFoundation

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
    let muted = Color(red: 0.43, green: 0.39, blue: 0.33)              // #6E6454
    let accent = Color(red: 0.545, green: 0.412, blue: 0.078)          // #8B6914
    let border = Color(red: 0.929, green: 0.91, blue: 0.878)           // #EDE8E0
    let fastBackground = Color(red: 0.941, green: 0.922, blue: 0.89)   // #F0EBE3
    let fastText = Color(red: 0.47, green: 0.37, blue: 0.18)           // #785E2E
    let todayHighlight = Color(red: 0.961, green: 0.941, blue: 0.902)  // #F5F0E6
}

// MARK: - User Font Size Environment

private struct UserFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 33
}

extension EnvironmentValues {
    var userFontSize: CGFloat {
        get { self[UserFontSizeKey.self] }
        set { self[UserFontSizeKey.self] = newValue }
    }
}

// MARK: - Typography Scale

struct AppTypography {
    let base: CGFloat

    /// Uppercase section labels, tiny badges (~14pt at 33)
    var micro: CGFloat { max(base * 0.42, 12) }
    /// Small annotations, error messages (~16pt at 33)
    var caption: CGFloat { max(base * 0.48, 13) }
    /// Secondary labels, settings text (~18pt at 33)
    var footnote: CGFloat { base * 0.55 }
    /// Book names, dictionary words (~21pt at 33)
    var subheadline: CGFloat { base * 0.65 }
    /// Reading references, emphasized secondary (~25pt at 33)
    var callout: CGFloat { base * 0.76 }
    /// Main readable body text (= base, 33pt default)
    var body: CGFloat { base }
    /// Reader/sub-page titles (~35pt at 33)
    var headline: CGFloat { base * 1.06 }
    /// Page titles (~39pt at 33)
    var title: CGFloat { base * 1.18 }
}

// MARK: - Layout

enum AppLayout {
    static let horizontalPaddingPortrait: CGFloat = 32
    static let horizontalPaddingLandscape: CGFloat = 24
    static let verticalPaddingLandscape: CGFloat = 12

    static func horizontalInset(isLandscape: Bool) -> CGFloat {
        isLandscape ? horizontalPaddingLandscape : horizontalPaddingPortrait
    }
}

// MARK: - Typography

struct AppFont {
    private static let cormorantVariable = "CormorantGaramond-VariableFont_wght"
    private static let cormorantItalicVariable = "CormorantGaramond-Italic-VariableFont_wght"

    // Family name used by UIFontDescriptor for variable font lookup
    private static let cormorantFamily = "Cormorant Garamond"

    // Cached font registration status — computed once, never changes at runtime
    private static let isCormorantVariableRegistered: Bool = {
        guard let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] else { return false }
        return names.contains(cormorantVariable)
    }()
    private static let isCormorantItalicVariableRegistered: Bool = {
        guard let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] else { return false }
        return names.contains(cormorantItalicVariable)
    }()

    // Cached family — set once at init, updated only via setFamily()
    private static var _cachedFamily: AppFontFamily = .cormorant

    // Track if fonts have been registered to avoid duplicates
    private static var fontsRegistered = false

    static func setFamily(_ family: AppFontFamily) {
        _cachedFamily = family
    }

    // Call this once at app launch (e.g., in AppDelegate or @main) to register fonts
    static func registerFonts() {
        guard !fontsRegistered else { return }  // Prevent multiple registrations
        fontsRegistered = true

        // List of font files in the app bundle (adjust filenames as needed)
        let fontNames = [
            "CormorantGaramond-VariableFont_wght.ttf",  // Variable weight
            "CormorantGaramond-Italic-VariableFont_wght.ttf"  // Variable italic
        ]

        for fontName in fontNames {
            guard let fontURL = Bundle.main.url(forResource: fontName, withExtension: nil) else {
                print("Font \(fontName) not found in bundle")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) {
                if let cfError = error?.takeRetainedValue() {
                    if CFErrorGetDomain(cfError) == kCTFontManagerErrorDomain && CFErrorGetCode(cfError) == 103 {
                        // Already registered, no action needed
                    } else {
                        print("Failed to register font \(fontName): \(CFErrorCopyDescription(cfError) as String)")
                    }
                } else {
                    print("Failed to register font \(fontName): unknown error")
                }
            }
        }
    }

    static func regular(_ size: CGFloat) -> Font {
        font(size: size, weight: .regular)
    }

    static func medium(_ size: CGFloat) -> Font {
        font(size: size, weight: .medium)
    }

    static func semiBold(_ size: CGFloat) -> Font {
        font(size: size, weight: .semibold)
    }

    static func bold(_ size: CGFloat) -> Font {
        font(size: size, weight: .bold)
    }

    static func italic(_ size: CGFloat) -> Font {
        switch _cachedFamily {
        case .cormorant:
            return .custom(cormorantItalicVariable, size: size)
        case .serif:
            return .system(size: size, weight: .regular, design: .serif).italic()
        case .system:
            return .system(size: size, weight: .regular, design: .default).italic()
        }
    }

    // MARK: - UIFont (for UIKit-bridged views like SelectableTextView)

    /// Creates a UIFont matching the current font family and weight.
    static func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        switch _cachedFamily {
        case .cormorant:
            return cormorantUIFont(size: size, weight: weight)
        case .serif:
            let w = uiFontWeight(for: weight)
            if let desc = UIFont.systemFont(ofSize: size, weight: w)
                .fontDescriptor.withDesign(.serif) {
                return UIFont(descriptor: desc, size: size)
            }
            return UIFont.systemFont(ofSize: size, weight: w)
        case .system:
            return UIFont.systemFont(ofSize: size, weight: uiFontWeight(for: weight))
        }
    }

    private static func uiFontWeight(for weight: Font.Weight) -> UIFont.Weight {
        if weight == .bold { return .bold }
        if weight == .semibold { return .semibold }
        if weight == .medium { return .medium }
        if weight == .light { return .light }
        return .regular
    }

    private static func cormorantUIFont(size: CGFloat, weight: Font.Weight) -> UIFont {
        let variationKey = UIFontDescriptor.AttributeName(
            rawValue: kCTFontVariationAttribute as String
        )
        // Use family name instead of PostScript name for reliable variable font lookup.
        let baseDescriptor = UIFontDescriptor(fontAttributes: [
            .family: cormorantFamily,
            variationKey: [wghtAxisTag: wghtValue(for: weight)]
        ])
        let italicTraits = UIFontDescriptor.SymbolicTraits.traitItalic
        let italicDescriptor = baseDescriptor.withSymbolicTraits(italicTraits) ?? baseDescriptor
        return UIFont(descriptor: italicDescriptor, size: size)
    }

    // MARK: - Variable Font Helpers

    /// OpenType 'wght' axis tag (FourCharCode for 'wght')
    private static let wghtAxisTag = 0x77676874

    /// Maps SwiftUI Font.Weight to OpenType `wght` axis values.
    /// Cormorant Garamond variable font supports 300–700.
    private static func wghtValue(for weight: Font.Weight) -> CGFloat {
        if weight == .bold { return 700 }
        if weight == .semibold { return 600 }
        if weight == .medium { return 500 }
        if weight == .light { return 300 }
        return 400 // .regular and any unknown
    }

    /// Creates a Cormorant Garamond font by setting the `wght` variation axis directly
    /// on the font descriptor, avoiding SwiftUI's `.weight()` modifier which cannot
    /// update the weight on variable fonts registered via UIAppFonts.
    private static func cormorantFont(size: CGFloat, weight: Font.Weight) -> Font {
        let variationKey = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: cormorantItalicVariable,
            variationKey: [wghtAxisTag: wghtValue(for: weight)]
        ])
        let italicTraits = UIFontDescriptor.SymbolicTraits.traitItalic
        let italicDescriptor = descriptor.withSymbolicTraits(italicTraits) ?? descriptor
        return Font(UIFont(descriptor: italicDescriptor, size: size))
    }

    private static func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch _cachedFamily {
        case .cormorant:
            return cormorantFont(size: size, weight: weight)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .system:
            return .system(size: size, weight: weight, design: .default)
        }
    }
}

// MARK: - Reusable View Modifiers

struct CardStyle: ViewModifier {
    private let theme = OrthodoxColors.fallback

    func body(content: Content) -> some View {
        content
            .background(theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

struct SectionHeader: ViewModifier {
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    func body(content: Content) -> some View {
        let typ = AppTypography(base: userFontSize)
        content
            .font(AppFont.regular(typ.micro))
            .foregroundColor(theme.text.opacity(0.75))
            .textCase(.uppercase)
            .tracking(1)
    }
}

// MARK: - Adaptive Top Padding
// Uses less space in landscape (compact vertical) to maximise reading area.

struct AdaptiveTopPadding: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let portrait: CGFloat

    func body(content: Content) -> some View {
        content.padding(.top, verticalSizeClass == .compact ? 16 : portrait)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }

    func sectionHeader() -> some View {
        modifier(SectionHeader())
    }

    /// Adds top padding that shrinks in landscape to avoid wasting screen space.
    func adaptiveTopPadding(_ portrait: CGFloat = 60) -> some View {
        modifier(AdaptiveTopPadding(portrait: portrait))
    }
}

