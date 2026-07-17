//  ShakeDetector.swift
import SwiftUI

/// Reports device-shake gestures to SwiftUI. Backed by a first-responder view controller
/// so it only observes shakes while its host view is on screen — which, because RootView
/// mounts one tab body at a time, means shakes are seen only on the tab that uses it.
private struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let controller = ShakeViewController()
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ controller: ShakeViewController, context: Context) {
        controller.onShake = onShake
    }
}

final class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resignFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
        super.motionEnded(motion, with: event)
    }
}

extension View {
    /// Runs `action` when the device is shaken while this view is on screen.
    func onShake(perform action: @escaping () -> Void) -> some View {
        background(ShakeDetector(onShake: action).frame(width: 0, height: 0))
    }
}
