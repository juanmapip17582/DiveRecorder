import CoreGraphics

extension CGRect {
    /// Converts a UIKit-style normalized rect (origin top-left, y down — how ROIs are drawn
    /// on screen and stored in `CalibrationSettings`) into Vision's normalized coordinate
    /// space (origin bottom-left, y up), as expected by `VNImageBasedRequest.regionOfInterest`.
    var visionNormalized: CGRect {
        CGRect(x: minX, y: 1 - maxY, width: width, height: height)
    }
}

extension CGRect {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// This rect clipped to the normalized 0...1 square. Returns `nil` if nothing usable is left
    /// (fully outside, or thinner than `minSide`) so callers can fall back to a default ROI —
    /// Vision rejects a `regionOfInterest` that isn't inside the unit square.
    func clampedToUnit(minSide: CGFloat = 0.02) -> CGRect? {
        let standardized = self.standardized
        guard standardized.minX.isFinite, standardized.minY.isFinite,
              standardized.width.isFinite, standardized.height.isFinite else { return nil }
        let clipped = standardized.intersection(.unit)
        guard !clipped.isNull, clipped.width >= minSide, clipped.height >= minSide else { return nil }
        return clipped
    }
}
