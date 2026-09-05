import SwiftUI
import UIKit

public struct ImageAnnotationWrapper: UIViewControllerRepresentable {
    public var image: UIImage
    public var onSave: (UIImage) -> Void
    public var projectURL: URL?
    public var onDismiss: (() -> Void)?

    public init(image: UIImage, projectURL: URL? = nil, onDismiss: (() -> Void)? = nil, onSave: @escaping (UIImage) -> Void) {
        self.image = image
        self.projectURL = projectURL
        self.onDismiss = onDismiss
        self.onSave = onSave
    }

    public func makeUIViewController(context: Context) -> ImageAnnotationViewController {
        let vc = ImageAnnotationViewController()
        vc.sourceImage = image
        vc.onSave = { edited in onSave(edited) }
        vc.onCancel = { onDismiss?() }
        vc.initialProjectURL = projectURL
        return vc
    }

    public func updateUIViewController(_ uiViewController: ImageAnnotationViewController, context: Context) {}
}
