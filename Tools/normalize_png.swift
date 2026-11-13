import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 5,
      let targetWidth = Int(CommandLine.arguments[3]),
      let targetHeight = Int(CommandLine.arguments[4]) else {
    fputs("usage: normalize_png input.png output.png width height\n", stderr)
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("could not read input PNG\n", stderr)
    exit(3)
}

let copyWidth = min(image.width, targetWidth)
let copyHeight = min(image.height, targetHeight)
guard let cropped = image.cropping(to: CGRect(x: 0, y: 0,
                                               width: copyWidth, height: copyHeight)),
      let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("could not create normalized canvas\n", stderr)
    exit(4)
}

context.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
context.interpolationQuality = .none
context.draw(cropped, in: CGRect(x: 0, y: 0, width: copyWidth, height: copyHeight))

guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.png.identifier as CFString, 1, nil
      ) else {
    fputs("could not create output PNG\n", stderr)
    exit(5)
}
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("could not write output PNG\n", stderr)
    exit(6)
}
