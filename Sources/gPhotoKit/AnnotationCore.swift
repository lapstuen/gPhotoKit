import UIKit
import PencilKit

// MARK: - AnnotationTool

public enum AnnotationTool {
    case select, arrow, line, circle, freehand, highlighter, rectangle, filledCircle, filledRect, number, text, image, paintBackground
}

extension AnnotationTool {
    var isFreehandLike: Bool { self == .freehand || self == .highlighter || self == .paintBackground }
}

func wrappedTextAttributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .left
    paragraphStyle.lineBreakMode = .byWordWrapping
    return [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraphStyle
    ]
}

func wrappedTextBounds(text: String, maxWidth: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGRect {
    let constrainedSize = CGSize(width: max(maxWidth, 1), height: .greatestFiniteMagnitude)
    return (text as NSString).boundingRect(
        with: constrainedSize,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: attributes,
        context: nil
    ).integral
}

func resolvedTextWidth(for item: AnnotationItem, canvasWidth: CGFloat) -> CGFloat {
    if let width = item.textWidth {
        return max(textMinimumWidth, width)
    }
    #if targetEnvironment(macCatalyst)
    return max(120, min(canvasWidth * 0.6, 420))
    #else
    return max(textMinimumWidth, min(canvasWidth * 0.35, 240))
    #endif
}

func textBoundingRect(for item: AnnotationItem, canvasWidth: CGFloat) -> CGRect {
    guard let origin = item.points.first else { return .zero }
    let font = resolveFont(name: item.fontName, size: item.fontSize)
    let attrs = wrappedTextAttributes(font: font, color: item.color)
    let width = resolvedTextWidth(for: item, canvasWidth: canvasWidth)
    let height = wrappedTextBounds(text: item.text, maxWidth: width, attributes: attrs).height
    return CGRect(x: origin.x, y: origin.y, width: width, height: max(height, font.lineHeight))
}

private let textMinimumWidth: CGFloat = 28

// MARK: - AnnotationItem

public struct AnnotationItem {
    public var tool: AnnotationTool
    public var color: UIColor
    public var lineWidth: CGFloat
    public var points: [CGPoint]
    public var number: Int
    public var text: String
    public var fontSize: CGFloat
    public var fontName: String
    public var textWidth: CGFloat?
    public var opacity: CGFloat
    public var overlayImage: UIImage?
    public var cornerRadius: CGFloat
    /// Bakgrunnsfyll bak tekst (kun brukt for .text). nil = ingen bakgrunn (gammel oppførsel).
    /// Fyllingsgraden gjenbruker `opacity`, samme mønster som filledRect/filledCircle.
    public var backgroundColor: UIColor?

    public init(tool: AnnotationTool, color: UIColor, lineWidth: CGFloat, points: [CGPoint],
                number: Int = 0, text: String = "", fontSize: CGFloat = 32, fontName: String = "bold",
                textWidth: CGFloat? = nil, opacity: CGFloat = 0.5, overlayImage: UIImage? = nil, cornerRadius: CGFloat = 0,
                backgroundColor: UIColor? = nil) {
        self.tool = tool; self.color = color; self.lineWidth = lineWidth; self.points = points
        self.number = number; self.text = text; self.fontSize = fontSize; self.fontName = fontName
        self.textWidth = textWidth; self.opacity = opacity; self.overlayImage = overlayImage; self.cornerRadius = cornerRadius
        self.backgroundColor = backgroundColor
    }
}

// MARK: - AnnotationCanvasView

open class AnnotationCanvasView: UIView {

    public var items: [AnnotationItem] = []

    // Switching away from freehand clears any in-progress stroke.
    public var currentTool: AnnotationTool = .select {
        didSet { if oldValue.isFreehandLike && !currentTool.isFreehandLike { finalizeFreehandSession() } }
    }
    public var currentColor: UIColor = .systemRed
    public var currentLineWidth: CGFloat = 14.0
    public var currentFillOpacity: CGFloat = 0.5
    public var currentCornerRadius: CGFloat = 0
    public var currentTextBackgroundColor: UIColor? = nil
    public var usesPencilKitForFreehand = false
    public var onTextTap: ((CGPoint) -> Void)?
    public var onSelectionChanged: ((Int?) -> Void)?
    public var onEditTextItem: ((Int) -> Void)?
    public var onContextMenu: ((_ itemIndex: Int) -> UIContextMenuConfiguration?)?
    public var onContextMenuMac: ((_ itemIndex: Int, _ locationInView: CGPoint) -> Bool)?
    /// Kalt når et strøk tegnet med `.paintBackground`-verktøyet er ferdig.
    /// Strøket blir ALDRI lagt til i `items` (og dermed aldri i prosjektfilen)
    /// — det er opp til mottakeren å "bake" det permanent inn i bakgrunnsbildet.
    public var onBakeStroke: ((AnnotationItem) -> Void)?
    public var isTextResizeInteractionActive = false

    public private(set) var selectedItemIndex: Int? = nil {
        didSet { onSelectionChanged?(selectedItemIndex) }
    }

    // Active freehand stroke while the current touch sequence is in progress.
    private var activeFreehandStrokeIndex: Int? = nil

    private var currentPoints: [CGPoint] = []
    private var draggedItemIndex: Int? = nil
    private var draggedPointIndex: Int? = nil
    private var dragOffset: CGPoint = .zero
    private var touchStartPoint: CGPoint = .zero
    private var didDragSignificantly = false
    private var dragStartBounds: CGRect = .zero
    private var dragStartPoints: [CGPoint] = []
    private let handleRadius: CGFloat = 18
    private var textResizeHitRadius: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 18
        #else
        return 12
        #endif
    }
    private var textHitPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 10
        #else
        return 20
        #endif
    }
    private var textResizeVisualSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 26
        #else
        return 28
        #endif
    }
    private let handleDrawR: CGFloat = 10
    private let textResizeHandleView = UIView()
    private let textResizeHandleIconView = UIImageView()

    // MARK: - Public API

    public func deselect() { selectedItemIndex = nil; setNeedsDisplay() }

    public func selectItem(at index: Int) {
        guard index < items.count else { return }
        selectedItemIndex = index; setNeedsDisplay()
    }

    /// Call from Escape handler. Returns true if a freehand stroke was active.
    @discardableResult
    public func finalizeFreehandSession() -> Bool {
        guard activeFreehandStrokeIndex != nil else { return false }
        activeFreehandStrokeIndex = nil
        return true
    }

    public func adjustSelectedFontSize(delta: CGFloat) {
        guard let idx = selectedItemIndex, items[idx].tool == .text else { return }
        items[idx].fontSize = max(8, min(1000, items[idx].fontSize + delta))
        setNeedsDisplay()
    }

    public func adjustSelectedTextWidth(delta: CGFloat) {
        guard let idx = selectedItemIndex, items[idx].tool == .text else { return }
        let currentWidth = resolvedTextWidth(for: items[idx], canvasWidth: bounds.width)
        items[idx].textWidth = max(textMinimumWidth, currentWidth + delta)
        setNeedsDisplay()
    }

    public func itemIndex(at point: CGPoint) -> Int? {
        hitTestAnyItem(at: point) ?? hitTestTextItem(at: point)
    }

    // MARK: - Hit testing

    private func hitTestTextItem(at point: CGPoint) -> Int? {
        for (index, item) in items.enumerated().reversed() {
            guard item.tool == .text else { continue }
            let hitRect = textBoundingRect(for: item, canvasWidth: bounds.width).insetBy(dx: -textHitPadding, dy: -textHitPadding)
            if hitRect.contains(point) { return index }
        }
        return nil
    }

    private func textResizeHandleFrame(for textRect: CGRect) -> CGRect {
        let size = textResizeVisualSize
        let nudge: CGFloat = 5
        return CGRect(x: textRect.maxX - size * 0.5 - nudge,
                      y: textRect.maxY - size * 0.5 - nudge,
                      width: size,
                      height: size)
    }

    private func hitTestTextResizeHandle(at point: CGPoint) -> Int? {
        for (index, item) in items.enumerated().reversed() {
            guard item.tool == .text else { continue }
            let textRect = textBoundingRect(for: item, canvasWidth: bounds.width)
            let hitRect = textResizeHandleFrame(for: textRect).insetBy(dx: -textResizeHitRadius, dy: -textResizeHitRadius)
            if hitRect.contains(point) {
                return index
            }
        }
        return nil
    }

    private func hitTestTextBody(at point: CGPoint) -> Int? {
        for (index, item) in items.enumerated().reversed() {
            guard item.tool == .text else { continue }
            let textRect = textBoundingRect(for: item, canvasWidth: bounds.width).insetBy(dx: -textHitPadding, dy: -textHitPadding)
            let handleRect = textResizeHandleFrame(for: textBoundingRect(for: item, canvasWidth: bounds.width)).insetBy(dx: -textResizeHitRadius, dy: -textResizeHitRadius)
            if textRect.contains(point) && !handleRect.contains(point) {
                return index
            }
        }
        return nil
    }

    private func hitTestAnyItem(at point: CGPoint) -> Int? {
        for (index, item) in items.enumerated().reversed() {
            guard item.tool != .text else { continue }
            if item.tool.isFreehandLike {
                let valid = item.points.filter { !$0.x.isInfinite }
                guard valid.count > 1 else { continue }
                let xs = valid.map { $0.x }, ys = valid.map { $0.y }
                let r = CGRect(x: xs.min()!, y: ys.min()!,
                               width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                    .insetBy(dx: -20, dy: -20)
                if r.contains(point) { return index }
            } else if item.points.count >= 2 {
                if rectFromPoints(item.points[0], item.points[1]).insetBy(dx: -20, dy: -20).contains(point) {
                    return index
                }
            }
        }
        return nil
    }

    private func hitTestHandle(at point: CGPoint, for index: Int) -> Int? {
        let item = items[index]
        if item.tool == .text {
            let textRect = textBoundingRect(for: item, canvasWidth: bounds.width)
            let corner = CGPoint(x: textRect.maxX - 10, y: textRect.maxY - 10)
            if hypot(point.x - corner.x, point.y - corner.y) <= handleRadius { return 3 }
            return nil
        }
        if item.tool.isFreehandLike {
            for (i, corner) in freehandCorners(item).enumerated() {
                if hypot(point.x - corner.x, point.y - corner.y) <= handleRadius { return i }
            }
            return nil
        }
        if item.tool == .image, item.points.count >= 2 {
            for (i, corner) in imageCorners(item).enumerated() {
                if hypot(point.x - corner.x, point.y - corner.y) <= handleRadius { return i }
            }
            return nil
        }
        for (i, pt) in item.points.enumerated() {
            if hypot(point.x - pt.x, point.y - pt.y) <= handleRadius { return i }
        }
        return nil
    }

    private func imageCorners(_ item: AnnotationItem) -> [CGPoint] {
        let p0 = item.points[0], p1 = item.points[1]
        return [p0, CGPoint(x: p1.x, y: p0.y), CGPoint(x: p0.x, y: p1.y), p1]
    }

    private func freehandBounds(_ item: AnnotationItem) -> CGRect? {
        let valid = item.points.filter { !$0.x.isInfinite }
        guard !valid.isEmpty,
              let x0 = valid.map({ $0.x }).min(), let x1 = valid.map({ $0.x }).max(),
              let y0 = valid.map({ $0.y }).min(), let y1 = valid.map({ $0.y }).max()
        else { return nil }
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
    }

    private func freehandCorners(_ item: AnnotationItem) -> [CGPoint] {
        guard let r = freehandBounds(item) else { return [] }
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false
        #if targetEnvironment(macCatalyst)
        addInteraction(UIContextMenuInteraction(delegate: self))
        #endif
        configureTextResizeHandle()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear; isOpaque = false
        #if targetEnvironment(macCatalyst)
        addInteraction(UIContextMenuInteraction(delegate: self))
        #endif
        configureTextResizeHandle()
    }

    // MARK: - Drawing

    open override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for (idx, item) in items.enumerated() {
            renderItem(item, in: ctx)
            if idx == selectedItemIndex {
                if item.tool == .text {
                    ctx.setStrokeColor(UIColor.systemYellow.cgColor)
                    ctx.setLineWidth(2)
                    ctx.setLineDash(phase: 0, lengths: [6, 3])
                    let textRect = textBoundingRect(for: item, canvasWidth: bounds.width)
                    ctx.stroke(textRect.insetBy(dx: -6, dy: -4))
                    ctx.setLineDash(phase: 0, lengths: [])
                } else {
                    drawSelectionHandles(for: item, in: ctx)
                }
            }
        }
        if !currentPoints.isEmpty {
            let nextNum = items.filter { $0.tool == .number }.count + 1
            renderItem(AnnotationItem(tool: currentTool, color: currentColor,
                                      lineWidth: currentLineWidth, points: currentPoints,
                                      number: nextNum, opacity: currentFillOpacity), in: ctx)
        }
        updateTextResizeHandleOverlay()
    }

    private func configureTextResizeHandle() {
        textResizeHandleView.isHidden = true
        textResizeHandleView.isUserInteractionEnabled = false
        textResizeHandleView.backgroundColor = .systemBlue
        textResizeHandleView.layer.cornerRadius = 6
        textResizeHandleView.layer.borderWidth = 2
        textResizeHandleView.layer.borderColor = UIColor.white.cgColor
        textResizeHandleView.layer.shadowColor = UIColor.black.cgColor
        textResizeHandleView.layer.shadowOpacity = 0.25
        textResizeHandleView.layer.shadowRadius = 2
        textResizeHandleView.layer.shadowOffset = CGSize(width: 0, height: 1)
        textResizeHandleView.layer.zPosition = 999

        let symbol = UIImage(systemName: "arrow.up.left.and.arrow.down.right",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        textResizeHandleIconView.image = symbol?.withTintColor(.white, renderingMode: .alwaysOriginal)
        textResizeHandleIconView.contentMode = .scaleAspectFit
        textResizeHandleIconView.translatesAutoresizingMaskIntoConstraints = false

        textResizeHandleView.addSubview(textResizeHandleIconView)
        addSubview(textResizeHandleView)

        NSLayoutConstraint.activate([
            textResizeHandleIconView.leadingAnchor.constraint(equalTo: textResizeHandleView.leadingAnchor, constant: 4),
            textResizeHandleIconView.trailingAnchor.constraint(equalTo: textResizeHandleView.trailingAnchor, constant: -4),
            textResizeHandleIconView.topAnchor.constraint(equalTo: textResizeHandleView.topAnchor, constant: 4),
            textResizeHandleIconView.bottomAnchor.constraint(equalTo: textResizeHandleView.bottomAnchor, constant: -4),
        ])
    }

    private func updateTextResizeHandleOverlay() {
        guard let idx = selectedItemIndex, idx < items.count, items[idx].tool == .text else {
            textResizeHandleView.isHidden = true
            return
        }
        let textRect = textBoundingRect(for: items[idx], canvasWidth: bounds.width)
        textResizeHandleView.frame = textResizeHandleFrame(for: textRect)
        textResizeHandleView.isHidden = false
        bringSubviewToFront(textResizeHandleView)
    }

    private func drawSelectionHandles(for item: AnnotationItem, in ctx: CGContext) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setStrokeColor(UIColor.systemYellow.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [6, 3])

        if item.tool == .image, item.points.count >= 2 {
            ctx.stroke(rectFromPoints(item.points[0], item.points[1]).insetBy(dx: -4, dy: -4))
            ctx.setLineDash(phase: 0, lengths: [])
            let offset = handleDrawR, p0 = item.points[0], p1 = item.points[1]
            let corners = [CGPoint(x: p0.x - offset, y: p0.y - offset),
                           CGPoint(x: p1.x + offset, y: p0.y - offset),
                           CGPoint(x: p0.x - offset, y: p1.y + offset),
                           CGPoint(x: p1.x + offset, y: p1.y + offset)]
            ctx.setFillColor(UIColor.systemYellow.cgColor)
            for c in corners {
                let r = CGRect(x: c.x - handleDrawR, y: c.y - handleDrawR, width: handleDrawR*2, height: handleDrawR*2)
                ctx.fillEllipse(in: r); ctx.setStrokeColor(UIColor.black.cgColor)
                ctx.setLineWidth(1.5); ctx.strokeEllipse(in: r)
            }
            return
        }

        if item.tool.isFreehandLike {
            guard let r = freehandBounds(item) else { return }
            ctx.stroke(CGRect(x: r.minX - 8, y: r.minY - 8, width: r.width + 16, height: r.height + 16))
            ctx.setLineDash(phase: 0, lengths: [])
            let offset = handleDrawR
            let corners = [CGPoint(x: r.minX - offset, y: r.minY - offset),
                           CGPoint(x: r.maxX + offset, y: r.minY - offset),
                           CGPoint(x: r.minX - offset, y: r.maxY + offset),
                           CGPoint(x: r.maxX + offset, y: r.maxY + offset)]
            ctx.setFillColor(UIColor.systemYellow.cgColor)
            for c in corners {
                let cr = CGRect(x: c.x - handleDrawR, y: c.y - handleDrawR, width: handleDrawR*2, height: handleDrawR*2)
                ctx.fillEllipse(in: cr)
                ctx.setStrokeColor(UIColor.black.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: cr)
            }
            return
        }

        if item.tool == .text {
            let textRect = textBoundingRect(for: item, canvasWidth: bounds.width)
            ctx.stroke(textRect.insetBy(dx: -8, dy: -8))
            ctx.setLineDash(phase: 0, lengths: [])
            let size: CGFloat = 30
            let r = CGRect(x: textRect.maxX - size * 0.75, y: textRect.maxY - size * 0.75, width: size, height: size)
            ctx.setFillColor(UIColor.systemPink.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(UIColor.black.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(r)
            return
        }

        if item.points.count >= 2 {
            ctx.stroke(rectFromPoints(item.points[0], item.points[1]).insetBy(dx: -8, dy: -8))
        }
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setFillColor(UIColor.systemYellow.cgColor)
        for pt in item.points {
            let r = CGRect(x: pt.x - handleDrawR, y: pt.y - handleDrawR, width: handleDrawR*2, height: handleDrawR*2)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(UIColor.white.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: r)
        }
    }

    private func renderItem(_ item: AnnotationItem, in ctx: CGContext) {
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setLineWidth(item.lineWidth)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)

        switch item.tool {
        case .freehand, .paintBackground:
            guard item.points.contains(where: { !$0.x.isInfinite }) else { return }
            var penDown = false
            for pt in item.points {
                if pt.x.isInfinite { penDown = false; continue }
                if !penDown { ctx.move(to: pt); penDown = true } else { ctx.addLine(to: pt) }
            }
            ctx.strokePath()

        case .highlighter:
            guard item.points.contains(where: { !$0.x.isInfinite }) else { return }
            ctx.saveGState()
            ctx.setLineCap(.square)
            ctx.setAlpha(item.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            var penDown = false
            for pt in item.points {
                if pt.x.isInfinite { penDown = false; continue }
                if !penDown { ctx.move(to: pt); penDown = true } else { ctx.addLine(to: pt) }
            }
            ctx.strokePath()
            ctx.endTransparencyLayer()
            ctx.restoreGState()

        case .circle:
            guard item.points.count == 2 else { return }
            ctx.strokeEllipse(in: rectFromPoints(item.points[0], item.points[1]))

        case .arrow:
            guard item.points.count == 2 else { return }
            renderArrow(from: item.points[0], to: item.points[1], color: item.color, lineWidth: item.lineWidth, in: ctx)

        case .line:
            guard item.points.count == 2 else { return }
            ctx.move(to: item.points[0]); ctx.addLine(to: item.points[1]); ctx.strokePath()

        case .rectangle:
            guard item.points.count == 2 else { return }
            let rrect = rectFromPoints(item.points[0], item.points[1])
            if item.cornerRadius > 0 {
                let path = UIBezierPath(roundedRect: rrect, cornerRadius: item.cornerRadius)
                ctx.addPath(path.cgPath); ctx.strokePath()
            } else {
                ctx.stroke(rrect)
            }

        case .filledCircle:
            guard item.points.count == 2 else { return }
            ctx.setFillColor(item.color.withAlphaComponent(item.opacity).cgColor)
            ctx.fillEllipse(in: rectFromPoints(item.points[0], item.points[1]))

        case .filledRect:
            guard item.points.count == 2 else { return }
            ctx.setFillColor(item.color.withAlphaComponent(item.opacity).cgColor)
            let frrect = rectFromPoints(item.points[0], item.points[1])
            if item.cornerRadius > 0 {
                let path = UIBezierPath(roundedRect: frrect, cornerRadius: item.cornerRadius)
                ctx.addPath(path.cgPath); ctx.fillPath()
            } else {
                ctx.fill(frrect)
            }

        case .number:
            guard item.points.count == 2 else { return }
            let r = rectFromPoints(item.points[0], item.points[1])
            ctx.setFillColor(item.color.withAlphaComponent(item.opacity).cgColor)
            ctx.fillEllipse(in: r)
            let fontSize = max(min(r.width, r.height) * 0.55, 10)
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: fontSize), .foregroundColor: UIColor.black]
            let str = "\(item.number)" as NSString
            let ts = str.size(withAttributes: attrs)
            str.draw(in: CGRect(x: r.midX - ts.width/2, y: r.midY - ts.height/2, width: ts.width, height: ts.height), withAttributes: attrs)

        case .text:
            guard !item.text.isEmpty, let pt = item.points.first else { return }
            let font = resolveFont(name: item.fontName, size: item.fontSize)
            let attrs = wrappedTextAttributes(font: font, color: item.color)
            let textRect = textBoundingRect(for: item, canvasWidth: bounds.width)
            // Fast padding/hjørneradius på tekst-bakgrunnen, ikke justerbar via UI (speiler gPhotoMac).
            let textBackgroundPadding: CGFloat = 8
            let textBackgroundCornerRadius: CGFloat = 6
            let hasBackground = item.backgroundColor != nil
            let textDrawX = pt.x + (hasBackground ? textBackgroundPadding : 0)
            let textDrawY = pt.y + (hasBackground ? textBackgroundPadding : 0)
            if let bg = item.backgroundColor {
                let bgRect = CGRect(x: textRect.origin.x, y: textRect.origin.y,
                                    width: textRect.width + textBackgroundPadding * 2,
                                    height: textRect.height + textBackgroundPadding * 2)
                ctx.setFillColor(bg.withAlphaComponent(item.opacity).cgColor)
                let path = UIBezierPath(roundedRect: bgRect, cornerRadius: textBackgroundCornerRadius)
                ctx.addPath(path.cgPath); ctx.fillPath()
            }
            item.text.draw(in: CGRect(x: textDrawX, y: textDrawY, width: textRect.width, height: textRect.height),
                           withAttributes: attrs)

        case .image:
            guard let img = item.overlayImage, item.points.count == 2 else { return }
            img.draw(in: rectFromPoints(item.points[0], item.points[1]))

        case .select:
            break
        }
    }

    private func rectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func renderArrow(from start: CGPoint, to end: CGPoint, color: UIColor, lineWidth: CGFloat, in ctx: CGContext) {
        ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
        let angle = atan2(end.y - start.y, end.x - start.x)
        let hl = max(18, lineWidth * 5), ha: CGFloat = .pi / 6
        ctx.move(to: end); ctx.addLine(to: CGPoint(x: end.x - hl*cos(angle-ha), y: end.y - hl*sin(angle-ha))); ctx.strokePath()
        ctx.move(to: end); ctx.addLine(to: CGPoint(x: end.x - hl*cos(angle+ha), y: end.y - hl*sin(angle+ha))); ctx.strokePath()
    }

    // MARK: - Touch handling

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)
        isTextResizeInteractionActive = false
        touchStartPoint = pt; didDragSignificantly = false; draggedPointIndex = nil

        if currentTool.isFreehandLike {
            if usesPencilKitForFreehand { return }
            // Images can always be selected even in freehand mode
            if let selIdx = selectedItemIndex, selIdx < items.count, items[selIdx].tool == .image {
                if let ptIdx = hitTestHandle(at: pt, for: selIdx) {
                    draggedItemIndex = selIdx; draggedPointIndex = ptIdx; setNeedsDisplay(); return
                }
                if rectFromPoints(items[selIdx].points[0], items[selIdx].points[1]).insetBy(dx: -20, dy: -20).contains(pt) {
                    draggedItemIndex = selIdx
                    dragOffset = CGPoint(x: pt.x - items[selIdx].points[0].x, y: pt.y - items[selIdx].points[0].y)
                    setNeedsDisplay(); return
                }
            }
            if let idx = hitTestAnyItem(at: pt), items[idx].tool == .image {
                draggedItemIndex = idx; selectedItemIndex = idx
                dragOffset = CGPoint(x: pt.x - items[idx].points[0].x, y: pt.y - items[idx].points[0].y)
                setNeedsDisplay(); return
            }

            // Start a new stroke for every touch sequence.
            if selectedItemIndex != nil { selectedItemIndex = nil }
            draggedItemIndex = nil
            items.append(AnnotationItem(tool: currentTool, color: currentColor,
                                         lineWidth: currentLineWidth, points: [pt], opacity: currentFillOpacity))
            activeFreehandStrokeIndex = items.count - 1
            setNeedsDisplay()
            return
        }

        // 1. Text resize handle wins over body hits.
        if let idx = hitTestTextResizeHandle(at: pt) {
            isTextResizeInteractionActive = true
            draggedItemIndex = idx
            selectedItemIndex = idx
            draggedPointIndex = 3
            setNeedsDisplay()
            return
        }

        // 2. Text can be dragged directly from its body, regardless of the active tool.
        if let idx = hitTestTextBody(at: pt) {
            draggedItemIndex = idx
            selectedItemIndex = idx
            dragOffset = CGPoint(x: pt.x - items[idx].points[0].x, y: pt.y - items[idx].points[0].y)
            setNeedsDisplay()
            return
        }

        // 3. Handles of selected shape/text (always — allows resize while any tool is active)
        if let selIdx = selectedItemIndex, selIdx < items.count {
            if let ptIdx = hitTestHandle(at: pt, for: selIdx) {
                draggedItemIndex = selIdx; draggedPointIndex = ptIdx
                if items[selIdx].tool == .freehand {
                    dragStartPoints = items[selIdx].points
                    dragStartBounds = freehandBounds(items[selIdx]) ?? .zero
                }
                setNeedsDisplay(); return
            }
        }
        // 4. Select/move existing items only when the select tool is active
        if currentTool == .select {
            if let idx = hitTestAnyItem(at: pt) {
                draggedItemIndex = idx; selectedItemIndex = idx
                dragOffset = CGPoint(x: pt.x - items[idx].points[0].x, y: pt.y - items[idx].points[0].y)
                setNeedsDisplay(); return
            }
        }
        // 5. Empty space / start drawing
        if selectedItemIndex != nil { selectedItemIndex = nil; setNeedsDisplay() }
        draggedItemIndex = nil
        if currentTool == .text || currentTool == .select { return }
        currentPoints = [pt]; setNeedsDisplay()
    }

    open override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self) else { return }
        if hypot(pt.x - touchStartPoint.x, pt.y - touchStartPoint.y) > 4 { didDragSignificantly = true }

        if let idx = draggedItemIndex {
            if let ptIdx = draggedPointIndex {
                if items[idx].tool == .image { applyImageCornerDrag(index: idx, cornerIndex: ptIdx, to: pt) }
                else if items[idx].tool == .freehand { applyFreehandCornerDrag(index: idx, cornerIndex: ptIdx, to: pt) }
                else if items[idx].tool == .text { applyTextCornerDrag(index: idx, cornerIndex: ptIdx, to: pt) }
                else { items[idx].points[ptIdx] = pt }
            } else {
                let newP0 = CGPoint(x: pt.x - dragOffset.x, y: pt.y - dragOffset.y)
                let delta = CGPoint(x: newP0.x - items[idx].points[0].x, y: newP0.y - items[idx].points[0].y)
                items[idx].points = items[idx].points.map { $0.x.isInfinite ? $0 : CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
            }
            setNeedsDisplay(); return
        }

        if currentTool.isFreehandLike, usesPencilKitForFreehand {
            return
        }
        if currentTool.isFreehandLike, let strokeIdx = activeFreehandStrokeIndex, strokeIdx < items.count {
            items[strokeIdx].points.append(pt)
            setNeedsDisplay()
            return
        }

        switch currentTool {
        case .arrow, .line, .circle, .rectangle, .filledCircle, .filledRect, .number:
            currentPoints = currentPoints.isEmpty ? [pt, pt] : [currentPoints[0], pt]
        case .freehand, .highlighter, .text, .image, .select, .paintBackground:
            break
        }
        setNeedsDisplay()
    }

    open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)

        if let idx = draggedItemIndex {
            if let ptIdx = draggedPointIndex {
                if items[idx].tool == .image { applyImageCornerDrag(index: idx, cornerIndex: ptIdx, to: pt) }
                else if items[idx].tool == .freehand { applyFreehandCornerDrag(index: idx, cornerIndex: ptIdx, to: pt) }
                else if items[idx].tool == .text { applyTextCornerDrag(index: idx, cornerIndex: ptIdx, to: pt) }
                else { items[idx].points[ptIdx] = pt }
                draggedPointIndex = nil
                dragStartPoints = []; dragStartBounds = .zero
            } else {
                let newP0 = CGPoint(x: pt.x - dragOffset.x, y: pt.y - dragOffset.y)
                let delta = CGPoint(x: newP0.x - items[idx].points[0].x, y: newP0.y - items[idx].points[0].y)
                items[idx].points = items[idx].points.map { $0.x.isInfinite ? $0 : CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
                if !didDragSignificantly && touch.tapCount >= 2 && items[idx].tool == .text { onEditTextItem?(idx) }
            }
            draggedItemIndex = nil; dragOffset = .zero; isTextResizeInteractionActive = false; setNeedsDisplay(); return
        }

        if currentTool.isFreehandLike, usesPencilKitForFreehand {
            return
        }
        if currentTool.isFreehandLike, let strokeIdx = activeFreehandStrokeIndex, strokeIdx < items.count {
            items[strokeIdx].points.append(pt)
            activeFreehandStrokeIndex = nil
            if currentTool == .paintBackground {
                let bakedItem = items[strokeIdx]
                items.remove(at: strokeIdx)
                onBakeStroke?(bakedItem)
            } else {
                selectedItemIndex = strokeIdx
            }
            setNeedsDisplay()
            return
        }

        if currentTool == .text {
            currentPoints = []
            activeFreehandStrokeIndex = nil
            onTextTap?(pt)
            return
        }

        switch currentTool {
        case .arrow, .line, .circle, .rectangle, .filledCircle, .filledRect, .number, .text, .image, .select, .freehand, .highlighter, .paintBackground:
            currentPoints = currentPoints.isEmpty ? [pt, pt] : [currentPoints[0], pt]
        }
        if currentPoints.count >= 2 {
            let nextNum = items.filter { $0.tool == .number }.count + 1
            items.append(AnnotationItem(tool: currentTool, color: currentColor,
                                        lineWidth: currentLineWidth, points: currentPoints,
                                        number: nextNum, opacity: currentFillOpacity,
                                        cornerRadius: currentCornerRadius))
            // Nyopprettet form forblir valgt, slik at farge/bredde/corner
            // radius/fyllingsgrad kan justeres med en gang — uten å måtte
            // bytte til "Velg"-verktøyet og trykke på formen manuelt først.
            selectedItemIndex = items.count - 1
        }
        currentPoints = []; setNeedsDisplay()
    }

    open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isTextResizeInteractionActive = false
        draggedItemIndex = nil
        draggedPointIndex = nil
        dragOffset = .zero
        activeFreehandStrokeIndex = nil
    }

    private func applyImageCornerDrag(index: Int, cornerIndex: Int, to pt: CGPoint) {
        switch cornerIndex {
        case 0: items[index].points[0] = pt
        case 1: items[index].points[1].x = pt.x; items[index].points[0].y = pt.y
        case 2: items[index].points[0].x = pt.x; items[index].points[1].y = pt.y
        case 3: items[index].points[1] = pt
        default: break
        }
    }

    private func applyTextCornerDrag(index: Int, cornerIndex: Int, to pt: CGPoint) {
        let textRect = textBoundingRect(for: items[index], canvasWidth: bounds.width)
        guard cornerIndex == 3 else { return }
        let newWidth = max(textMinimumWidth, pt.x - textRect.minX)
        items[index].textWidth = newWidth
    }

    private func applyFreehandCornerDrag(index: Int, cornerIndex: Int, to pt: CGPoint) {
        let b = dragStartBounds
        guard b.width > 0.001, b.height > 0.001 else { return }
        // Anchor = opposite corner, origCorner = corner being dragged
        let anchor: CGPoint
        let origCorner: CGPoint
        switch cornerIndex {
        case 0: anchor = CGPoint(x: b.maxX, y: b.maxY); origCorner = CGPoint(x: b.minX, y: b.minY)
        case 1: anchor = CGPoint(x: b.minX, y: b.maxY); origCorner = CGPoint(x: b.maxX, y: b.minY)
        case 2: anchor = CGPoint(x: b.maxX, y: b.minY); origCorner = CGPoint(x: b.minX, y: b.maxY)
        case 3: anchor = CGPoint(x: b.minX, y: b.minY); origCorner = CGPoint(x: b.maxX, y: b.maxY)
        default: return
        }
        let sx = (pt.x - anchor.x) / (origCorner.x - anchor.x)
        let sy = (pt.y - anchor.y) / (origCorner.y - anchor.y)
        items[index].points = dragStartPoints.map { p in
            guard !p.x.isInfinite else { return p }
            return CGPoint(x: anchor.x + (p.x - anchor.x) * sx,
                           y: anchor.y + (p.y - anchor.y) * sy)
        }
    }

    // MARK: - Actions

    public func duplicateSelected(offset: CGPoint = CGPoint(x: 20, y: 20)) {
        guard let idx = selectedItemIndex else { return }
        var copy = items[idx]
        copy.points = copy.points.map { $0.x.isInfinite ? $0 : CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        items.insert(copy, at: idx + 1); selectedItemIndex = idx + 1; setNeedsDisplay()
    }

    /// Flytter valgt objekt helt fremst (øverst i lagrekkefølgen), uansett hvor
    /// mange objekter som finnes eller hva som er gjort tidligere — trygt å
    /// bruke om og om igjen på forskjellige objekter uten at det ene overskriver
    /// det andre (i motsetning til et enkelt "bytt med nabo"-steg).
    public func moveSelectedToFront() {
        guard let idx = selectedItemIndex, idx < items.count - 1 else { return }
        let item = items.remove(at: idx)
        items.append(item)
        selectedItemIndex = items.count - 1
        setNeedsDisplay()
    }

    /// Flytter valgt objekt helt bakerst (nederst i lagrekkefølgen) — samme
    /// prinsipp som `moveSelectedToFront()`, bare motsatt retning.
    public func moveSelectedToBack() {
        guard let idx = selectedItemIndex, idx > 0 else { return }
        let item = items.remove(at: idx)
        items.insert(item, at: 0)
        selectedItemIndex = 0
        setNeedsDisplay()
    }

    public func deleteSelected() {
        guard let idx = selectedItemIndex else { return }
        if activeFreehandStrokeIndex == idx { activeFreehandStrokeIndex = nil }
        items.remove(at: idx); selectedItemIndex = nil; setNeedsDisplay()
    }

    public func undo() {
        guard !items.isEmpty else { return }
        if selectedItemIndex == items.count - 1 { selectedItemIndex = nil }
        if activeFreehandStrokeIndex == items.count - 1 { activeFreehandStrokeIndex = nil }
        items.removeLast(); setNeedsDisplay()
    }

    public func clear() { items.removeAll(); selectedItemIndex = nil; activeFreehandStrokeIndex = nil; setNeedsDisplay() }

    private func finalizeSession() { activeFreehandStrokeIndex = nil }
}

