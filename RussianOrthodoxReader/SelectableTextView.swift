import SwiftUI
import UIKit

/// A non-editable text view that allows native word selection.
/// When the user selects text, a "Словарь" option appears in the context menu
/// that triggers the `onWordSelected` callback.
struct SelectableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let backgroundColor: UIColor
    var onWordSelected: ((String) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = backgroundColor
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.delegate = context.coordinator
        tv.attributedText = attributedText
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText
        uiView.backgroundColor = backgroundColor
        context.coordinator.onWordSelected = onWordSelected
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onWordSelected: onWordSelected)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UITextViewDelegate {
        var onWordSelected: ((String) -> Void)?

        init(onWordSelected: ((String) -> Void)?) {
            self.onWordSelected = onWordSelected
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            var actions = suggestedActions

            if range.length > 0, let text = textView.text {
                let selected = (text as NSString)
                    .substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !selected.isEmpty {
                    let lookupAction = UIAction(
                        title: "Словарь",
                        image: UIImage(systemName: "character.book.closed")
                    ) { [weak self] _ in
                        self?.onWordSelected?(selected)
                    }
                    actions.insert(lookupAction, at: 0)
                }
            }

            return UIMenu(children: actions)
        }
    }
}

// MARK: - Word Definition Sheet

/// A half-sheet that shows dictionary results for a selected word.
struct WordDefinitionSheet: View {
    let word: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @State private var results: [DictionaryEntry] = []

    private let dictionary = DictionaryRepository.shared
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    noResultsView
                } else {
                    resultsList
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle(word)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { dismiss() }
                        .font(AppFont.regular(17))
                        .foregroundColor(theme.accent)
                }
            }
        }
        .onAppear {
            results = dictionary.search(query: word)
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 48))
                .foregroundColor(theme.muted.opacity(0.5))

            Text("Слово не найдено")
                .font(AppFont.medium(typ.subheadline))
                .foregroundColor(theme.text)

            Text("«\(word)» не найдено в словаре.\nПопробуйте другую форму слова.")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var resultsList: some View {
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
