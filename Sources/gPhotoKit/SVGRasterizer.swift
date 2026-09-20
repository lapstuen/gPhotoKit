//
//  SVGRasterizer.swift
//  gPhotoKit
//
//  Port av gPhotoMac sin SVGRasterizer.swift. Rendrer SVG-tekst til et vanlig
//  bitmap-bilde — UIKit/ImageIO støtter ikke SVG (UIImage(data:) returnerer
//  nil for SVG-XML), så vi bruker WKWebView — samme rendringsmotor som
//  Safari — og tar et snapshot av resultatet. Brukes for VILKÅRLIG SVG
//  (biblioteks-klistremerker, innsatte filer) — helt uavhengig av
//  `SVGExporter`, som kun leser/skriver appens EGNE annotasjon-SVG-er.
//

import UIKit
import WebKit

public enum SVGRasterizer {
    /// Rendrer `svgText` til et `UIImage`. Kalles på hovedtråden, svarer på
    /// hovedtråden. `nil` i callback betyr at SVG-en ikke kunne lastes.
    public static func render(svgText: String, completion: @escaping (UIImage?) -> Void) {
        let size = intrinsicSize(from: svgText)
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:0;background:transparent;}
        svg{display:block;width:\(Int(size.width))px;height:\(Int(size.height))px;}</style>
        </head><body>\(svgText)</body></html>
        """
        _ = SVGRasterizerJob(html: html, size: size, completion: completion)
    }

    /// Leser `viewBox`/`width`+`height` fra SVG-teksten for å vite hvor stort
    /// bildet skal rendres. Faller tilbake til en fornuftig standardstørrelse.
    /// Små grafikker skaleres opp for skarphet; svært store caps for å unngå
    /// et absurd stort lerret.
    private static func intrinsicSize(from svg: String) -> CGSize {
        let natural = viewBoxSize(from: svg) ?? explicitSize(from: svg) ?? CGSize(width: 1024, height: 768)
        var size = natural
        if max(size.width, size.height) <= 1200 {
            size = CGSize(width: size.width * 2, height: size.height * 2)
        }
        let maxEdge: CGFloat = 3000
        if max(size.width, size.height) > maxEdge {
            let scale = maxEdge / max(size.width, size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        return size
    }

    private static func viewBoxSize(from svg: String) -> CGSize? {
        let pattern = "viewBox\\s*=\\s*\"([^\"]+)\""
        guard let range = svg.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(svg[range])
        guard let quoted = match.split(separator: "\"").dropFirst().first else { return nil }
        let parts = quoted.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return CGSize(width: parts[2], height: parts[3])
    }

    private static func explicitSize(from svg: String) -> CGSize? {
        guard let w = attribute("width", in: svg), let h = attribute("height", in: svg) else { return nil }
        return CGSize(width: w, height: h)
    }

    private static func attribute(_ name: String, in svg: String) -> Double? {
        let pattern = "\(name)\\s*=\\s*\"([\\d.]+)"
        guard let range = svg.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(svg[range])
        guard let value = match.split(separator: "\"").last else { return nil }
        return Double(value)
    }
}

/// Eier én WKWebView gjennom lastingen og snapshot-kallet, og holder seg selv
/// i live til jobben er ferdig (ingen andre holder en referanse til den).
private final class SVGRasterizerJob: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private let completion: (UIImage?) -> Void
    private var selfRetain: SVGRasterizerJob?

    init(html: String, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        super.init()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = self
        self.webView = webView
        selfRetain = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: webView.frame.size)
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            self?.finish(image)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ image: UIImage?) {
        completion(image)
        webView = nil
        selfRetain = nil
    }
}