// MARK: - Document persistence

public struct AnnotationDocument: Codable {
    public let version: Int
    public let canvasWidth: Double?
    public let canvasHeight: Double?
    public let imagePixelWidth: Double?
    public let imagePixelHeight: Double?
    public let imageBase64: String?
    public let pencilDrawingBase64: String?
    public let pencilDrawingNormalizedToImageSpace: Bool?
    public let items: [CodableItem]

    public struct CodableItem: Codable {
        public let tool: String
        public let color: [Double]          // [r, g, b, a]
        public let lineWidth: Double
        public let points: [CodablePoint]
        public let number: Int
        public let text: String
        public let fontSize: Double
        public let fontName: String
        public let textWidth: Double?
        public let opacity: Double
        public let overlayImageBase64: String?
        public let cornerRadius: Double?
        public let backgroundColor: [Double]?
    }

    public struct CodablePoint: Codable {
        public let x: Double?   // nil = pen-lift sentinel (infinity)
        public let y: Double?
    }
}

extension AnnotationCanvasView {

    public func encodeDocument(backgroundImage: UIImage? = nil,
                               pencilDrawingData: Data? = nil,
                               pencilDrawingNormalizedToImageSpace: Bool = false) -> Data? {
        let codableItems = items.map { item -> AnnotationDocument.CodableItem in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            item.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let pts = item.points.map { pt -> AnnotationDocument.CodablePoint in
                pt.x.isInfinite ? .init(x: nil, y: nil) : .init(x: Double(pt.x), y: Double(pt.y))
            }
            let overlayB64 = item.overlayImage.flatMap { $0.pngData() }?.base64EncodedString()
            let bg: [Double]? = item.backgroundColor.map { bgColor in
                var br: CGFloat = 0, bg2: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
                bgColor.getRed(&br, green: &bg2, blue: &bb, alpha: &ba)
                return [Double(br), Double(bg2), Double(bb), Double(ba)]
            }
            return .init(tool: toolToString(item.tool),
                         color: [Double(r), Double(g), Double(b), Double(a)],
                         lineWidth: Double(item.lineWidth),
                         points: pts,
                         number: item.number,
                         text: item.text,
                         fontSize: Double(item.fontSize),
                         fontName: item.fontName,
                         textWidth: item.textWidth.map(Double.init),
                         opacity: Double(item.opacity),
                         overlayImageBase64: overlayB64,
                         cornerRadius: Double(item.cornerRadius),
                         backgroundColor: bg)
        }
        let imgB64 = backgroundImage.flatMap { $0.jpegData(compressionQuality: 0.88) }?.base64EncodedString()
        let imgPxW = backgroundImage.flatMap { $0.cgImage.map { Double($0.width) } }
        let imgPxH = backgroundImage.flatMap { $0.cgImage.map { Double($0.height) } }
        let drawingB64 = pencilDrawingData?.base64EncodedString()
        let doc = AnnotationDocument(version: 2,
                                     canvasWidth: Double(bounds.width),
                                     canvasHeight: Double(bounds.height),
                                     imagePixelWidth: imgPxW,
                                     imagePixelHeight: imgPxH,
                                     imageBase64: imgB64,
                                     pencilDrawingBase64: drawingB64,
                                     pencilDrawingNormalizedToImageSpace: pencilDrawingNormalizedToImageSpace,
                                     items: codableItems)
        return try? JSONEncoder().encode(doc)
    }

