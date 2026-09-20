import UIKit
import Vision
import CoreImage

public enum ObjectLibrary {

    public static let uncategorizedCategory = "Uten kategori"
    private static let rootFolderName = "gPhotoObjects"
    /// Filtyper som vises i biblioteket. SVG er ekte vektorgrafikk (rastreres
    /// ved innsetting, se ImageAnnotationViewController), ikke bare et bilde.
    private static let displayableExtensions: Set<String> = ["png", "svg"]

    public static var folder: URL {
        if let icloud = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.no.1955.gPhoto") {
            let dir = icloud.appendingPathComponent("Documents/\(rootFolderName)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(rootFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func categories() -> [String] {
        var categories: [String] = [uncategorizedCategory]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return categories }

        for url in items where url.hasDirectoryPath {
            guard hasPNGFiles(in: url) else { continue }
            categories.append(url.lastPathComponent)
        }

        return categories.sorted {
            if $0 == uncategorizedCategory { return true }
            if $1 == uncategorizedCategory { return false }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public static func all() -> [(name: String, url: URL)] {
        all(in: nil)
    }

    public static func all(in category: String?) -> [(name: String, url: URL)] {
        let urls = urlsForCategory(category)
        return urls
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
    }

    @discardableResult
    public static func save(_ image: UIImage, in category: String? = nil) throws -> URL {
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        let destinationDirectory = directory(for: category)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let baseName = "obj_\(formatter.string(from: Date()))"
        let url = destinationDirectory.appendingPathComponent(uniqueFileName(baseName: baseName, in: destinationDirectory))
        try data.write(to: url)
        return url
    }

    public static func delete(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Flytter et eksisterende objekt til en (eventuelt ny) katalog. Katalogen
    /// opprettes automatisk hvis den ikke finnes fra før (samme som `save`).
    @discardableResult
    public static func move(url: URL, to category: String?) -> URL? {
        let destDir = directory(for: category)
        let baseName = url.deletingPathExtension().lastPathComponent
        let destURL = destDir.appendingPathComponent(uniqueFileName(baseName: baseName, ext: url.pathExtension, in: destDir))
        guard destURL != url else { return url }
        guard (try? FileManager.default.moveItem(at: url, to: destURL)) != nil else { return nil }
        return destURL
    }

    /// Overskriver et eksisterende objekt i biblioteket med nytt bildeinnhold
    /// (samme filnavn/plassering/kategori). Brukes til å beskjære et
    /// objekt direkte i biblioteket, uten å måtte legge det inn i et bilde
    /// først for å trimme det via kontekstmenyen der.
    @discardableResult
    public static func overwrite(url: URL, with image: UIImage) -> Bool {
        guard let data = image.pngData() else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func removeBackground(from image: UIImage, completion: @escaping (UIImage?) -> Void) {
        guard #available(iOS 17.0, *) else { completion(nil); return }
        guard let cgImage = image.cgImage else { completion(nil); return }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
                guard let result = request.results?.first,
                      let maskBuffer = try? result.generateScaledMaskForImage(
                          forInstances: result.allInstances, from: handler) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let masked = applyMask(maskBuffer, to: cgImage)
                DispatchQueue.main.async { completion(masked) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    private static func directory(for category: String?) -> URL {
        guard let category = normalizedCategoryName(category) else { return folder }
        let dir = folder.appendingPathComponent(category, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func normalizedCategoryName(_ category: String?) -> String? {
        guard let category = category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty else {
            return nil
        }
        if category == uncategorizedCategory {
            return nil
        }
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let cleaned = category.components(separatedBy: forbidden).joined(separator: "-")
        let collapsed = cleaned
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func urlsForCategory(_ category: String?) -> [URL] {
        if category == uncategorizedCategory {
            return pngFiles(in: folder)
        }
        if let category = normalizedCategoryName(category) {
            return pngFiles(in: folder.appendingPathComponent(category, isDirectory: true))
        }

        var urls = pngFiles(in: folder)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return urls }

        for url in items where url.hasDirectoryPath {
            urls.append(contentsOf: pngFiles(in: url))
        }
        return urls
    }

    private static func pngFiles(in directory: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return items.filter { displayableExtensions.contains($0.pathExtension.lowercased()) }
    }

    private static func hasPNGFiles(in directory: URL) -> Bool {
        !pngFiles(in: directory).isEmpty
    }

    private static func uniqueFileName(baseName: String, ext: String = "png", in directory: URL) -> String {
        let fm = FileManager.default
        var candidate = "\(baseName).\(ext)"
        var counter = 1
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(baseName)_\(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private static func applyMask(_ maskBuffer: CVPixelBuffer, to cgImage: CGImage) -> UIImage? {
        let maskCI  = CIImage(cvPixelBuffer: maskBuffer)
        let imageCI = CIImage(cgImage: cgImage)
        let output  = imageCI.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": CIImage.empty(),
            "inputMaskImage": maskCI
        ])
        guard let result = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: result)
    }

    /// Crops away empty (transparent or near-white) borders, returning the tight bounding box of actual content.
    public static func trimToContent(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width  = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow   = bytesPerPixel * width
        var pixels        = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Detect whether the image actually uses transparency
        var hasTransparency = false
        outer: for y in 0..<height {
            for x in 0..<width {
                if pixels[(y * width + x) * bytesPerPixel + 3] < 255 {
                    hasTransparency = true
                    break outer
                }
            }
        }

        var minX = width, minY = height, maxX = 0, maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let base  = (y * width + x) * bytesPerPixel
                let r = pixels[base], g = pixels[base + 1], b = pixels[base + 2], a = pixels[base + 3]
                let isContent: Bool
                if hasTransparency {
                    isContent = a > 10
                } else {
                    // Trim near-white background
                    isContent = !(r > 240 && g > 240 && b > 240)
                }
                if isContent {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }

        let cropRect = CGRect(x: minX, y: minY,
                              width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
