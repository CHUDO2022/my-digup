// How a picture came out (своя версия: the analysis's "Мусор"): sharpness, brightness and an average hash, from the
// picture decoded by stb and looked at on a grid of at most ~320 pixels a side.
#if !canImport(ImageIO)
import CStb
import Foundation

public struct PictureQuality: Sendable, Codable {
    /// The variance of the Laplacian over the gray picture: low is blurry (below ~60 on this scale).
    public let sharpness: Double
    /// Mean gray, 0…255.
    public let brightness: Double
    /// The share of nearly black (<25) and nearly white (>235) pixels.
    public let dark: Double
    public let bright: Double
    /// 8×8 average hash: pictures a few bits apart look alike.
    public let hash: UInt64
    public let width: Int
    public let height: Int

    /// Nil when stb can't read the file (HEIC, RAW…).
    public static func measure(_ path: String) -> PictureQuality? {
        guard let image = RGBImage.load(path), image.width > 2, image.height > 2 else { return nil }
        let step = max(1, max(image.width, image.height) / 320)
        let w = image.width / step, h = image.height / step
        guard w > 2, h > 2 else { return nil }
        var gray = [Double](repeating: 0, count: w * h)
        var sum = 0.0, darkCount = 0, brightCount = 0
        image.pixels.withUnsafeBufferPointer { pixels in
            for y in 0..<h {
                for x in 0..<w {
                    let p = ((y * step) * image.width + x * step) * 3
                    let value = (Double(pixels[p]) * 299 + Double(pixels[p + 1]) * 587 + Double(pixels[p + 2]) * 114) / 1000
                    gray[y * w + x] = value
                    sum += value
                    if value < 25 { darkCount += 1 }
                    if value > 235 { brightCount += 1 }
                }
            }
        }
        var laplacians = 0.0, squares = 0.0, count = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let value = gray[i - 1] + gray[i + 1] + gray[i - w] + gray[i + w] - 4 * gray[i]
                laplacians += value
                squares += value * value
                count += 1
            }
        }
        let mean = laplacians / max(count, 1)
        let total = Double(w * h)
        return PictureQuality(sharpness: squares / max(count, 1) - mean * mean, brightness: sum / total,
                              dark: Double(darkCount) / total, bright: Double(brightCount) / total,
                              hash: image.averageHash(), width: image.width, height: image.height)
    }
}
#endif