    @discardableResult
    public func loadDocument(_ data: Data) -> (UIImage?, Data?) {
        guard let doc = try? JSONDecoder().decode(AnnotationDocument.self, from: data) else { return (nil, nil) }
        items = doc.items.compactMap { ci -> AnnotationItem? in
            guard let tool = toolFromString(ci.tool) else { return nil }
            let color: UIColor = ci.color.count == 4
                ? UIColor(red: CGFloat(ci.color[0]), green: CGFloat(ci.color[1]),
                          blue: CGFloat(ci.color[2]), alpha: CGFloat(ci.color[3]))
                : .systemRed
            let pts = ci.points.map { p -> CGPoint in
                guard let x = p.x, let y = p.y else { return CGPoint(x: CGFloat.infinity, y: CGFloat.infinity) }
                return CGPoint(x: x, y: y)
            }
            let overlayImg = ci.overlayImageBase64
                .flatMap { Data(base64Encoded: $0) }
                .flatMap { UIImage(data: $0) }
            let bgColor: UIColor? = ci.backgroundColor.flatMap { bg -> UIColor? in
                guard bg.count == 4 else { return nil }
                return UIColor(red: CGFloat(bg[0]), green: CGFloat(bg[1]), blue: CGFloat(bg[2]), alpha: CGFloat(bg[3]))
            }
            return AnnotationItem(tool: tool, color: color, lineWidth: CGFloat(ci.lineWidth),
                                  points: pts, number: ci.number, text: ci.text,
                                  fontSize: CGFloat(ci.fontSize), fontName: ci.fontName,
                                  textWidth: ci.textWidth.map { CGFloat($0) },
                                  opacity: CGFloat(ci.opacity), overlayImage: overlayImg,
                                  cornerRadius: CGFloat(ci.cornerRadius ?? 0),
                                  backgroundColor: bgColor)
        }

        // Remap coordinates when loading on a different canvas size
        if let savedCW = doc.canvasWidth, let savedCH = doc.canvasHeight,
           let imgPxW = doc.imagePixelWidth, let imgPxH = doc.imagePixelHeight,
           savedCW > 0, savedCH > 0, imgPxW > 0, imgPxH > 0,
           bounds.width > 0, bounds.height > 0 {
            let imgSize = CGSize(width: imgPxW, height: imgPxH)
            let oldFit = fitRectFor(imageSize: imgSize, in: CGSize(width: savedCW, height: savedCH))
            let newFit = fitRectFor(imageSize: imgSize, in: bounds.size)
            items = items.map { item in
                var copy = item
                copy.points = item.points.map { pt in
                    guard !pt.x.isInfinite else { return pt }
                    let rx = (pt.x - oldFit.origin.x) / oldFit.width
                    let ry = (pt.y - oldFit.origin.y) / oldFit.height
                    return CGPoint(x: rx * newFit.width + newFit.origin.x,
                                   y: ry * newFit.height + newFit.origin.y)
                }
                if item.tool == .text, let width = item.textWidth {
                    copy.textWidth = width * (newFit.width / oldFit.width)
                }
                return copy
            }
        }

        selectedItemIndex = nil
        activeFreehandStrokeIndex = nil
        setNeedsDisplay()
        let image = doc.imageBase64
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { UIImage(data: $0) }
        let pencilData = doc.pencilDrawingBase64.flatMap { Data(base64Encoded: $0) }
            .flatMap { data in
                if doc.pencilDrawingNormalizedToImageSpace == true {
                    return remappedPencilDrawingDataFromImageSpace(data, from: doc, to: bounds.size)
                }
                return remappedPencilDrawingData(data, from: doc, to: bounds.size)
            }
        return (image, pencilData)
    }

