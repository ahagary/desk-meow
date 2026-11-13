import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard [3, 4].contains(CommandLine.arguments.count) else {
    fputs("usage: derive_blink feed-master-v1-normalized.png output.png\n       derive_blink seated-open.png seated-closed-source.png output.png\n", stderr)
    exit(2)
}

func load(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

let open: CGImage
let closed: CGImage
if CommandLine.arguments.count == 3 {
    let atlas = load(CommandLine.arguments[1])
    guard atlas.width == 1260, atlas.height == 1244 else {
        fputs("blink atlas must be 4 x 4 cells of 315 x 311\n", stderr)
        exit(3)
    }
    open = atlas.cropping(to: CGRect(x: 0, y: 0, width: 315, height: 311))!
    closed = atlas.cropping(to: CGRect(x: 945, y: 622, width: 315, height: 311))!
} else {
    open = load(CommandLine.arguments[1])
    closed = load(CommandLine.arguments[2])
}
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

// Cell 12 has a narrower, left-shifted face. Register each eyelid to the
// corresponding open eye in cell 1; one nose-based translation cannot align
// both eyes. Coordinates are in the 315 x 311 cels, measured from the top-left.
// Keep the masks clear of the nose/muzzle so they remain exactly stationary.
let eyes = [(x: 130.0, y: 104.0, sourceX: 104, sourceY: 99),
            (x: 185.0, y: 104.0, sourceX: 165, sourceY: 99)]
let radius = (x: 22.0, y: 18.0)
for y in 0..<height {
    for x in 0..<width {
        for eye in eyes {
            let dx = (Double(x) - eye.x) / radius.x
            // The lower edge stops above the whiskers. Keep enough room above
            // the eye to replace the open upper lid without a dark ghost rim.
            let verticalRadius = Double(y) > eye.y ? 14.0 : radius.y
            let dy = (Double(y) - eye.y) / verticalRadius
            let distance = sqrt(dx * dx + dy * dy)
            guard distance < 1 else { continue }
            let sourceX = x + eye.sourceX - Int(eye.x)
            let sourceY = y + eye.sourceY - Int(eye.y)
            guard sourceX >= 0, sourceX < width, sourceY >= 0, sourceY < height else { continue }
            let sourceOffset = sourceY * bytesPerRow + sourceX * 4
            let destinationOffset = y * bytesPerRow + x * 4
            let weight = distance <= 0.80 ? 1.0 : (1.0 - distance) / 0.20
            // Eye regions are opaque; retain the original silhouette's alpha.
            for channel in 0..<3 {
                let a = Double(openBytes[destinationOffset + channel])
                let b = Double(closedBytes[sourceOffset + channel])
                openBytes[destinationOffset + channel] = UInt8(max(0, min(255, (a + (b - a) * weight).rounded())))
            }
        }
    }
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments.last!)
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
