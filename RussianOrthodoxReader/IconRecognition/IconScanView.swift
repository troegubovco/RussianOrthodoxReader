// Camera-based icon recognition is an iOS-only feature (relies on UIImage /
// AVFoundation). See IconRecognizer.swift for the same gating.
#if os(iOS)
import SwiftUI
import PhotosUI
import UIKit
import Photos
import AVFoundation

/// «Распознать икону» — capture or pick a photo, run it through `IconRecognizer`,
/// then show `IconResultView`. Fully offline; degrades gracefully while the
/// Core ML artifacts (see `Tools/icon_ml/PLAN.md`) aren't bundled yet.
struct IconScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.userFontSize) private var userFontSize
    @EnvironmentObject private var appState: AppState
    private let theme = OrthodoxColors.fallback

    @State private var showCamera = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var capturedImage: UIImage?
    @State private var isProcessing = false
    @State private var result: IconRecognitionResult?
    @State private var showCrop = false
    /// Снимок, который не распознался и ушёл на экран обрезки.
    @State private var cropSource: UIImage?
    @State private var pendingCroppedImage: UIImage?
    /// Обрезка предлагается один раз на фото: не узнали и по обрезке — обычный
    /// экран «не найдено», без третьего круга.
    @State private var hasCropRetried = false

    private var typ: AppTypography { AppTypography.iconScreen(userFontSize: userFontSize) }

    private var isCameraAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    private var isModelAvailable: Bool {
        IconRecognizer.shared != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let image = capturedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(.top, 16)
                    }

                    if isProcessing {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Распознаём икону…")
                                .font(AppFont.regular(typ.footnote))
                                .foregroundColor(theme.muted)
                        }
                        .padding(.top, 32)
                    } else {
                        introContent
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Распознать икону")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { dismiss() }
                        .font(AppFont.regular(17))
                        .foregroundColor(theme.accent)
                        .buttonStyle(.plain)
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                showCamera = false
                if let image {
                    handleNewImage(image.downscaled(maxDimension: 1600))
                    if appState.saveIconPhotosToLibrary {
                        saveToPhotoLibrary(image)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photosPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handleNewImage(image.downscaled(maxDimension: 1600))
                }
                photosPickerItem = nil
            }
        }
        .fullScreenCover(item: resultBinding) { wrapped in
            IconResultView(
                image: capturedImage,
                result: wrapped.result,
                onRetry: {
                    // "Попробовать снова" from the .unknown state
                    capturedImage = nil
                    result = nil
                    cropSource = nil
                    hasCropRetried = false
                }
            )
        }
        .fullScreenCover(isPresented: $showCrop, onDismiss: recognizeCroppedIfPending) {
            if let cropSource {
                IconCropView(image: cropSource) {
                    // Отмена: возвращаемся на экран сканирования со своим фото.
                    showCrop = false
                } onConfirm: { cropped in
                    pendingCroppedImage = cropped
                    showCrop = false
                }
            }
        }
    }

    // MARK: - Смена fullScreenCover'ов
    //
    // B6: две обложки нельзя переключать в одном витке runloop — вторая молча
    // не показывается. Поэтому переход всегда идёт через onDismiss первой
    // (он вызывается уже после её закрытия) плюс ещё один async-виток.

    private func recognizeCroppedIfPending() {
        guard let cropped = pendingCroppedImage else { return }
        pendingCroppedImage = nil
        DispatchQueue.main.async {
            handleNewImage(cropped, isCropRetry: true)
        }
    }

    // MARK: - Intro state

    @ViewBuilder
    private var introContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundColor(theme.accent.opacity(0.5))
                .padding(.top, 24)

            Text("Наведите камеру на икону или выберите фото из галереи, чтобы узнать, кто на ней изображён, прочитать житие, историю иконы и молитвы.")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            if !isModelAvailable {
                Text("Модель распознавания появится в одном из ближайших обновлений.")
                    .font(AppFont.regular(typ.caption))
                    .foregroundColor(theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            VStack(spacing: 12) {
                Button {
                    showCamera = true
                } label: {
                    Label("Сделать снимок", systemImage: "camera")
                        .font(AppFont.medium(typ.subheadline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(isCameraAvailable && isModelAvailable ? theme.accent : theme.muted.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(!isCameraAvailable || !isModelAvailable)

                if !isCameraAvailable {
                    Text("Камера недоступна в этом окружении")
                        .font(AppFont.regular(typ.caption))
                        .foregroundColor(theme.muted)
                }

                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    Label("Выбрать из галереи", systemImage: "photo.on.rectangle")
                        .font(AppFont.medium(typ.subheadline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.text)
                .background(theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(!isModelAvailable)
                .opacity(isModelAvailable ? 1 : 0.5)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Photo library

    /// Saves a camera-captured photo to the user's photo library. Fire-and-forget:
    /// never blocks the UI, errors are logged and otherwise ignored. Only called
    /// for photos taken with the in-app camera — gallery picks are never re-saved.
    private func saveToPhotoLibrary(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                if !success {
                    #if DEBUG
                    print("IconScanView: failed to save photo to library: \(String(describing: error))")
                    #endif
                }
            }
        }
    }

    // MARK: - Recognition

    private func handleNewImage(_ image: UIImage, isCropRetry: Bool = false) {
        capturedImage = image
        hasCropRetried = isCropRetry
        guard let recognizer = IconRecognizer.shared else {
            // B6: assigning `result` in the same runloop turn as `showCamera = false`
            // (still settling from the fullScreenCover dismissal) can make the second
            // fullScreenCover(item:) silently fail to present. Defer to the next runloop turn.
            DispatchQueue.main.async {
                result = .unknown
            }
            return
        }
        isProcessing = true
        recognizer.recognize(image) { recognitionResult in
            DispatchQueue.main.async {
                isProcessing = false
                if case .unknown = recognitionResult, !hasCropRetried {
                    // Первая неудача — вместо тупика сразу экран обрезки:
                    // повторный прогон по обрезанному кадру часто срабатывает.
                    cropSource = image
                    showCrop = true
                } else {
                    result = recognitionResult
                }
            }
        }
    }

    /// Wraps `result` so `.fullScreenCover(item:)` can present it (nil dismisses).
    private struct ResultWrapper: Identifiable {
        let id = UUID()
        let result: IconRecognitionResult
    }

    private var resultBinding: Binding<ResultWrapper?> {
        Binding(
            get: { result.map(ResultWrapper.init) },
            set: { newValue in
                if newValue == nil {
                    result = nil
                    capturedImage = nil
                }
            }
        )
    }
}

// MARK: - Camera capture (UIImagePickerController wrapper)

/// Штатная системная камера (со всеми привычными элементами управления) плюс
/// ненавязчивая рамка-подсказка: квадрат соответствует центральному кропу,
/// который видит классификатор.
private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator

        let overlay = FramingGuideOverlay(frame: picker.view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        picker.cameraOverlayView = overlay

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage?) -> Void

        init(onCapture: @escaping (UIImage?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}

/// Прозрачный слой поверх видоискателя, пропускающий все касания к штатным
/// элементам управления камеры.
private final class FramingGuideOverlay: UIView {
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shape.fillColor = UIColor.clear.cgColor
        shape.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        shape.lineWidth = 2
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Видоискатель 4:3 занимает верхнюю часть экрана; нижняя полоса — панель
        // управления камеры, поэтому центр рамки смещён выше середины.
        let side = min(bounds.width, bounds.height) * 0.82
        let center = CGPoint(x: bounds.midX, y: bounds.midY - 60)
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        shape.frame = bounds
        shape.path = UIBezierPath(roundedRect: rect, cornerRadius: 16).cgPath
    }
}

extension UIImage {
    /// Returns a copy whose longest edge is at most `maxDimension`, preserving
    /// aspect ratio. Returns `self` unchanged if already within bounds.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longestEdge = max(size.width, size.height)
        guard longestEdge > maxDimension, longestEdge > 0 else { return self }

        let scale = maxDimension / longestEdge
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

#Preview {
    IconScanView()
        .environmentObject(AppState())
}
#endif
