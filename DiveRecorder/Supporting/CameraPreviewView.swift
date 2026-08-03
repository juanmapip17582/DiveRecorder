import SwiftUI
import AVFoundation

/// Hosts `CaptureManager`'s single shared `AVCaptureVideoPreviewLayer`, reparenting it as a
/// sublayer into whichever `CameraPreviewView` is currently on screen (the recording screen, or
/// Calibration's own live preview while its sheet is open).
///
/// This used to be one independent `AVCaptureVideoPreviewLayer` per screen. That caused two
/// problems: opening Calibration created a brand-new layer and negotiated a brand-new
/// AVFoundation connection to the running session every time, which is the several-seconds
/// delay reported when opening it; and closing Calibration left the recording screen's own
/// preview layer as it always was — but nothing ever explicitly re-confirmed it was still
/// attached, and it could end up black until a full relaunch. Reusing one already-connected
/// layer makes switching between screens an instant CALayer reparent (no new connection), and
/// `attach(_:)` re-claims it from scratch (checking the actual current superlayer, not a cached
/// assumption) every time either screen's view appears — so the recording screen reliably gets
/// it back when Calibration's sheet closes.
struct CameraPreviewView: UIViewRepresentable {
    let captureManager: CaptureManager

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.attach(captureManager.previewLayer)
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.attach(captureManager.previewLayer)
    }

    final class HostView: UIView {
        private weak var hostedLayer: AVCaptureVideoPreviewLayer?

        func attach(_ previewLayer: AVCaptureVideoPreviewLayer) {
            if previewLayer.superlayer !== layer {
                previewLayer.removeFromSuperlayer()
                layer.addSublayer(previewLayer)
            }
            hostedLayer = previewLayer
            previewLayer.frame = bounds
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