    private func remappedPencilDrawingData(_ data: Data, from doc: AnnotationDocument, to canvasSize: CGSize) -> Data? {
        guard let savedCW = doc.canvasWidth, let savedCH = doc.canvasHeight,
              let imgPxW = doc.imagePixelWidth, let imgPxH = doc.imagePixelHeight,
              savedCW > 0, savedCH > 0, imgPxW > 0, imgPxH > 0,
              canvasSize.width > 0, canvasSize.height > 0,
              let drawing = try? PKDrawing(data: data)
        else { return data }

        let imgSize = CGSize(width: imgPxW, height: imgPxH)
        let oldFit = fitRectFor(imageSize: imgSize, in: CGSize(width: savedCW, height: savedCH))
        let newFit = fitRectFor(imageSize: imgSize, in: canvasSize)
        guard oldFit.width > 0.001, oldFit.height > 0.001 else { return data }

        let scaleX = newFit.width / oldFit.width
        let scaleY = newFit.height / oldFit.height
        let transform = CGAffineTransform(
            a: scaleX, b: 0,
            c: 0, d: scaleY,
            tx: newFit.origin.x - oldFit.origin.x * scaleX,
            ty: newFit.origin.y - oldFit.origin.y * scaleY
        )
        return drawing.transformed(using: transform).dataRepresentation()
    }

