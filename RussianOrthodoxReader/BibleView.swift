import SwiftUI

struct BibleView: View {
    let onSelectChapter: (String) -> Void
    
    @State private var selectedTestament: Testament = .new
    let theme = OrthodoxColorsFallback()
    
    private var books: [BibleBook] {
        BibleDataProvider.books(for: selectedTestament)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                Text("Библия")
                    .font(AppFont.medium(28))
                    .foregroundColor(theme.text)
                    .padding(.top, 60)
                
                // Testament picker
                TestamentPicker(selected: $selectedTestament)
                
                // Book list
                VStack(spacing: 2) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        let hasData = BibleDataProvider.hasChapter(bookId: book.id)
                        
                        Button {
                            if let key = BibleDataProvider.firstAvailableChapter(bookId: book.id) {
                                onSelectChapter(key)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Text(book.abbreviation)
                                    .font(AppFont.semiBold(13))
                                    .foregroundColor(theme.accent)
                                    .frame(width: 44, alignment: .center)
                                
                                Text(book.name)
                                    .font(AppFont.regular(17))
                                    .foregroundColor(theme.text)
                                
                                Spacer()
                                
                                if hasData {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(theme.muted)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(theme.card)
                            .clipShape(
                                bookRowShape(index: index, total: books.count)
                            )
                            .opacity(hasData ? 1 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasData)
                        .accessibilityLabel(book.name)
                        .accessibilityHint(hasData ? "Нажмите, чтобы открыть" : "Пока недоступно")
                    }
                }
                
                // Note
                Text("Демо: доступны Мф 5, Ин 1, Пс 50")
                    .font(AppFont.regular(13))
                    .foregroundColor(theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 120)
        }
    }
    
    private func bookRowShape(index: Int, total: Int) -> some Shape {
        let topRadius: CGFloat = index == 0 ? 14 : 2
        let bottomRadius: CGFloat = index == total - 1 ? 14 : 2
        return UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
    }
}

// MARK: - Testament Picker

struct TestamentPicker: View {
    @Binding var selected: Testament
    let theme = OrthodoxColorsFallback()
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Testament.allCases) { testament in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = testament
                    }
                } label: {
                    Text(testament.rawValue)
                        .font(AppFont.regular(15))
                        .foregroundColor(selected == testament ? .white : theme.muted)
                        .fontWeight(selected == testament ? .semibold : .regular)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected == testament ? theme.accent : Color.clear)
                        )
                }
                .accessibilityLabel(testament.rawValue)
                .accessibilityAddTraits(selected == testament ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.card)
        )
    }
}

#Preview {
    BibleView(onSelectChapter: { _ in })
        .environmentObject(AppState())
}
