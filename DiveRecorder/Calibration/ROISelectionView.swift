import SwiftUI

/// Drag-to-draw rectangle overlay for defining a ROI on top of the live camera preview.
///
/// `roi` is normalized (0...1, origin top-left) relative to the *camera image*, not the view:
/// the preview uses aspect fill, so an image of `imageAspectRatio` (width / height) is scaled to
/// cover the whole view and cropped at the edges. This view reproduces that same mapping, so
/// it must be laid out with exactly the same frame as the `CameraPreviewView` underneath it
/// (both full screen, ignoring safe areas).
struct ROISelectionView: View {
    let title: String
    @Binding var roi: CGRect
    let overlayColor: Color
    let imageAspectRatio: CGFloat

    @State private var dragStart: CGPoint?
    @State private var currentRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let image = imageRect(in: geo.size)
            let rect = currentRect ?? viewRect(for: roi, image: image)

            ZStack(alignment: .topLeading) {
                Color.clear

                Rectangle()
                    .stroke(overlayColor, lineWidth: 2)
                    .background(overlayColor.opacity(0.15))
                    .frame(width: max(0, rect.width), height: max(0, rect.height))
                    .position(x: rect.midX, y: rect.midY)

                Text(title)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(overlayColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.black)
                    .offset(x: max(0, rect.minX), y: max(0, rect.minY - 20))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        // Clamp the finger to the visible part of the image so the ROI can
                        // never extend past it.
                        let visible = image.intersection(CGRect(origin: .zero, size: geo.size))
                        if dragStart == nil { dragStart = clamp(value.startLocation, to: visible) }
                        guard let start = dragStart else { return }
                        let end = clamp(value.location, to: visible)
                        currentRect = CGRect(
                            x: min(start.x, end.x),
                            y: min(start.y, end.y),
                            width: abs(end.x - start.x),
                            height: abs(end.y - start.y)
                        )
                    }
                    .onEnded { _ in
                        defer {
                            dragStart = nil
                            currentRect = nil
                        }
                        guard let drawn = currentRect, image.width > 0, image.height > 0 else { return }
                        let normalized = CGRect(
                            x: (drawn.minX - image.minX) / image.width,
                            y: (drawn.minY - image.minY) / image.height,
                            width: drawn.width / image.width,
                            height: drawn.height / image.height
                        )
                        // Too small/degenerate (e.g. a tap) → keep the previous ROI.
                        if let clamped = normalized.clampedToUnit() { roi = clamped }
                    }
            )
        }
    }

    /// Where the full camera image lands in a view of `size` with aspect fill (centered, may
    /// extend past the view's edges).
    private func imageRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, imageAspectRatio > 0 else { return .zero }
        let imageSize: CGSize
        if size.width / size.height > imageAspectRatio {
            imageSize = CGSize(width: size.width, height: size.width / imageAspectRatio)
        } else {
            imageSize = CGSize(width: size.height * imageAspectRatio, height: size.height)
        }
        return CGRect(
            x: (size.width - imageSize.width) / 2,
            y: (size.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private func viewRect(for normalized: CGRect, image: CGRect) -> CGRect {
        CGRect(
            x: image.minX + normalized.minX * image.width,
            y: image.minY + normalized.minY * image.height,
            width: normalized.width * image.width,
            height: normalized.height * image.height
        )
    }

    private func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}
