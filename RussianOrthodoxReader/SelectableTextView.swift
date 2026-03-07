import SwiftUI
import UIKit

struct SelectableTextView: UIViewRepresentable {
    let text: String
    let font: Font
    let textColor: Color
    let backgroundColor: Color
    
    @Environment(\.userFontSize) private var userFontSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) private var presentationMode // For dismissal if needed
    
    private let dictionary = DictionaryRepository.shared
    private let theme = OrthodoxColors.fallback
    private let typ: AppTypography
    
    init(text: String, font: Font, textColor: Color, backgroundColor: Color) {
        self.text = text
        self.font = font
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.typ = AppTypography(base: userFontSize)
    }
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.text = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = UIColor(backgroundColor)
        textView.textColor = UIColor(textColor)
        textView.font = mapSwiftUIFontToUIFont(font)
        textView.delegate = context.coordinator
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false // Assume text fits; enable if needed
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
        uiView.font = mapSwiftUIFontToUIFont(font)
        uiView.textColor = UIColor(textColor)
        uiView.backgroundColor = UIColor(backgroundColor)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    private func mapSwiftUIFontToUIFont(_ font: Font) -> UIFont {
        // Map SwiftUI Font to UIFont; adjust for your AppFont logic
        switch font {
        case .system(let size, design: let design, weight: let weight):
            let uiWeight: UIFont.Weight
            switch weight {
            case .regular: uiWeight = .regular
            case .medium: uiWeight = .medium
            case .semibold: uiWeight = .semibold
            case .bold: uiWeight = .bold
            default: uiWeight = .regular
            }
            return UIFont.systemFont(ofSize: size, weight: uiWeight)
        default:
            // For custom fonts like AppFont, use a fallback or extract size
            return UIFont.systemFont(ofSize: typ.body)
        }
    }
    
    class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextView
        var searchTask: Task<Void, Never>?
        
        init(parent: SelectableTextView) {
            self.parent = parent
        }
        
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let selectedRange = textView.selectedTextRange,
                  let selectedText = textView.text(in: selectedRange),
                  !selectedText.isEmpty else { return }
            
            // Extract the word at the selection
            let fullText = textView.text ?? ""
            let nsRange = selectedRange.toTextRange(textInput: textView) as! NSRange
            let wordRange = (fullText as NSString).rangeOfComposedCharacterSequence(at: nsRange.location)
            let word = (fullText as NSString).substring(with: wordRange).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !word.isEmpty {
                performLookup(for: word)
            }
        }
        
        private func performLookup(for word: String) {
            searchTask?.cancel()
            searchTask = Task {
                // Debounce: wait 300ms before searching
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                
                let results = parent.dictionary.search(query: word)
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    presentDefinition(results: results, query: word)
                }
            }
        }
        
        @MainActor
        private func presentDefinition(results: [DictionaryEntry], query: String) {
            // Find the root view controller to present the popover/sheet
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first?.rootViewController else { return }
            
            let definitionVC = UIHostingController(rootView: DefinitionPopoverView(results: results, query: query))
            definitionVC.modalPresentationStyle = .popover
            definitionVC.preferredContentSize = CGSize(width: 300, height: 400)
            
            if let popover = definitionVC.popoverPresentationController {
                popover.sourceView = rootVC.view
                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            
            rootVC.present(definitionVC, animated: true)
        }
    }
}

// Simplified popover view for definitions
struct DefinitionPopoverView: View {
    let results: [DictionaryEntry]
    let query: String
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if results.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 48))
                            .foregroundColor(theme.muted.opacity(0.5))
                        Text("Слово не найдено")
                            .font(AppFont.medium(typ.subheadline))
                            .foregroundColor(theme.text)
                        Text("«\(query)» не найдено в словаре.\nПопробуйте другую форму слова.")
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(results) { entry in
                                DictionaryEntryRow(entry: entry)
                            }
                        }
                        .padding(.horizontal, AppLayout.horizontalInset(isLandscape: false))
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(theme.card.ignoresSafeArea())
            .navigationTitle("Определение: \(query)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                    .font(AppFont.regular(17))
                    .foregroundColor(theme.accent)
                }
            }
        }
    }
}
