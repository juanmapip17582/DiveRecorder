import CoreGraphics

extension CGRect {
    /// Converts a UIKit-style normalized rect (origin top-left, y down — how ROIs are drawn
    /// on screen and stored in `CalibrationSettings`) into Vision's normalized coordinate
    /// space (origin bottom-left, y up), as expected by `VNImageBasedRequest.regionOfInterest`.
    var visionNormalized: CGRect {
        CGRect(x: minX, y: 1 - maxY, width: width, height: height)
    }
}
