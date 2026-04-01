import PhotosUI
import SwiftUI

#if canImport(UIKit) && !os(macOS)
import UIKit
#endif

struct IdentifyView: View {
    @Environment(\.userFontSize) private var userFontSize
    @StateObject private var viewModel = IconIdentificationViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedMatch: IconMatch?
    #if canImport(UIKit) && !os(macOS)
    @State private var showCamera = false
    #endif

    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection(isLandscape: isLandscape)
                    actionSection

                    if let previewImage = viewModel.previewImage {
                        previewSection(image: previewImage)
                    }

                    if viewModel.isPreparing && viewModel.previewImage == nil {
                        statusCard(
                            title: "Подготовка индекса",
                            message: "Загружаем офлайн-базу и визуальные признаки икон для быстрого поиска."
                        )
                    }

                    if viewModel.isAnalyzing {
                        statusCard(
                            title: "Анализируем изображение",
                            message: "Сравниваем вашу фотографию с базой икон на устройстве."
                        )
                    }

                    if let errorMessage = viewModel.errorMessage {
                        messageCard(
                            title: "Нужны assets распознавания",
                            message: errorMessage
                        )
                    }

                    if !viewModel.matches.isEmpty {
                        resultsSection
                    } else if !viewModel.isAnalyzing, viewModel.previewImage == nil, viewModel.errorMessage == nil {
                        emptyStateCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableContentWidth()
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: isLandscape))
                .padding(.vertical, isLandscape ? AppLayout.verticalPaddingLandscape : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.background.ignoresSafeArea())
        .task {
            await viewModel.prepareIfNeeded()
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            Task {
                do {
                    guard let newValue,
                          let data = try await newValue.loadTransferable(type: Data.self) else {
                        selectedPhotoItem = nil
                        return
                    }
                    await viewModel.identify(imageData: data)
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
                selectedPhotoItem = nil
            }
        }
        .sheet(item: $selectedMatch) { match in
            IconMatchDetailSheet(match: match)
        }
        #if canImport(UIKit) && !os(macOS)
        .sheet(isPresented: $showCamera) {
            CameraCaptureView { image in
                Task {
                    await viewModel.identify(image: image)
                }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder
    private func headerSection(isLandscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Иконы")
                .sectionHeader()

            Text("Распознавание икон")
                .font(AppFont.medium(typ.title))
                .foregroundColor(theme.text)

            Text("Сфотографируйте икону или выберите изображение. Приложение найдет наиболее похожие варианты из локальной базы.")
                .font(AppFont.regular(isLandscape ? typ.footnote : typ.callout))
                .foregroundColor(theme.muted)
                .lineSpacing(4)
        }
        .padding(.top, isLandscape ? 12 : 8)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Источник")
                .sectionHeader()

            VStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    actionButtonLabel(
                        title: "Выбрать фото",
                        subtitle: "Открыть изображение из медиатеки",
                        systemImage: "photo.on.rectangle.angled"
                    )
                }
                .buttonStyle(.plain)

                #if canImport(UIKit) && !os(macOS)
                Button {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        viewModel.errorMessage = "Камера недоступна на этом устройстве."
                        return
                    }
                    showCamera = true
                } label: {
                    actionButtonLabel(
                        title: "Снять фото",
                        subtitle: "Сфотографировать икону прямо сейчас",
                        systemImage: "camera.viewfinder"
                    )
                }
                .buttonStyle(.plain)
                #endif
            }
        }
        .padding(24)
        .cardStyle()
    }

    private func previewSection(image: PlatformImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ваше изображение")
                    .sectionHeader()

                Spacer()

                Button("Очистить") {
                    viewModel.clearResults()
                }
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.accent)
                .buttonStyle(.plain)
            }

            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(24)
        .cardStyle()
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Лучшие совпадения")
                .sectionHeader()

            if let firstMatch = viewModel.matches.first {
                resultsSummary(for: firstMatch)
            }

            ForEach(viewModel.matches) { match in
                Button {
                    selectedMatch = match
                } label: {
                    IconMatchCard(match: match)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func resultsSummary(for match: IconMatch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Сходство \(match.similarityScore.formattedPercent)")
                    .font(AppFont.semiBold(typ.caption))
                    .foregroundColor(theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.accent.opacity(0.12))
                    .clipShape(Capsule())

                if let classifierCategory = match.classifierCategory,
                   let confidence = match.classifierConfidence {
                    Text("Класс: \(classifierCategory.title) \(confidence.formattedPercent)")
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.muted)
                }
            }

            Text(match.similarityScore < 0.5
                 ? "Результат выглядит неуверенным. Лучше воспринимать его как подсказку и просмотреть несколько вариантов."
                 : "Показываем наиболее похожие иконы, а не окончательный вердикт. При необходимости откройте карточку и сверяйте житие и праздники.")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .lineSpacing(3)
        }
        .padding(20)
        .cardStyle()
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Как это работает")
                .sectionHeader()

            Text("Мы сравниваем визуальные признаки снимка с локальной базой из тысяч икон и показываем наиболее похожие совпадения.")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.text)
                .lineSpacing(4)

            Text("Результаты особенно полезны, когда лицо святого, композиция или надпись хорошо видны.")
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.muted)
                .lineSpacing(3)
        }
        .padding(24)
        .cardStyle()
    }

    private func actionButtonLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.accent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.medium(typ.subheadline))
                    .foregroundColor(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private func statusCard(title: String, message: String) -> some View {
        HStack(spacing: 14) {
            ProgressView()
                .progressViewStyle(.circular)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppFont.medium(typ.footnote))
                    .foregroundColor(theme.text)

                Text(message)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
                    .lineSpacing(3)
            }
        }
        .padding(20)
        .cardStyle()
    }

    private func messageCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppFont.medium(typ.footnote))
                .foregroundColor(theme.text)

            Text(message)
                .font(AppFont.regular(typ.caption))
                .foregroundColor(theme.muted)
                .lineSpacing(3)
        }
        .padding(20)
        .cardStyle()
    }
}