    private func remappedPencilDrawingDataFromImageSpace(_ data: Data, from doc: AnnotationDocument, to canvasSize: CGSize) -> Data? {
        guard let imgPxW = doc.imagePixelWidth, let imgPxH = doc.imagePixelHeight,
              imgPxW > 0, imgPxH > 0,
              canvasSize.width > 0, canvasSize.height > 0,
              let drawing = try? PKDrawing(data: data)
        else { return data }

        let imgSize = CGSize(width: imgPxW, height: imgPxH)
        let fit = fitRectFor(imageSize: imgSize, in: canvasSize)
        guard fit.width > 0.001, fit.height > 0.001 else { return data }

        let scaleX = fit.width / imgSize.width
        let scaleY = fit.height / imgSize.height
        let transform = CGAffineTransform(
            a: scaleX, b: 0,
            c: 0, d: scaleY,
            tx: fit.origin.x,
            ty: fit.origin.y
        )
        return drawing.transformed(using: transform).dataRepresentation()
    }

    private func fitRectFor(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        let ia = imageSize.width / imageSize.height
        let va = viewSize.width  / viewSize.height
        var r = CGRect.zero
        if ia > va {
            r.size.width  = viewSize.width
            r.size.height = viewSize.width / ia
            r.origin.y    = (viewSize.height - r.size.height) / 2
        } else {
            r.size.height = viewSize.height
            r.size.width  = viewSize.height * ia
            r.origin.x    = (viewSize.width - r.size.width) / 2
        }
        return r
    }

