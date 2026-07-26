import CoreVideo
import CoreGraphics

/// Visual half of splash detection: simple frame differencing (no ML) on the calibrated water
/// ROI. A splash shows up as a sharp spike in mean luma difference between consecutive frames.
final class SplashDetector {
    private var previousLuma: [UInt8]?
    private var previousROI: CGRect?

    /// Computes a normalized motion-energy score (roughly 0...1) for the given ROI (normalized,
    /// top-left origin — matching CVPixelBuffer's row order, no Vision coordinate flip needed)
    /// by comparing mean absolute luma difference against the previous call. Call once per
    /// sampled frame while recording.
    func motionEnergy(pixelBuffer: CVPixelBuffer, roi: CGRect) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return 0 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let x0 = max(0, Int(roi.minX * CGFloat(width)))
        let y0 = max(0, Int(roi.minY * CGFloat(height)))
        let x1 = min(width, Int(roi.maxX * CGFloat(width)))
        let y1 = min(height, Int(roi.maxY * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return 0 }

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        var currentLuma: [UInt8] = []
        currentLuma.reserveCapacity(((x1 - x0) / 2 + 1) * ((y1 - y0) / 2 + 1))

        var y = y0
        while y < y1 {
            let rowStart = y * bytesPerRow
            var x = x0
            while x < x1 {
                let offset = rowStart + x * 4
                let b = Double(buffer[offset])
                let g = Double(buffer[offset + 1])
                let r = Double(buffer[offset + 2])
                let luma = UInt8(max(0, min(255, (0.299 * r + 0.587 * g + 0.114 * b).rounded())))
                currentLuma.append(luma)
                x += 2
            }
            y += 2
        }

        defer {
            previousLuma = currentLuma
            previousROI = roi
        }

        guard let previous = previousLuma, previous.count == currentLuma.count, previousROI == roi else {
            return 0
        }

        var totalDiff = 0.0
        for i in 0..<currentLuma.count {
            totalDiff += Double(abs(Int(currentLuma[i]) - Int(previous[i])))
        }
        let meanDiff = totalDiff / Double(currentLuma.count)
        return meanDiff / 255.0
    }

    /// Clears the frame-diff baseline. Call when entering STANDBY so the first frame of the next
    /// dive attempt doesn't get diffed against a stale reference from a previous recording.
    func reset() {
        previousLuma = nil
        previousROI = nil
    }
}
