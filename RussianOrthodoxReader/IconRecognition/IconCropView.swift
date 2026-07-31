// Ручной кроп — вторая попытка после `.unknown`. Модель обучена на каталожных
// репродукциях, где икона занимает весь кадр; на фото иконы на стене фон
// роняет ранжирование (замерено: ап. Андрей — 43-й на полном кадре, 1-й после
// обрезки по доске). Никогда не является обязательным шагом перед первым
// распознаванием, и второго круга обрезки нет.
#if os(iOS)
import SwiftUI
import UIKit
import Vision

/// Угол рамки кропа. Вынесен из вью, чтобы им пользовалась и ручка `CropCornerHandle`.
private enum CropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

/// Полноэкранный редактор кропа: фото по центру, рамка с затемнением снаружи,
/// четыре угловые ручки, свободные пропорции.
struct IconCropView: View {
    let onCancel: () -> Void
    let onConfirm: (UIImage) -> Void

    /// Копия с orientation == .up и scale == 1 — вся математика кропа ведётся
    /// в пикселях именно этой копии.
    private let source: UIImage
    private let pixelSize: CGSize

    @Environment(\.userFontSize) private var userFontSize
    private let theme = OrthodoxColors.fallback

    /// Кадр отображаемого (scaledToFit) изображения в координатах контейнера.
    @State private var imageFrame: CGRect = .zero
    /// Рамка кропа — тоже в display-координатах; в пиксели переводится на подтверждении.
    @State private var cropRect: CGRect = .zero
    @State private var dragStart: CGRect?
    /// Пока пользователь не тронул рамку, её можно молча заменить на предложенную Vision.
    @State private var userAdjusted = false
    @State private var visionBox: CGRect?
    @State private var visionStarted = false

    private var typ: AppTypography { AppTypography.iconScreen(userFontSize: userFontSize) }

    private let handleTouchSize: CGFloat = 44
    private let minCropSide: CGFloat = 80

