//  ShareViewController.swift
//  OndaShareExtension — no UI, no heavy work: grab the shared URL, queue it for the
//  main app (which does extraction + TTS on next foreground), and dismiss.
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        handleShare()
    }

    private func handleShare() {
        let providers = ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
            .flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) else {
            complete()
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
            if let url = item as? URL, let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                PendingArticlesQueue.standard.append(url)
            }
            DispatchQueue.main.async { self?.complete() }
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
