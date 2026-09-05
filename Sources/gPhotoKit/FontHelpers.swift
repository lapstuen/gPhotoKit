import UIKit
import CoreText

var fontCache: [String: CGFont] = [:]

func resolveFont(name: String, size: CGFloat) -> UIFont {
    switch name {
    case "bold":   return UIFont.boldSystemFont(ofSize: size)
    case "system": return UIFont.systemFont(ofSize: size)
    default:
        if let f = UIFont(name: name, size: size) { return f }
        if let cgFont = loadCGFont(name: name) {
            let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
            return ctFont as UIFont
        }
        return UIFont.systemFont(ofSize: size)
    }
}

func loadCGFont(name: String) -> CGFont? {
    if let cached = fontCache[name] { return cached }
    guard let url = Bundle.module.url(forResource: name, withExtension: "ttf"),
          let data = try? Data(contentsOf: url),
          let provider = CGDataProvider(data: data as CFData),
          let font = CGFont(provider) else { return nil }
    fontCache[name] = font
    return font
}

public func registerFonts() {
    let names = [
        "NotoSansThai-Regular", "NotoSansThai-Bold",
        "Sarabun-Regular",      "Sarabun-Bold",
        "Kanit-Regular",        "Kanit-Bold",
        "Prompt-Regular"
    ]
    for name in names {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else {
            print("❌ Font ikke funnet i bundle: \(name).ttf"); continue
        }
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider) else {
            print("❌ Kunne ikke laste font: \(name)"); continue
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(cgFont, &error) {
            print("✅ Font registrert: \(name)")
        } else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "ukjent"
            print("⚠️ Font allerede registrert eller feil: \(name) – \(desc)")
        }
    }
}
