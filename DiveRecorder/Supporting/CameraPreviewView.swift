import SwiftUI
import AVFoundation

/// Live camera preview for `CaptureManager`'s session. Each instance owns its own
/// `AVCaptureVideoPreviewLayer` (as the backing layer of its host view) connected to the same
/// shared `AVCaptureSession` — the standard, cheap way to show one session in several places.
///
/// This used to reparent a single shared preview layer between screens, but SwiftUI doesn't
/// call `updateUIView` when a sheet/cover closes (the `captureManager` reference is unchanged),
/// so the layer stayed in the dismissed Calibration view and the main screen went black.
struct CameraPreviewView: UIViewRepresentable {
    let captureManager: CaptureManager

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = captureManager.session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== captureManager.session {
            uiView.previewLayer.session = captureManager.session
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