private struct IconMatchCard: View {
    let match: IconMatch

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconThumbnailView(fileName: match.representativeThumbnailName)
                .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(match.name)
                            .font(AppFont.medium(typ.subheadline))
                            .foregroundColor(theme.text)
                            .multilineTextAlignment(.leading)

                        Text(match.category.title)
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.accent)
                    }

                    Spacer(minLength: 12)

                    Text(match.similarityScore.formattedPercent)
                        .font(AppFont.semiBold(typ.caption))
                        .foregroundColor(theme.accent)
                }

                if !match.feastDays.isEmpty {
                    Text(match.feastDays.joined(separator: ", "))
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.muted)
                        .lineLimit(2)
                }

                Text(match.biography.isEmpty ? "Биография пока не указана." : match.biography)
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.text)
                    .lineLimit(4)

                Text("Открыть карточку")
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.accent)
            }
        }
        .padding(18)
        .cardStyle()
    }
}

private struct IconThumbnailView: View {
    let fileName: String?

    var body: some View {
        if let thumbnail = loadThumbnail() {
            Image(platformImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OrthodoxColors.fallback.todayHighlight)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(OrthodoxColors.fallback.muted)
                }
        }
    }

    private func loadThumbnail() -> PlatformImage? {
        guard let fileName,
              let url = IconAssetLocator.representativeThumbnailURL(fileName: fileName) else {
            return nil
        }

        #if canImport(UIKit)
        return PlatformImage(contentsOfFile: url.path)
        #elseif canImport(AppKit)
        return PlatformImage(contentsOf: url)
        #endif
    }
}

private struct IconMatchDetailSheet: View {
    let match: IconMatch

    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback
    private var typ: AppTypography { AppTypography(base: userFontSize) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    IconThumbnailView(fileName: match.representativeThumbnailName)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(match.name)
                            .font(AppFont.medium(typ.title))
                            .foregroundColor(theme.text)

                        Text(match.category.title)
                            .font(AppFont.regular(typ.callout))
                            .foregroundColor(theme.accent)

                        Text("Сходство: \(match.similarityScore.formattedPercent)")
                            .font(AppFont.regular(typ.caption))
                            .foregroundColor(theme.muted)
                    }
                    .padding(24)
                    .cardStyle()

                    if !match.feastDays.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Праздничные дни")
                                .sectionHeader()

                            Text(match.feastDays.joined(separator: "\n"))
                                .font(AppFont.regular(typ.footnote))
                                .foregroundColor(theme.text)
                                .lineSpacing(4)
                        }
                        .padding(24)
                        .cardStyle()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Описание")
                            .sectionHeader()

                        Text(match.biography.isEmpty ? "Биография пока не указана." : match.biography)
                            .font(AppFont.regular(typ.footnote))
                            .foregroundColor(theme.text)
                            .lineSpacing(4)
                    }
                    .padding(24)
                    .cardStyle()
                }
                .readableContentWidth()
                .padding(.horizontal, AppLayout.horizontalInset(isLandscape: false))
                .padding(.vertical, 16)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Совпадение")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                    .foregroundColor(theme.accent)
                }
            }
        }
    }
}

private extension Double {
    var formattedPercent: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: self)) ?? "\(Int(self * 100))%"
    }
}

#if canImport(UIKit) && !os(macOS)
private struct CameraCaptureView: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }
    }
}
#endif