    private func toolToString(_ t: AnnotationTool) -> String {
        switch t {
        case .select: return "select"
        case .arrow: return "arrow"
        case .line: return "line"
        case .circle: return "circle"
        case .freehand: return "freehand"
        case .highlighter: return "highlighter"
        case .rectangle: return "rectangle"
        case .filledCircle: return "filledCircle"
        case .filledRect: return "filledRect"
        case .number: return "number"
        case .text: return "text"
        case .image: return "image"
        case .paintBackground: return "paintBackground"
        }
    }

    private func toolFromString(_ s: String) -> AnnotationTool? {
        switch s {
        case "select": return .select
        case "arrow": return .arrow
        case "line": return .line
        case "circle": return .circle
        case "freehand": return .freehand
        case "highlighter": return .highlighter
        case "rectangle": return .rectangle
        case "filledCircle": return .filledCircle
        case "filledRect": return .filledRect
        case "number": return .number
        case "text": return .text
        case "image": return .image
        default: return nil
        }
    }
}

// MARK: - Context menu

extension AnnotationCanvasView: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                       configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let idx = hitTestAnyItem(at: location) ?? hitTestTextItem(at: location)
        guard let idx else { return nil }
        selectedItemIndex = idx; setNeedsDisplay()
        #if targetEnvironment(macCatalyst)
        if onContextMenuMac?(idx, location) == true { return nil }
        #endif
        return onContextMenu?(idx)
    }
}
