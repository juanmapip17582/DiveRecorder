import CoreVideo
import CoreGraphics

/// Identifies Juan Manuel by the color of his shorts: crops the torso-legs region using Vision's
/// hip/knee keypoints, builds an HSV hue histogram (robust to pool-lighting brightness shifts,
/// unlike raw RGB), and compares it against a calibrated reference histogram.
enum ColorMatcher {
    static let hueBinCount = 36 // 10-degree bins across the 0-360 hue wheel

    /// Pixel-space crop rect (origin top-left, matching CVPixelBuffer row order) around the
    /// torso-legs region, derived from Vision's normalized hip/knee keypoints (origin bottom-left).
    static func torsoLegsCropRect(hip: CGPoint, knee: CGPoint, imageWidth: Int, imageHeight: Int) -> CGRect {
        let midX = (hip.x + knee.x) / 2
        let topY = hip.y
        let bottomY = knee.y
        let normalizedWidth: CGFloat = 0.22

        let pixelX = (midX - normalizedWidth / 2) * CGFloat(imageWidth)
        let pixelTop = (1 - topY) * CGFloat(imageHeight)
        let pixelBottom = (1 - bottomY) * CGFloat(imageHeight)
        let pixelWidth = normalizedWidth * CGFloat(imageWidth)
        let pixelHeight = max(1, pixelBottom - pixelTop)

        let rect = CGRect(x: pixelX, y: pixelTop, width: pixelWidth, height: pixelHeight)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight))
        return rect.intersection(bounds)
    }

    /// Builds a normalized hue histogram for the given pixel-space crop rect. Samples every
    /// other pixel and skips near-grayscale / very dark / blown-out pixels, which carry no
    /// reliable hue information (common at poolside with harsh overhead lighting).
    static func hueHistogram(from pixelBuffer: CVPixelBuffer, cropRect: CGRect) -> [Double]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let x0 = max(0, Int(cropRect.minX))
        let y0 = max(0, Int(cropRect.minY))
        let x1 = min(width, Int(cropRect.maxX))
        let y1 = min(height, Int(cropRect.maxY))
        guard x1 > x0, y1 > y0 else { return nil }

        var histogram = [Double](repeating: 0, count: hueBinCount)
        var sampleCount = 0
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var y = y0
        while y < y1 {
            let rowStart = y * bytesPerRow
            var x = x0
            while x < x1 {
                let offset = rowStart + x * 4
                let b = Double(buffer[offset]) / 255.0
                let g = Double(buffer[offset + 1]) / 255.0
                let r = Double(buffer[offset + 2]) / 255.0

                let (h, s, v) = rgbToHSV(r: r, g: g, b: b)
                if s > 0.25 && v > 0.15 && v < 0.98 {
                    let bin = min(hueBinCount - 1, Int(h / 360.0 * Double(hueBinCount)))
                    histogram[bin] += 1
                    sampleCount += 1
                }
                x += 2
            }
            y += 2
        }

        guard sampleCount > 0 else { return nil }
        return histogram.map { $0 / Double(sampleCount) }
    }

    /// Chi-square distance between two normalized histograms: 0 = identical, larger = more
    /// different. Used against `CalibrationSettings.colorMatchThreshold`.
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0.0
        for i in 0..<a.count {
            let denom = a[i] + b[i]
            guard denom > 0 else { continue }
            let diff = a[i] - b[i]
            sum += (diff * diff) / denom
        }
        return sum / 2.0
    }

    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV

        var h: Double = 0
        if delta > 0.0001 {
            if maxV == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxV == g {
                h = 60 * (((b - r) / delta) + 2)
            } else {
                h = 60 * (((r - g) / delta) + 4)
            }
            if h < 0 { h += 360 }
        }
        let s = maxV == 0 ? 0 : delta / maxV
        return (h, s, maxV)
    }
}
