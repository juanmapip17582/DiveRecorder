import Vision
import CoreGraphics
import ImageIO

struct DetectedPose {
    /// Normalized bounding box in Vision's coordinate space (origin bottom-left, y up).
    let boundingBox: CGRect
    let hip: CGPoint?
    let knee: CGPoint?
    let ankle: CGPoint?
    let confidence: Float
}

/// Wraps `VNDetectHumanBodyPoseRequest`, restricted to a region of interest (the calibrated
/// trampoline/platform ROI) so it ignores people elsewhere in frame — teammates waiting their
/// turn, coaches, spectators.
final class PoseDetector {
    func detectPoses(in pixelBuffer: CVPixelBuffer, roi: CGRect, orientation: CGImagePropertyOrientation) -> [DetectedPose] {
        let request = VNDetectHumanBodyPoseRequest()
        request.regionOfInterest = roi

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        return observations.compactMap { observation -> DetectedPose? in
            guard let points = try? observation.recognizedPoints(.all), !points.isEmpty else { return nil }

            func point(_ name: VNHumanBodyPoseObservation.JointName, minConfidence: Float = 0.3) -> CGPoint? {
                guard let p = points[name], p.confidence >= minConfidence else { return nil }
                return CGPoint(x: p.location.x, y: p.location.y)
            }

            let hip = averagePoint(point(.leftHip), point(.rightHip))
            let knee = averagePoint(point(.leftKnee), point(.rightKnee))
            let ankle = averagePoint(point(.leftAnkle), point(.rightAnkle))

            let visible = points.values.filter { $0.confidence >= 0.3 }
            guard !visible.isEmpty else { return nil }
            let xs = visible.map { $0.location.x }
            let ys = visible.map { $0.location.y }
            let boundingBox = CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            )

            return DetectedPose(boundingBox: boundingBox, hip: hip, knee: knee, ankle: ankle, confidence: observation.confidence)
        }
    }

    /// Heuristic for a "standing / ready" posture: hip above knee above ankle in image space
    /// (Vision y increases upward) with a reasonably extended leg — an upright standing body,
    /// not crouched, seated, or mid-motion. This is what triggers STANDBY -> IDENTIFICANDO.
    func isStandingPose(_ pose: DetectedPose) -> Bool {
        guard let hip = pose.hip, let knee = pose.knee, let ankle = pose.ankle else { return false }
        let isVerticallyOrdered = hip.y > knee.y && knee.y > ankle.y
        let hipKneeDelta = hip.y - knee.y
        let kneeAnkleDelta = knee.y - ankle.y
        let isExtended = hipKneeDelta > 0.04 && kneeAnkleDelta > 0.04
        return isVerticallyOrdered && isExtended
    }

    private func averagePoint(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
        switch (a, b) {
        case let (a?, b?): return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}
