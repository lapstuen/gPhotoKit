//
//  SVGExporter.swift
//  gPhotoKit
//
//  Port av gPhotoMac sin SVGExporter.swift (samme fil, samme format) —
//  bygger en ekte, redigerbar SVG-fil av annotasjonene i et prosjekt. I
//  motsetning til `.gphoto`-prosjektfila inneholder denne verken
//  bakgrunnsbildet eller innsatte bilder (`.image`/`.paintBackground`), kun
//  de faktiske tegnede formene/strekene. Geometrien speiler nøyaktig
//  `AnnotationCanvasView.renderItem(_:in:)` — lerretet bruker allerede et
//  y-ned koordinatsystem som er identisk med SVG sitt, så punktene kan
//  brukes rett av, uten noen koordinat-transform.
//

import UIKit

public enum SVGExporter {
    public static func encode(items: [AnnotationItem], canvasSize: CGSize) -> String {
        var body = ""
        for item in items {
            let inner: String
            switch item.tool {
            case .select, .image, .paintBackground:
                continue
            case .freehand, .highlighter:
                inner = freehandElement(item)
            case .circle:
                inner = circleElement(item)
            case .arrow:
                inner = arrowElement(item)
            case .line:
                inner = lineElement(item)
            case .rectangle:
                inner = rectangleElement(item)
            case .number:
                inner = numberElement(item)
            case .text:
                inner = textElement(item, canvasWidth: canvasSize.width)
            case .polygon:
                inner = polygonElement(item)
            }
            guard !inner.isEmpty else { continue }
            // Hvert element pakkes i en <g> med data-*-attributter som beskriver
            // hele AnnotationItem-et — slik kan "Last inn SVG…" lese filen tilbake
            // eksakt, i stedet for å måtte gjette tool-type fra rå SVG-geometri
            // (som f.eks. ikke kan skille en enkelt linje fra de tre linjene som
            // utgjør en pil). data-* er inert metadata; filen forblir en helt
            // vanlig, visbar SVG i alle andre programmer.
            body += "<g \(metadataAttributes(for: item))>\n\(inner)</g>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(fmt(canvasSize.width))" height="\(fmt(canvasSize.height))" viewBox="0 0 \(fmt(canvasSize.width)) \(fmt(canvasSize.height))" data-gphoto-fill-model="unified">
        \(body)</svg>
        """
    }

    /// Leser en SVG-fil skrevet av `encode(items:canvasSize:)` tilbake til
    /// `AnnotationItem`-er, ved å lese `data-*`-attributtene på hver `<g>` —
    /// ikke ved å tolke selve tegne-geometrien. En SVG som ikke kommer fra
    /// denne eksportøren (ingen `data-tool`-attributter) gir tom liste.
    public static func decode(svgText: String) -> [AnnotationItem] {
        let delegate = ItemParserDelegate()
        guard let data = svgText.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// Eldre SVG-er (før sirkel/rektangel/polygon fikk justerbar fyllingsgrad på
    /// det samlede verktøyet) kan ha "filledCircle"/"filledRect"/"filledPolygon"
    /// i data-tool — mappes til det sammenslåtte verktøyet her.
    private static func migrateLegacyTool(_ raw: String) -> AnnotationTool? {
        switch raw {
        case "filledCircle": return .circle
        case "filledRect": return .rectangle
        case "filledPolygon": return .polygon
        default: return AnnotationTool(rawValue: raw)
        }
    }

    /// En gammel IKKE-fylt sirkel/rektangel/polygon skal ha fyllingsgrad 0
    /// uansett hva som tilfeldigvis lå lagret i data-opacity (det ble aldri
    /// brukt til noe for dem før nå).
    private static func legacyToolForcesZeroOpacity(_ raw: String) -> Bool {
        raw == "circle" || raw == "rectangle" || raw == "polygon"
    }

    private final class ItemParserDelegate: NSObject, XMLParserDelegate {
        var items: [AnnotationItem] = []
        // Antas gammelt (fyllingsgrad-tvang aktiv) helt til rot-<svg>-elementet
        // beviser at fila kommer fra det nye, sammenslåtte formatet — se
        // `data-gphoto-fill-model` skrevet av `encode(items:canvasSize:)`.
        private var isLegacyDocument = true

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "svg" {
                isLegacyDocument = attributeDict["data-gphoto-fill-model"] != "unified"
                return
            }
            guard elementName == "g",
                  let toolRaw = attributeDict["data-tool"],
                  let tool = SVGExporter.migrateLegacyTool(toolRaw) else { return }

            let color = SVGExporter.color(fromHex: attributeDict["data-color"] ?? "#FF0000",
                                          alpha: CGFloat(Double(attributeDict["data-color-alpha"] ?? "1") ?? 1))
            let lineWidth = CGFloat(Double(attributeDict["data-line-width"] ?? "0") ?? 0)
            let rawOpacity = CGFloat(Double(attributeDict["data-opacity"] ?? "1") ?? 1)
            let opacity = (isLegacyDocument && SVGExporter.legacyToolForcesZeroOpacity(toolRaw)) ? 0 : rawOpacity
            let cornerRadius = CGFloat(Double(attributeDict["data-corner-radius"] ?? "0") ?? 0)
            let points = SVGExporter.decodePoints(attributeDict["data-points"] ?? "")

            var number = 0
            var text = ""
            var fontSize: CGFloat = 32
            var fontName = "bold"
            var textWidth: CGFloat?
            var backgroundColor: UIColor?
            var sides = 5
            var isStar = false

            if tool == .number {
                number = Int(attributeDict["data-number"] ?? "0") ?? 0
            }
            if tool == .polygon {
                sides = Int(attributeDict["data-sides"] ?? "5") ?? 5
                isStar = attributeDict["data-star"] == "true"
            }
            if tool == .text {
                text = SVGExporter.decodeText(attributeDict["data-text"] ?? "")
                fontSize = CGFloat(Double(attributeDict["data-font-size"] ?? "32") ?? 32)
                fontName = attributeDict["data-font-name"] ?? "bold"
                if let w = attributeDict["data-text-width"] { textWidth = CGFloat(Double(w) ?? 0) }
                if let bgHex = attributeDict["data-background-color"] {
                    let bgAlpha = CGFloat(Double(attributeDict["data-background-alpha"] ?? "1") ?? 1)
                    backgroundColor = SVGExporter.color(fromHex: bgHex, alpha: bgAlpha)
                }
            }

            items.append(AnnotationItem(tool: tool, color: color, lineWidth: lineWidth, points: points,
                                        number: number, text: text, fontSize: fontSize, fontName: fontName,
                                        textWidth: textWidth, opacity: opacity, overlayImage: nil,
                                        cornerRadius: cornerRadius, backgroundColor: backgroundColor,
                                        sides: sides, isStar: isStar))
        }
    }

    // MARK: - Per-verktøy elementer

    private static func freehandElement(_ item: AnnotationItem) -> String {
        var d = ""
        var penDown = false
        for pt in item.points {
            if pt.x.isInfinite { penDown = false; continue }
            d += penDown ? "L \(fmt(pt.x)) \(fmt(pt.y)) " : "M \(fmt(pt.x)) \(fmt(pt.y)) "
            penDown = true
        }
        guard !d.isEmpty else { return "" }
        let (strokeHex, strokeA) = hexAndAlpha(item.color)
        let isHighlighter = item.tool == .highlighter
        let cap = isHighlighter ? "square" : "round"
        let opacityAttr = isHighlighter ? " opacity=\"\(fmt(item.opacity))\"" : (strokeA < 1 ? " stroke-opacity=\"\(fmt(strokeA))\"" : "")
        return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(strokeHex)\" stroke-width=\"\(fmt(item.lineWidth))\" stroke-linecap=\"\(cap)\" stroke-linejoin=\"round\"\(opacityAttr)/>\n"
    }

    private static func circleElement(_ item: AnnotationItem) -> String {
        guard item.points.count == 2 else { return "" }
        let r = rectFromPoints(item.points[0], item.points[1])
        let (strokeHex, strokeA) = hexAndAlpha(item.color)
        let opacityAttr = strokeA < 1 ? " stroke-opacity=\"\(fmt(strokeA))\"" : ""
        let fillAttr = item.opacity > 0 ? " fill=\"\(strokeHex)\" fill-opacity=\"\(fmt(item.opacity))\"" : " fill=\"none\""
        return "<ellipse cx=\"\(fmt(r.midX))\" cy=\"\(fmt(r.midY))\" rx=\"\(fmt(r.width / 2))\" ry=\"\(fmt(r.height / 2))\"\(fillAttr) stroke=\"\(strokeHex)\" stroke-width=\"\(fmt(item.lineWidth))\"\(opacityAttr)/>\n"
    }

    private static func polygonElement(_ item: AnnotationItem) -> String {
        guard item.points.count == 2 else { return "" }
        let r = rectFromPoints(item.points[0], item.points[1])
        let verts = polygonVertices(in: r, sides: item.sides, isStar: item.isStar)
        guard !verts.isEmpty else { return "" }
        let pointsAttr = verts.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: " ")
        let (strokeHex, strokeA) = hexAndAlpha(item.color)
        let opacityAttr = strokeA < 1 ? " stroke-opacity=\"\(fmt(strokeA))\"" : ""
        let fillAttr = item.opacity > 0 ? " fill=\"\(strokeHex)\" fill-opacity=\"\(fmt(item.opacity))\"" : " fill=\"none\""
        return "<polygon points=\"\(pointsAttr)\"\(fillAttr) stroke=\"\(strokeHex)\" stroke-width=\"\(fmt(item.lineWidth))\"\(opacityAttr)/>\n"
    }

    private static func lineElement(_ item: AnnotationItem) -> String {
        guard item.points.count == 2 else { return "" }
        let (strokeHex, strokeA) = hexAndAlpha(item.color)
        let opacityAttr = strokeA < 1 ? " stroke-opacity=\"\(fmt(strokeA))\"" : ""
        return svgLine(item.points[0], item.points[1], strokeHex: strokeHex, lineWidth: item.lineWidth, opacityAttr: opacityAttr)
    }

    /// Samme vinkelberegning som `AnnotationCanvasView.renderArrow` — hovedlinje
    /// pluss to korte linjer for pilhodet.
    private static func arrowElement(_ item: AnnotationItem) -> String {
        guard item.points.count == 2 else { return "" }
        let start = item.points[0], end = item.points[1]
        let (strokeHex, strokeA) = hexAndAlpha(item.color)
        let opacityAttr = strokeA < 1 ? " stroke-opacity=\"\(fmt(strokeA))\"" : ""
        let angle: CGFloat = atan2(end.y - start.y, end.x - start.x)
        let hl: CGFloat = max(18, item.lineWidth * 5)
        let ha: CGFloat = .pi / 6
        let head1x: CGFloat = end.x - hl * cos(angle - ha)
        let head1y: CGFloat = end.y - hl * sin(angle - ha)
        let head2x: CGFloat = end.x - hl * cos(angle + ha)
        let head2y: CGFloat = end.y - hl * sin(angle + ha)
        let head1 = CGPoint(x: head1x, y: head1y)
        let head2 = CGPoint(x: head2x, y: head2y)
        return svgLine(start, end, strokeHex: strokeHex, lineWidth: item.lineWidth, opacityAttr: opacityAttr)
            + svgLine(end, head1, strokeHex: strokeHex, lineWidth: item.lineWidth, opacityAttr: opacityAttr)
            + svgLine(end, head2, strokeHex: strokeHex, lineWidth: item.lineWidth, opacityAttr: opacityAttr)
    }

    private static func svgLine(_ a: CGPoint, _ b: CGPoint, strokeHex: String, lineWidth: CGFloat, opacityAttr: String) -> String {
        "<line x1=\"\(fmt(a.x))\" y1=\"\(fmt(a.y))\" x2=\"\(fmt(b.x))\" y2=\"\(fmt(b.y))\" stroke=\"\(strokeHex)\" stroke-width=\"\(fmt(lineWidth))\" stroke-linecap=\"round\"\(opacityAttr)/>\n"
    }

    private static func rectangleElement(_ item: AnnotationItem) -> String {
        guard item.points.count == 2 else { return "" }
        let r = rectFromPoints(item.points[0], item.points[1])
        let (strokeHex, strokeA) = hexAndAlpha(item.color)
        let opacityAttr = strokeA < 1 ? " stroke-opacity=\"\(fmt(strokeA))\"" : ""
        let radiusAttr = item.cornerRadius > 0 ? " rx=\"\(fmt(item.cornerRadius))\" ry=\"\(fmt(item.cornerRadius))\"" : ""
        let fillAttr = item.opacity > 0 ? " fill=\"\(strokeHex)\" fill-opacity=\"\(fmt(item.opacity))\"" : " fill=\"none\""
        return "<rect x=\"\(fmt(r.minX))\" y=\"\(fmt(r.minY))\" width=\"\(fmt(r.width))\" height=\"\(fmt(r.height))\"\(radiusAttr)\(fillAttr) stroke=\"\(strokeHex)\" stroke-width=\"\(fmt(item.lineWidth))\"\(opacityAttr)/>\n"
    }

    private static func numberElement(_ item: AnnotationItem) -> String {
        guard item.points.count == 2 else { return "" }
        let r = rectFromPoints(item.points[0], item.points[1])
        let (fillHex, _) = hexAndAlpha(item.color)
        let fontSize = max(min(r.width, r.height) * 0.55, 10)
        return "<ellipse cx=\"\(fmt(r.midX))\" cy=\"\(fmt(r.midY))\" rx=\"\(fmt(r.width / 2))\" ry=\"\(fmt(r.height / 2))\" fill=\"\(fillHex)\" fill-opacity=\"\(fmt(item.opacity))\"/>\n"
            + "<text x=\"\(fmt(r.midX))\" y=\"\(fmt(r.midY))\" font-family=\"-apple-system, sans-serif\" font-weight=\"700\" font-size=\"\(fmt(fontSize))\" fill=\"#000000\" text-anchor=\"middle\" dominant-baseline=\"central\">\(item.number)</text>\n"
    }

    /// Ordbryter teksten selv (linje for linje, ord for ord etter bredde), siden
    /// SVG `<text>` ikke har noen innebygd tilsvarighet til UIKit sin
    /// automatiske word-wrap som brukes på lerretet.
    private static func textElement(_ item: AnnotationItem, canvasWidth: CGFloat) -> String {
        guard !item.text.isEmpty, let origin = item.points.first else { return "" }
        let font = resolveFont(name: item.fontName, size: item.fontSize)
        let maxWidth = resolvedTextWidth(for: item, canvasWidth: canvasWidth)
        let lines = item.text.components(separatedBy: "\n").flatMap { wrapLine($0, font: font, maxWidth: maxWidth) }
        let lineHeight = font.ascender - font.descender + font.leading
        let padding: CGFloat = 8
        let hasBackground = item.backgroundColor != nil
        let textX = origin.x + (hasBackground ? padding : 0)
        let textY = origin.y + (hasBackground ? padding : 0)

        var svg = ""
        if let bg = item.backgroundColor {
            let (bgHex, _) = hexAndAlpha(bg)
            let bgWidth = maxWidth + padding * 2
            let bgHeight = lineHeight * CGFloat(lines.count) + padding * 2
            svg += "<rect x=\"\(fmt(origin.x))\" y=\"\(fmt(origin.y))\" width=\"\(fmt(bgWidth))\" height=\"\(fmt(bgHeight))\" rx=\"6\" ry=\"6\" fill=\"\(bgHex)\" fill-opacity=\"\(fmt(item.opacity))\"/>\n"
        }
        let (textHex, textA) = hexAndAlpha(item.color)
        let opacityAttr = textA < 1 ? " fill-opacity=\"\(fmt(textA))\"" : ""
        let fontFamily = "-apple-system, sans-serif"
        let fontWeight = item.fontName == "bold" ? "700" : "400"
        for (i, line) in lines.enumerated() {
            let baselineY = textY + font.ascender + CGFloat(i) * lineHeight
            svg += "<text x=\"\(fmt(textX))\" y=\"\(fmt(baselineY))\" font-family=\"\(fontFamily)\" font-weight=\"\(fontWeight)\" font-size=\"\(fmt(item.fontSize))\" fill=\"\(textHex)\"\(opacityAttr)>\(xmlEscape(line))</text>\n"
        }
        return svg
    }

    private static func wrapLine(_ line: String, font: UIFont, maxWidth: CGFloat) -> [String] {
        guard !line.isEmpty else { return [""] }
        let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            let width = (candidate as NSString).size(withAttributes: [.font: font]).width
            if width > maxWidth, !current.isEmpty {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    // MARK: - data-*-metadata (for "Last inn SVG…", se decode(svgText:))

    private static func metadataAttributes(for item: AnnotationItem) -> String {
        let (colorHex, colorAlpha) = hexAndAlpha(item.color)
        var attrs = "data-tool=\"\(item.tool.rawValue)\""
            + " data-color=\"\(colorHex)\" data-color-alpha=\"\(fmt(colorAlpha))\""
            + " data-line-width=\"\(fmt(item.lineWidth))\" data-opacity=\"\(fmt(item.opacity))\""
            + " data-corner-radius=\"\(fmt(item.cornerRadius))\""
            + " data-points=\"\(xmlAttrEscape(encodePoints(item.points)))\""
        if item.tool == .number {
            attrs += " data-number=\"\(item.number)\""
        }
        if item.tool == .polygon {
            attrs += " data-sides=\"\(item.sides)\" data-star=\"\(item.isStar)\""
        }
        if item.tool == .text {
            attrs += " data-text=\"\(xmlAttrEscape(encodeText(item.text)))\""
                + " data-font-size=\"\(fmt(item.fontSize))\" data-font-name=\"\(xmlAttrEscape(item.fontName))\""
            if let w = item.textWidth {
                attrs += " data-text-width=\"\(fmt(w))\""
            }
            if let bg = item.backgroundColor {
                let (bgHex, bgAlpha) = hexAndAlpha(bg)
                attrs += " data-background-color=\"\(bgHex)\" data-background-alpha=\"\(fmt(bgAlpha))\""
            }
        }
        return attrs
    }

    /// `"x,y"`-par separert med mellomrom; `"u"` markerer penn-opp (frihånd/
    /// merkepenn kan ha flere separate strøk i samme item).
    private static func encodePoints(_ points: [CGPoint]) -> String {
        points.map { pt in
            pt.x.isInfinite ? "u" : "\(fmt(pt.x)),\(fmt(pt.y))"
        }.joined(separator: " ")
    }

    private static func decodePoints(_ s: String) -> [CGPoint] {
        s.split(separator: " ").map { token -> CGPoint in
            if token == "u" { return CGPoint(x: CGFloat.infinity, y: CGFloat.infinity) }
            let parts = token.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
                return CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
            }
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
    }

    /// XML-attributter kan ikke bære et bokstavelig linjeskift (normaliseres bort
    /// av XML-parsere), så flerlinjet tekst escapes til `\n`/`\\` her og pakkes ut igjen ved lasting.
    private static func encodeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func decodeText(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\", s.index(after: i) < s.endIndex {
                let next = s[s.index(after: i)]
                if next == "n" { result.append("\n"); i = s.index(i, offsetBy: 2); continue }
                if next == "\\" { result.append("\\"); i = s.index(i, offsetBy: 2); continue }
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
    }

    private static func color(fromHex hex: String, alpha: CGFloat) -> UIColor {
        var hexStr = hex
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }
        guard hexStr.count == 6, let rgb = UInt32(hexStr, radix: 16) else { return .systemRed }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    // MARK: - Hjelpere

    private static func rectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private static func hexAndAlpha(_ color: UIColor) -> (hex: String, alpha: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let hex = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        return (hex, a)
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func xmlAttrEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func fmt(_ v: CGFloat) -> String {
        String(format: "%.2f", v)
    }
}
