//
//  ImageCropViewController.swift
//  gPhotoKit
//
//  Enkel, interaktiv beskjæring presentert fra "…"-menyen i
//  ImageAnnotationViewController (se moreActionsButtonTapped). Ren UIKit med
//  fast frame-basert layout (ingen GeometryReader/ScrollView-zoom) — brukes
//  for å unngå at beskjæringen kolliderer med noe annet i redigeringsskjermen.
//

import UIKit

final class ImageCropViewController: UIViewController {
    private let sourceImage: UIImage
    private let onCancel: () -> Void
    private let onApply: (UIImage) -> Void

    private let imageView = UIImageView()
    private let overlayView = CropOverlayView()

    init(image: UIImage, onCancel: @escaping () -> Void, onApply: @escaping (UIImage) -> Void) {
        self.sourceImage = image
        self.onCancel = onCancel
        self.onApply = onApply
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("Avbryt", for: .normal)
        cancelBtn.setTitleColor(.white, for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 17)
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = "Beskjær"
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let applyBtn = UIButton(type: .system)
        applyBtn.setTitle("Bruk", for: .normal)
        applyBtn.setTitleColor(.white, for: .normal)
        applyBtn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        applyBtn.addTarget(self, action: #selector(applyTapped), for: .touchUpInside)
        applyBtn.translatesAutoresizingMaskIntoConstraints = false

        imageView.image = sourceImage
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.translatesAutoresizingMaskIntoConstraints = false

        overlayView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(cancelBtn)
        view.addSubview(titleLabel)
        view.addSubview(applyBtn)
        view.addSubview(imageView)
        view.addSubview(overlayView)

        NSLayoutConstraint.activate([
            cancelBtn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cancelBtn.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            applyBtn.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            applyBtn.centerYAnchor.constraint(equalTo: cancelBtn.centerYAnchor),

            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: cancelBtn.centerYAnchor),

            imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            imageView.topAnchor.constraint(equalTo: cancelBtn.bottomAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            overlayView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: imageView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlayView.updateImageFrame(computeImageFrame(), resetCropRect: overlayView.imageFrame == .zero)
    }

    private func computeImageFrame() -> CGRect {
        let container = imageView.bounds
        let imgSize = sourceImage.size
        guard imgSize.width > 0, imgSize.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / imgSize.width, container.height / imgSize.height)
        let fitSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let origin = CGPoint(x: (container.width - fitSize.width) / 2, y: (container.height - fitSize.height) / 2)
        return CGRect(origin: origin, size: fitSize)
    }

    @objc private func cancelTapped() { onCancel() }

    @objc private func applyTapped() {
        guard let cgImage = sourceImage.cgImage else { onApply(sourceImage); return }
        let imageFrame = overlayView.imageFrame
        let cropRect = overlayView.cropRect
        guard imageFrame.width > 0, imageFrame.height > 0 else { onApply(sourceImage); return }

        let scaleX = CGFloat(cgImage.width) / imageFrame.width
        let scaleY = CGFloat(cgImage.height) / imageFrame.height
        let pixelRect = CGRect(
            x: (cropRect.minX - imageFrame.minX) * scaleX,
            y: (cropRect.minY - imageFrame.minY) * scaleY,
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard pixelRect.width > 1, pixelRect.height > 1, let cropped = cgImage.cropping(to: pixelRect) else {
            onApply(sourceImage)
            return
        }
        onApply(UIImage(cgImage: cropped, scale: sourceImage.scale, orientation: sourceImage.imageOrientation))
    }
}

/// Tegner en nedtonet maske utenfor beskjæringsrektangelet og gir fire
/// hjørnehåndtak (endre størrelse) + dra i selve rektangelet (flytt). Rent
/// frame-basert — ingen zoom/scroll involvert.
private final class CropOverlayView: UIView {
    private(set) var imageFrame: CGRect = .zero
    private(set) var cropRect: CGRect = .zero

    private let maskLayer = CAShapeLayer()
    private let borderView = UIView()
    private var handles: [Corner: UIView] = [:]
    private var gestureStartRect: CGRect?

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    private let handleSize: CGFloat = 28
    private let minCropSize: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        backgroundColor = .clear

        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        layer.addSublayer(maskLayer)

        borderView.layer.borderColor = UIColor.white.cgColor
        borderView.layer.borderWidth = 1.5
        borderView.isUserInteractionEnabled = true
        addSubview(borderView)
        let moveGesture = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        borderView.addGestureRecognizer(moveGesture)

        for corner in Corner.allCases {
            let handle = UIView()
            handle.backgroundColor = .white
            handle.layer.cornerRadius = handleSize / 2
            handle.isUserInteractionEnabled = true
            addSubview(handle)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleResizePan(_:)))
            pan.name = cornerName(corner)
            handle.addGestureRecognizer(pan)
            handles[corner] = handle
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func cornerName(_ corner: Corner) -> String {
        switch corner {
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        }
    }

    private func corner(forGestureName name: String?) -> Corner? {
        Corner.allCases.first { cornerName($0) == name }
    }

    func updateImageFrame(_ frame: CGRect, resetCropRect: Bool) {
        imageFrame = frame
        if resetCropRect || cropRect == .zero {
            cropRect = frame
        } else {
            // Behold relativ posisjon/størrelse hvis viewet legges om (f.eks. rotasjon).
            cropRect = cropRect.intersection(frame)
            if cropRect.isEmpty { cropRect = frame }
        }
        layoutHandlesAndMask()
    }

    private func layoutHandlesAndMask() {
        borderView.frame = cropRect
        for corner in Corner.allCases {
            handles[corner]?.frame = CGRect(
                x: point(for: corner, in: cropRect).x - handleSize / 2,
                y: point(for: corner, in: cropRect).y - handleSize / 2,
                width: handleSize, height: handleSize
            )
        }
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(rect: cropRect))
        maskLayer.path = path.cgPath
        maskLayer.frame = bounds
    }

    private func point(for corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    @objc private func handleMovePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            gestureStartRect = cropRect
        case .changed:
            guard let start = gestureStartRect else { return }
            let t = gesture.translation(in: self)
            var newRect = start
            newRect.origin.x += t.x
            newRect.origin.y += t.y
            cropRect = clamp(newRect)
            layoutHandlesAndMask()
        case .ended, .cancelled, .failed:
            gestureStartRect = nil
        default:
            break
        }
    }

