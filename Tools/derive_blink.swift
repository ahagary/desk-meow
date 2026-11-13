import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4 else {
    fputs("usage: derive_blink seated-open.png seated-closed-source.png output.png\n", stderr)
    exit(2)
}

func load(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

let open = load(CommandLine.arguments[1])
let closed = load(CommandLine.arguments[2])
guard open.width == 315, open.height == 311,
      closed.width == open.width, closed.height == open.height else {
    fputs("blink sources must both be 315 x 311\n", stderr)
    exit(3)
}

let width = open.width, height = open.height, bytesPerRow = width * 4
var openBytes = [UInt8](repeating: 0, count: height * bytesPerRow)
var closedBytes = [UInt8](repeating: 0, count: height * bytesPerRow)
func render(_ image: CGImage, into bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}
render(open, into: &openBytes)
render(closed, into: &closedBytes)

// Cell 12 shares the same identity and closed eyelids. Its nose is 6 px left
// and 2 px above cell 1. Copy two feathered eye-shaped regions rather than a
// rectangular face band, keeping the original muzzle, forehead and cheeks.
let eyes = [(x: 119.0, y: 103.0), (x: 171.0, y: 103.0)]
let radius = (x: 31.0, y: 23.0)
for y in 0..<height {
    for x in 0..<width {
        let distance: Double = eyes.map { eye -> Double in
            let dx = (Double(x) - eye.x) / radius.x
            let dy = (Double(y) - eye.y) / radius.y
            return sqrt(dx * dx + dy * dy)
        }.min()!
        guard distance < 1 else { continue }
        let sourceX = x - 6, sourceY = y - 2
        guard sourceX >= 0, sourceX < width, sourceY >= 0, sourceY < height else { continue }
        let sourceOffset = sourceY * bytesPerRow + sourceX * 4
        let destinationOffset = y * bytesPerRow + x * 4
        let weight = distance <= 0.80 ? 1.0 : (1.0 - distance) / 0.20
        for channel in 0..<4 {
            let a = Double(openBytes[destinationOffset + channel])
            let b = Double(closedBytes[sourceOffset + channel])
            openBytes[destinationOffset + channel] = UInt8(max(0, min(255, (a + (b - a) * weight).rounded())))
        }
    }
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
let result = openBytes.withUnsafeMutableBytes { raw -> CGImage in
    let context = CGContext(data: raw.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}
let destinationWriter = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(destinationWriter, result, nil)
guard CGImageDestinationFinalize(destinationWriter) else {
    fputs("could not write blink PNG\n", stderr)
    exit(4)
}