    init(image: UIImage, onCancel: @escaping () -> Void, onConfirm: @escaping (UIImage) -> Void) {
        let normalized = image.iconCropNormalized()
        self.source = normalized
        self.pixelSize = normalized.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? normalized.size
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                GeometryReader { geo in
                    let fitted = imageRect(in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: source)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .offset(x: fitted.minX, y: fitted.minY)

                        dimMask(container: geo.size)

                        if cropRect.width > 0 {
                            cropBox
                            cornerHandles
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .onAppear {
                        syncFrame(fitted)
                        startVisionSeed()
                    }
                    .onChange(of: geo.size) { _, newSize in
                        syncFrame(imageRect(in: newSize))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                bottomBar
            }
        }
    }

    // MARK: - Слои рамки

    private func dimMask(container: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: container))
            if cropRect.width > 0 { path.addRect(cropRect) }
        }
        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
        .frame(width: container.width, height: container.height)
        .allowsHitTesting(false)
    }

    private var cropBox: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))    // прозрачная, но кликабельная заливка
            .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 2))
            .frame(width: cropRect.width, height: cropRect.height)
            .offset(x: cropRect.minX, y: cropRect.minY)
            .gesture(moveGesture)
    }

    private var cornerHandles: some View {
        ForEach(CropCorner.allCases, id: \.self) { corner in
            let point = cornerPoint(corner)
            CropCornerHandle(corner: corner, touchSize: handleTouchSize)
                .offset(x: point.x - handleTouchSize / 2, y: point.y - handleTouchSize / 2)
                // highPriority — иначе у краёв выигрывает перетаскивание всей рамки
                .highPriorityGesture(resizeGesture(corner))
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            Text("Не удалось узнать. Выделите икону — так надёжнее.")
                .font(AppFont.regular(typ.footnote))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button {
                    onCancel()
                } label: {
                    Text("Отмена")
                        .font(AppFont.medium(typ.subheadline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    confirm()
                } label: {
                    Text("Распознать")
                        .font(AppFont.medium(typ.subheadline))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Жесты

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = beginDrag()
                var rect = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                rect.origin.x = min(max(rect.minX, imageFrame.minX), imageFrame.maxX - rect.width)
                rect.origin.y = min(max(rect.minY, imageFrame.minY), imageFrame.maxY - rect.height)
                cropRect = rect
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: CropCorner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = beginDrag()
                var minX = start.minX, maxX = start.maxX
                var minY = start.minY, maxY = start.maxY

                if corner.isLeft { minX += value.translation.width } else { maxX += value.translation.width }
                if corner.isTop { minY += value.translation.height } else { maxY += value.translation.height }

                // Сначала в границы изображения, потом — минимальный размер,
                // сдвигая именно ту сторону, которую тянут.
                minX = max(minX, imageFrame.minX)
                maxX = min(maxX, imageFrame.maxX)
                minY = max(minY, imageFrame.minY)
                maxY = min(maxY, imageFrame.maxY)

                let side = minSide
                if corner.isLeft { minX = min(minX, maxX - side) } else { maxX = max(maxX, minX + side) }
                if corner.isTop { minY = min(minY, maxY - side) } else { maxY = max(maxY, minY + side) }

                cropRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func beginDrag() -> CGRect {
        if let dragStart { return dragStart }
        dragStart = cropRect
        userAdjusted = true
        return cropRect
    }

    // MARK: - Геометрия

    /// Кадр изображения внутри контейнера с полем в пол-ручки по краям: иначе
    /// угловые ручки вылезают за GeometryReader и хуже ловят касания.
    private func imageRect(in container: CGSize) -> CGRect {
        let inset = handleTouchSize / 2
        let inner = CGSize(width: container.width - inset * 2,
                           height: container.height - inset * 2)
        return Self.fittedRect(imageSize: pixelSize, container: inner)
            .offsetBy(dx: inset, dy: inset)
    }

    /// Прямоугольник scaledToFit-изображения внутри контейнера. Считаем сами:
    /// это надёжнее, чем вычитывать размер уже отрисованного `Image`.
    private static func fittedRect(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
    }

    private var minSide: CGFloat {
        guard imageFrame.width > 0 else { return minCropSide }
        return min(minCropSide, imageFrame.width, imageFrame.height)
    }

    private func cornerPoint(_ corner: CropCorner) -> CGPoint {
        CGPoint(x: corner.isLeft ? cropRect.minX : cropRect.maxX,
                y: corner.isTop ? cropRect.minY : cropRect.maxY)
    }

    /// Пересчитывает кадр изображения (первое появление, поворот экрана).
    private func syncFrame(_ newFrame: CGRect) {
        guard newFrame.width > 0 else { return }
        let old = imageFrame
        imageFrame = newFrame

        if old.width > 0, cropRect.width > 0 {
            // Поворот/смена размера: сохраняем рамку в долях кадра.
            let rect = CGRect(
                x: newFrame.minX + (cropRect.minX - old.minX) / old.width * newFrame.width,
                y: newFrame.minY + (cropRect.minY - old.minY) / old.height * newFrame.height,
                width: cropRect.width / old.width * newFrame.width,
                height: cropRect.height / old.height * newFrame.height
            )
            cropRect = sanitized(rect)
        } else {
            applySeed()
        }
    }

    /// Ставит стартовую рамку: предложение Vision, иначе — 60% кадра по центру.
    private func applySeed(using box: CGRect? = nil) {
        guard imageFrame.width > 0, !userAdjusted else { return }
        if let visionBox = box ?? visionBox {
            cropRect = sanitized(displayRect(fromNormalized: visionBox))
        } else if cropRect.width <= 0 {
            cropRect = sanitized(imageFrame.insetBy(dx: imageFrame.width * 0.2,
                                                    dy: imageFrame.height * 0.2))
        }
    }

    /// Vision: нормированные координаты, начало отсчёта — левый нижний угол.
    private func displayRect(fromNormalized box: CGRect) -> CGRect {
        CGRect(x: imageFrame.minX + box.minX * imageFrame.width,
               y: imageFrame.minY + (1 - box.maxY) * imageFrame.height,
               width: box.width * imageFrame.width,
               height: box.height * imageFrame.height)
    }

    /// Загоняет рамку в границы изображения и вытягивает до минимального размера.
    private func sanitized(_ rect: CGRect) -> CGRect {
        guard imageFrame.width > 0 else { return rect }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else {
            return imageFrame.insetBy(dx: imageFrame.width * 0.2, dy: imageFrame.height * 0.2)
        }
        let side = minSide
        let width = min(max(rect.width, side), imageFrame.width)
        let height = min(max(rect.height, side), imageFrame.height)
        var x = rect.midX - width / 2
        var y = rect.midY - height / 2
        x = min(max(x, imageFrame.minX), imageFrame.maxX - width)
        y = min(max(y, imageFrame.minY), imageFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Автоподсказка рамки (Vision)

    private func startVisionSeed() {
        guard !visionStarted, let cg = source.cgImage else { return }
        visionStarted = true
        DispatchQueue.global(qos: .userInitiated).async {
            let box = Self.detectBoard(in: cg)
            guard let box else { return }
            DispatchQueue.main.async {
                // Никогда не выдёргиваем рамку из-под пользователя.
                guard !userAdjusted else { return }
                visionBox = box
                applySeed(using: box)
            }
        }
    }

    /// Прямоугольник доски, иначе — область внимания. Обе даёт нормированный
    /// boundingBox в системе координат уже нормализованного (.up) изображения.
    private static func detectBoard(in cgImage: CGImage) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)

        let rectangles = VNDetectRectanglesRequest()
        // aspect у Vision — отношение меньшей стороны к большей, [0…1];
        // доски икон вытянуты по вертикали, но не сильнее ~2:5.
        rectangles.minimumAspectRatio = 0.4
        rectangles.maximumAspectRatio = 1.0
        rectangles.minimumSize = 0.2
        rectangles.minimumConfidence = 0.6
        rectangles.maximumObservations = 3
        if (try? handler.perform([rectangles])) != nil,
           let best = rectangles.results?.max(by: {
               $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
           }) {
            return best.boundingBox
        }

        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([saliency])) != nil,
           let observation = saliency.results?.first,
           let object = observation.salientObjects?.first {
            // Saliency часто выделяет фрагмент (лик, фигуру), а не доску:
            // на контрольном IMG_9467 её рамка — 23% кадра и softmax 0.42,
            // тогда как 60% по центру даёт 0.87. Слишком маленькую рамку
            // считаем «доску не нашли» и падаем на дефолт 60%.
            let box = object.boundingBox
            if box.width * box.height >= 1.0 / 3.0 {
                return box
            }
        }
        return nil
    }

    // MARK: - Кроп

    private func confirm() {
        if let cropped = croppedImage() {
            onConfirm(cropped)
        } else {
            onConfirm(source)
        }
    }

    private func croppedImage() -> UIImage? {
        guard let cg = source.cgImage,
              imageFrame.width > 0, cropRect.width > 0 else { return nil }
        // display → пиксели: масштаб одинаков по обеим осям (scaledToFit).
        let scale = imageFrame.width / pixelSize.width
        guard scale > 0 else { return nil }

        // Рамка берётся как есть, без полей: граница обрезки — внешний край
        // доски, промах внутрь дешевле промаха наружу (замерено на полевых фото).
        var rect = CGRect(x: (cropRect.minX - imageFrame.minX) / scale,
                          y: (cropRect.minY - imageFrame.minY) / scale,
                          width: cropRect.width / scale,
                          height: cropRect.height / scale)

        let bounds = CGRect(origin: .zero, size: pixelSize)
        rect = rect.intersection(bounds).integral.intersection(bounds)
        guard rect.width >= 1, rect.height >= 1,
              let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

// MARK: - Угловая ручка

private struct CropCornerHandle: View {
    let corner: CropCorner
    let touchSize: CGFloat

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)   // зона касания 44×44, а не тонкий штрих
            Path { path in
                let arm: CGFloat = 20
                let center = CGPoint(x: touchSize / 2, y: touchSize / 2)
                let dx: CGFloat = corner.isLeft ? arm : -arm
                let dy: CGFloat = corner.isTop ? arm : -arm
                path.move(to: CGPoint(x: center.x + dx, y: center.y))
                path.addLine(to: center)
                path.addLine(to: CGPoint(x: center.x, y: center.y + dy))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: touchSize, height: touchSize)
        .contentShape(Rectangle())
    }
}

// MARK: - Нормализация ориентации

private extension UIImage {
    /// Копия с orientation == .up и scale == 1, чтобы `size` совпадал с пикселями,
    /// а `cgImage.cropping(to:)` работал в тех же координатах, что и экранная рамка.
    /// Съёмка проходит через `downscaled(maxDimension:)` и уже нормализована,
    /// но маленькие фото из галереи сохраняют EXIF-ориентацию.
    func iconCropNormalized() -> UIImage {
        if imageOrientation == .up, scale == 1 { return self }
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        guard pixels.width > 0, pixels.height > 0 else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: pixels, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: pixels))
        }
    }
}

#Preview {
    IconCropView(image: iconCropPreviewImage(), onCancel: {}, onConfirm: { _ in })
}

private func iconCropPreviewImage() -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let size = CGSize(width: 900, height: 1200)
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor.systemBrown.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}
#endif
