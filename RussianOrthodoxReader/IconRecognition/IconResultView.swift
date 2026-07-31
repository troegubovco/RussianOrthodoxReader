#if os(iOS)
import SwiftUI
import UIKit

/// Shows the outcome of `IconRecognizer.recognize` — subject name + confidence,
/// then «Житие», «История иконы» and «Молитвы» pulled from `IconMetaRepository`.
struct IconResultView: View {
    let image: UIImage?
    let result: IconRecognitionResult
    /// Called when the user wants to retry (from the `.unknown` state).
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    private var typ: AppTypography { AppTypography.iconScreen(userFontSize: userFontSize) }

    var body: some View {
        NavigationStack {
            root
                .navigationDestination(for: IconMatch.self) { match in
                    IconSubjectDetailView(userImage: image, match: match, showsMatchPercent: false)
                        .navigationTitle("Результат")
                }
                .navigationTitle("Результат")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                            .font(AppFont.regular(17))
                            .foregroundColor(theme.accent)
                            .buttonStyle(.plain)
                    }
                }
        }
    }

    // MARK: - Root content per state

    @ViewBuilder
    private var root: some View {
        switch result {
        case let .recognized(match, alternatives):
            IconSubjectDetailView(
                userImage: image,
                match: match,
                showsMatchPercent: true,
                alternatives: alternatives,
                showsAttribution: true
            )
            .background(theme.background.ignoresSafeArea())
        case .suggestions(let matches):
            suggestionsScreen(matches)
        case .unknown:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    unknownState
                    IconAttributionLine()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(theme.background.ignoresSafeArea())
        }
    }

    // MARK: - Suggestions state

    private func suggestionsScreen(_ matches: [IconMatch]) -> some View {
        VStack(spacing: 0) {
            if let image {
                VStack(spacing: 6) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text("Ваше фото")
                        .font(AppFont.regular(typ.micro))
                        .foregroundColor(theme.muted)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Возможно, это:")
                        .font(AppFont.medium(typ.title))
                        .foregroundColor(theme.text)

                    VStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                            if index > 0 {
                                Divider().background(theme.border)
                            }
                            NavigationLink(value: match) {
                                suggestionRow(match)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .cardStyle()

                    IconAttributionLine()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .background(theme.background.ignoresSafeArea())
    }

    private func suggestionRow(_ match: IconMatch) -> some View {
        HStack(spacing: 12) {
            IconThumbnailView(iconId: match.iconId)
                .frame(width: 54, height: 70)
            VStack(alignment: .leading, spacing: 6) {
                Text(match.name)
                    .font(AppFont.medium(typ.subheadline))
                    .foregroundColor(theme.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                SimilarityMeter(score: match.score)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.muted)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - Unknown state

    private var unknownState: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.diamond")
                .font(.system(size: 44))
                .foregroundColor(theme.muted.opacity(0.5))
                .padding(.top, 24)

            Text("Не удалось распознать. Попробуйте снять без бликов, ровно и ближе.")
                .font(AppFont.regular(typ.subheadline))
                .foregroundColor(theme.text)
                .multilineTextAlignment(.center)

            Button {
                onRetry()
                dismiss()
            } label: {
                Text("Попробовать снова")
                    .font(AppFont.medium(typ.subheadline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .background(theme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Attribution (shared with IconSubjectDetailView's root usage)

struct IconAttributionLine: View {
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography.iconScreen(userFontSize: userFontSize) }

    var body: some View {
        Text("Тексты: azbyka.ru · Каталог икон: pravicon.com")
            .font(AppFont.regular(typ.caption))
            .foregroundColor(theme.muted.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }
}

// MARK: - Similarity meter (suggestions screen — cosine, not a probability)

/// 3-segment meter replacing a raw percentage on the suggestions screen —
/// the score there is cosine similarity, not a softmax probability.
struct SimilarityMeter: View {
    let score: Float

    private let theme = OrthodoxColors.fallback

    private var filled: Int {
        score >= 0.65 ? 3 : (score >= 0.55 ? 2 : 1)
    }

    private var levelLabel: String {
        ["низкая", "средняя", "высокая"][filled - 1]
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(index < filled ? theme.accent : theme.border)
                    .frame(width: 22, height: 5)
            }
        }
        .accessibilityLabel("Схожесть: \(levelLabel)")
    }
}

#Preview {
    IconResultView(
        image: nil,
        result: .unknown,
        onRetry: {}
    )
}
#endif
