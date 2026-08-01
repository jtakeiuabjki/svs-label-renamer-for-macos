import AppKit
import QuickLookUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let imageView = NSImageView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping ((any Error)?) -> Void
    ) {
        do {
            let data = try SVSPreviewRenderer.renderPreviewData(from: url)
            guard let image = NSImage(data: data) else {
                throw SVSPreviewError.encodingFailed
            }
            imageView.image = image
            handler(nil)
        } catch {
            handler(error)
        }
    }
}
