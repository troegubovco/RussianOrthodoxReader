import SwiftUI

/// A non-editable text view that allows native word selection.
/// When the user selects text, a "Словарь" option appears in the context menu
/// that triggers the `onWordSelected` callback.

#if os(iOS)
import UIKit

struct SelectableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let backgroundColor: PlatformColor
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

#elseif os(macOS)
import AppKit

struct SelectableTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    let backgroundColor: PlatformColor
    var onWordSelected: ((String) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        let textView = DictionaryTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributedText)
        textView.onWordSelected = onWordSelected

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? DictionaryTextView else { return }
        textView.textStorage?.setAttributedString(attributedText)
        textView.backgroundColor = backgroundColor
        textView.onWordSelected = onWordSelected
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let width = proposal.width, width > 0,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let rect = layoutManager.usedRect(for: textContainer)
        return CGSize(width: width, height: rect.height)
    }
}

class DictionaryTextView: NSTextView {
    var onWordSelected: ((String) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()

        let selectedRange = self.selectedRange()
        if selectedRange.length > 0,
           let text = self.string as NSString? {
            let selected = text.substring(with: selectedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty {
                let item = NSMenuItem(
                    title: "Словарь",
                    action: #selector(lookupWord(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = selected
                item.target = self
                menu.insertItem(item, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
        }
        return menu
    }

    @objc private func lookupWord(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        onWordSelected?(word)
    }
}

#endif

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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
