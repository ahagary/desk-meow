import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Register only the generated neutral eyelid artwork onto the approved seated
// cel. Intermediate frames cover the stationary iris with moving eyelids.
// Never crossfade two eye expressions or warp the entire face.
guard CommandLine.arguments.count == 4 else {
    fputs("usage: build_natural_blink atlas.png neutral-source.png output-directory\n", stderr)
    exit(2)
}

func load(_ path: String) -> CGImage {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

let width = 315, height = 311
let colorSpace = CGColorSpaceCreateDeviceRGB()
func context(_ data: UnsafeMutableRawPointer?) -> CGContext {
    CGContext(data: data, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func pixels(_ image: CGImage) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: width * height * 4)
    result.withUnsafeMutableBytes { raw in
        context(raw.baseAddress).draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return result
}
func write(_ bytes: [UInt8], to url: URL) {
    var copy = bytes
    let image = copy.withUnsafeMutableBytes { context($0.baseAddress).makeImage()! }
    let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, image, nil)
    precondition(CGImageDestinationFinalize(writer))
}
func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
func sample(_ bytes: [UInt8], x: Int, y: Double, channel: Int) -> Double {
    let y = max(0, min(Double(height - 1), y))
    let row = Int(y), next = min(height - 1, row + 1)
    let fraction = y - Double(row)
    let a = Double(bytes[(row * width + x) * 4 + channel])
    let b = Double(bytes[(next * width + x) * 4 + channel])
    return a + (b - a) * fraction
}

let atlas = load(CommandLine.arguments[1])
let artwork = load(CommandLine.arguments[2])
precondition(atlas.width == 1260 && atlas.height == 1244)
precondition(artwork.width == 1254 && artwork.height == 1254)
let seated = atlas.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))!
let original = pixels(seated)
let registration = context(nil)
registration.interpolationQuality = .high
// Top-left registration: 1254 px source -> 320 px, +2 px in x, 0 px in y.
registration.draw(artwork, in: CGRect(x: 2, y: height - 320, width: 320, height: 320))
let neutral = pixels(registration.makeImage()!)
let output = URL(fileURLWithPath: CommandLine.arguments[3])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let centers = [130.0, 185.0]
// Locate the actual thin neutral lid in each column, rather than assuming the
// generated shallow curve is mathematically symmetric.
var lidRows = [Int: Double]()
for cx in centers {
    for x in Int(cx - 18)...Int(cx + 18) {
        let row = (104...114).min { a, b in
            func brightness(_ y: Int) -> Int {
                let i = (y * width + x) * 4
                return Int(neutral[i]) + Int(neutral[i + 1]) + Int(neutral[i + 2])
            }
            return brightness(a) < brightness(b)
        }!
        lidRows[x] = Double(row)
    }
}

for (index, amount) in [0.25, 0.50, 0.75, 1.0].enumerated() {
    var result = original
    for y in 86..<118 {
        for x in 108..<207 {
            guard let cx = centers.first(where: { abs(Double(x) - $0) < 22 }) else { continue }
            let dx = (Double(x) - cx) / 22
            let dy = (Double(y) - 104) / (y > 104 ? 14.0 : 18.0)
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < 1 else { continue }
            let feather = clamp((1 - distance) / 0.20)
            let u = max(-1, min(1, (Double(x) - cx) / 17))
            let arc = sqrt(max(0, 1 - u * u))
            let topOpen = 104 - 13 * arc
            let bottomOpen = 104 + 12 * arc
            let closedLine = lidRows[x] ?? (105 + 6 * arc)
            let upper = topOpen + (closedLine - topOpen) * amount
            let lower = bottomOpen + (closedLine - bottomOpen) * amount
            let topCoverage = clamp(upper - Double(y) + 0.5)
            let bottomCoverage = clamp(Double(y) - lower + 0.5)
            let coverage = amount == 1 ? 1 : max(topCoverage, bottomCoverage)
            guard coverage > 0 else { continue }
            let sourceY: Double
            if amount == 1 {
                sourceY = Double(y)
            } else if topCoverage >= bottomCoverage {
                // Keep the top edge fixed while the upper lid descends.
                sourceY = 86 + (Double(y) - 86) * (closedLine - 86) / max(1, upper - 86)
            } else {
                sourceY = 118 - (118 - Double(y)) * (118 - closedLine) / max(1, 118 - lower)
            }
            let insideOriginalEye = Double(y) >= topOpen - 1 && Double(y) <= bottomOpen + 1
            let weight = feather * coverage * (insideOriginalEye ? 1 : amount)
            let offset = (y * width + x) * 4
            for channel in 0..<3 {
                let a = Double(original[offset + channel])
                let b = sample(neutral, x: x, y: sourceY, channel: channel)
                result[offset + channel] = UInt8(max(0, min(255, (a + (b - a) * weight).rounded())))
            }
        }
    }
    let filename = "feed-master-blink-v5-\(index + 1).png"
    write(result, to: output.appendingPathComponent(filename))
    print(filename)
}
