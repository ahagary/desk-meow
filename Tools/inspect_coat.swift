// Read-only color audit. It measures brown midtones, not character identity.
// Pose-dependent proportions of cream and stripes make whole-image RGB means misleading.
import Foundation
import ImageIO
import CoreGraphics

func quantile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * p)]
}
var results: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var hues: [Double] = [], sats: [Double] = [], lights: [Double] = []
    for i in stride(from: 0, to: bytes.count, by: 4) {
        if bytes[i + 3] < 250 { continue }
        let r = Double(bytes[i]) / 255, g = Double(bytes[i+1]) / 255, b = Double(bytes[i+2]) / 255
        let hi = max(r, max(g,b)), lo = min(r, min(g,b)), delta = hi-lo
        if delta < 0.01 || hi < 0.25 || hi > 0.80 || r != hi { continue }
        let hue = 60 * (g-b) / delta, saturation = delta / hi
        if hue < 12 || hue > 46 || saturation < 0.25 || saturation > 0.85 { continue }
        hues.append(hue); sats.append(saturation)
        lights.append(0.2126*r + 0.7152*g + 0.0722*b)
    }
    results.append(["file":path,"size":[w,h],"opaqueBrownSamples":hues.count,
        "hueDegreesP25P50P75":[quantile(hues,0.25),quantile(hues,0.5),quantile(hues,0.75)],
        "medianSaturation":quantile(sats,0.5),"medianLuma":quantile(lights,0.5),
        "sourceColorSpace":image.colorSpace?.name as String? ?? "unknown",
        "cornerAlpha":[bytes[3],bytes[(w-1)*4+3],bytes[(w*(h-1))*4+3],bytes[(w*h-1)*4+3]]])
}
print(String(data:try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
