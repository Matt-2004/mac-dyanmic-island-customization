import AppKit

/// Decoded artwork plus the accent color derived from it.
final class ProcessedArtwork {
    let image: NSImage
    let accentColor: NSColor

    init(image: NSImage, accentColor: NSColor) {
        self.image = image
        self.accentColor = accentColor
    }
}

/// Decodes artwork data, derives an accent color, and caches results by track ID.
/// Decoding and color extraction run on a background queue.
final class ArtworkProcessor {
    private let cache = NSCache<NSString, ProcessedArtwork>()
    private let queue = DispatchQueue(label: "com.wai.Isle.artwork", qos: .utility)

    init() {
        cache.countLimit = 30
    }

    func cached(for trackID: String) -> ProcessedArtwork? {
        cache.object(forKey: trackID as NSString)
    }

    /// Decodes `data` off the main thread and returns the result on the main queue.
    func process(data: Data, trackID: String, completion: @escaping (ProcessedArtwork?) -> Void) {
        queue.async { [cache] in
            var processed: ProcessedArtwork?
            if let image = NSImage(data: data) {
                let color = Self.accentColor(for: image)
                let result = ProcessedArtwork(image: image, accentColor: color)
                cache.setObject(result, forKey: trackID as NSString)
                processed = result
            }
            DispatchQueue.main.async {
                completion(processed)
            }
        }
    }

    /// Picks the most prominent vivid hue in the artwork, brightened enough to read on black.
    static func accentColor(for image: NSImage) -> NSColor {
        let fallback = NSColor(white: 0.92, alpha: 1)
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return fallback }

        let side = 24
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: side,
                      height: side,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return fallback }

        let binCount = 12
        var weights = [Double](repeating: 0, count: binCount)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: binCount)

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[offset]) / 255
            let g = Double(pixels[offset + 1]) / 255
            let b = Double(pixels[offset + 2]) / 255
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            guard maxC > 0.15, delta > 0.08 else { continue }
            let saturation = delta / maxC
            var hue: Double
            if maxC == r {
                hue = (g - b) / delta
            } else if maxC == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            let weight = saturation * saturation * maxC
            weights[bin] += weight
            sums[bin].r += r * weight
            sums[bin].g += g * weight
            sums[bin].b += b * weight
        }

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0.5 else {
            return fallback
        }
        let total = weights[best]
        let average = NSColor(
            srgbRed: CGFloat(sums[best].r / total),
            green: CGFloat(sums[best].g / total),
            blue: CGFloat(sums[best].b / total),
            alpha: 1
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(max(saturation, 0.45), 0.85),
            brightness: max(brightness, 0.78),
            alpha: 1
        )
    }
}
