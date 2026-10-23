import SwiftUI
import AVFoundation

/// Live camera preview for `CaptureManager`'s session, backed by its own
/// `AVCaptureVideoPreviewLayer`.
///
/// Use exactly ONE of these, kept mounted for the app's lifetime (ContentView's). Connecting a
/// second preview layer to the same session (as Calibration used to) blocks the main thread
/// for seconds while AVFoundation reconfigures, interrupts the session, and detaches the
/// first layer — measured at ~9 s with `previewLayer.session` going nil on the main layer.
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
