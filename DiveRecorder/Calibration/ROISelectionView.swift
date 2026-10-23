import SwiftUI

/// Drag-to-draw rectangle overlay for defining a ROI on top of the live camera preview.
/// `roi` is normalized (0...1, origin top-left) relative to the view's own bounds.
struct ROISelectionView: View {
    let title: String
    @Binding var roi: CGRect
    let overlayColor: Color

    @State private var dragStart: CGPoint?
    @State private var currentRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            let rect = displayRect(in: geo.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                Rectangle()
                    .stroke(overlayColor, lineWidth: 2)
                    .background(overlayColor.opacity(0.15))
                    .frame(width: max(0, rect.width), height: max(0, rect.height))
                    .position(x: rect.midX, y: rect.midY)

                VStack {
                    Text(title)
                        .font(.caption.bold())
                        .padding(6)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragStart == nil { dragStart = clamp(value.startLocation, to: geo.size) }
                        guard let start = dragStart else { return }
                        // Clamp the finger to the view so the ROI can never extend past the image.
                        let end = clamp(value.location, to: geo.size)
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
                        guard let drawn = currentRect, geo.size.width > 0, geo.size.height > 0 else { return }
                        let normalized = CGRect(
                            x: drawn.minX / geo.size.width,
                            y: drawn.minY / geo.size.height,
                            width: drawn.width / geo.size.width,
                            height: drawn.height / geo.size.height
                        )
                        // Too small/degenerate (e.g. a tap) → keep the previous ROI.
                        if let clamped = normalized.clampedToUnit() { roi = clamped }
                    }
            )
        }
    }

    private func clamp(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }

    private func displayRect(in size: CGSize) -> CGRect {
        if let currentRect { return currentRect }
        return CGRect(x: roi.minX * size.width, y: roi.minY * size.height, width: roi.width * size.width, height: roi.height * size.height)
    }
}