    @objc private func handleResizePan(_ gesture: UIPanGestureRecognizer) {
        guard let corner = corner(forGestureName: gesture.name) else { return }
        switch gesture.state {
        case .began:
            gestureStartRect = cropRect
        case .changed:
            guard let start = gestureStartRect else { return }
            let t = gesture.translation(in: self)
            cropRect = resized(start, corner: corner, by: t)
            layoutHandlesAndMask()
        case .ended, .cancelled, .failed:
            gestureStartRect = nil
        default:
            break
        }
    }

    private func resized(_ rect: CGRect, corner: Corner, by translation: CGPoint) -> CGRect {
        switch corner {
        case .topLeft:
            let newX = min(rect.maxX - minCropSize, max(imageFrame.minX, rect.minX + translation.x))
            let newY = min(rect.maxY - minCropSize, max(imageFrame.minY, rect.minY + translation.y))
            return CGRect(x: newX, y: newY, width: rect.maxX - newX, height: rect.maxY - newY)
        case .topRight:
            let newMaxX = max(rect.minX + minCropSize, min(imageFrame.maxX, rect.maxX + translation.x))
            let newY = min(rect.maxY - minCropSize, max(imageFrame.minY, rect.minY + translation.y))
            return CGRect(x: rect.minX, y: newY, width: newMaxX - rect.minX, height: rect.maxY - newY)
        case .bottomLeft:
            let newX = min(rect.maxX - minCropSize, max(imageFrame.minX, rect.minX + translation.x))
            let newMaxY = max(rect.minY + minCropSize, min(imageFrame.maxY, rect.maxY + translation.y))
            return CGRect(x: newX, y: rect.minY, width: rect.maxX - newX, height: newMaxY - rect.minY)
        case .bottomRight:
            let newMaxX = max(rect.minX + minCropSize, min(imageFrame.maxX, rect.maxX + translation.x))
            let newMaxY = max(rect.minY + minCropSize, min(imageFrame.maxY, rect.maxY + translation.y))
            return CGRect(x: rect.minX, y: rect.minY, width: newMaxX - rect.minX, height: newMaxY - rect.minY)
        }
    }

    private func clamp(_ rect: CGRect) -> CGRect {
        var result = rect
        if result.minX < imageFrame.minX { result.origin.x = imageFrame.minX }
        if result.minY < imageFrame.minY { result.origin.y = imageFrame.minY }
        if result.maxX > imageFrame.maxX { result.origin.x = imageFrame.maxX - result.width }
        if result.maxY > imageFrame.maxY { result.origin.y = imageFrame.maxY - result.height }
        return result
    }
}
