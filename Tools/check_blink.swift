import CoreGraphics
import Foundation
import ImageIO

// Asset-level regression: blinking must not alter the nose, whiskers, coat,
// silhouette, or registration. The old v3 patch also copied a second nose.
guard CommandLine.arguments.count == 3 else {
    fputs("usage: check_blink feed-master-v1-normalized.png blink.png\n", stderr)
    exit(2)
}

func load(_ path: String) -> CGImage {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func pixels(_ image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

let atlas = load(CommandLine.arguments[1])
let blink = load(CommandLine.arguments[2])
guard atlas.width == 1260, atlas.height == 1244,
      blink.width == 315, blink.height == 311 else {
    fputs("unexpected atlas or blink dimensions\n", stderr)
    exit(1)
}
let open = atlas.cropping(to: CGRect(x: 0, y: 0, width: 315, height: 311))!
let a = pixels(open), b = pixels(blink)
// Independently bounded eye sockets: the nose starts below row 117.
let sockets = [CGRect(x: 108, y: 86, width: 44, height: 32),
               CGRect(x: 163, y: 86, width: 44, height: 32)]
var outsideChanges = 0, alphaChanges = 0
var eyeChanges = [0, 0]
for y in 0..<311 {
    for x in 0..<315 {
        let offset = (y * 315 + x) * 4
        if a[offset + 3] != b[offset + 3] { alphaChanges += 1 }
        let changed = (0..<3).contains { a[offset + $0] != b[offset + $0] }
        guard changed else { continue }
        if let eye = sockets.firstIndex(where: { $0.contains(CGPoint(x: x, y: y)) }) {
            eyeChanges[eye] += 1
        } else {
            outsideChanges += 1
        }
    }
}
print("eye changes: \(eyeChanges); outside eye sockets: \(outsideChanges); alpha changes: \(alphaChanges)")
guard outsideChanges == 0, alphaChanges == 0, eyeChanges.allSatisfy({ $0 > 200 }) else {
    fputs("blink regression: both eyes must close while the rest of the cat stays pixel-identical\n", stderr)
    exit(1)
}
print("blink asset valid")
